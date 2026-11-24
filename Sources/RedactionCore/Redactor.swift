import Foundation

public enum RedactionMode: String, CaseIterable, Sendable {
    case oracle = "Oracle SQL"
    case log = "日志"
}

public struct RedactionOptions: Equatable, Sendable {
    public var emails = false
    public var urlHosts = false
    public var sqlStrings = false

    public init(emails: Bool = false, urlHosts: Bool = false, sqlStrings: Bool = false) {
        self.emails = emails
        self.urlHosts = urlHosts
        self.sqlStrings = sqlStrings
    }
}

public enum Category: String, CaseIterable, Identifiable, Sendable {
    case schema, table, alias, cte, ip, email, host, secret, literal, comment, manual

    public var id: Self { self }

    public var label: String {
        switch self {
        case .schema: "Schema"
        case .table: "表或视图"
        case .alias: "表别名"
        case .cte: "CTE"
        case .ip: "IP 地址"
        case .email: "邮箱"
        case .host: "URL 主机名"
        case .secret: "凭据"
        case .literal: "SQL 字符串"
        case .comment: "SQL 注释"
        case .manual: "手动遮盖"
        }
    }

    var marker: String? {
        switch self {
        case .schema: "S"
        case .table: "T"
        case .alias: "A"
        case .cte: "C"
        case .ip: "IP"
        case .email: "EMAIL"
        case .host: "HOST"
        case .secret, .literal, .comment, .manual: nil
        }
    }

    var isSQLName: Bool {
        self == .schema || self == .table || self == .alias || self == .cte
    }
}

public struct Highlight: Sendable, Equatable {
    public let category: Category
    public let source: NSRange
    public let output: NSRange
}

public struct RedactionError: LocalizedError, Sendable, Equatable {
    public let message: String
    public let range: NSRange?

    public init(_ message: String, range: NSRange? = nil) {
        self.message = message
        self.range = range
    }

    public var errorDescription: String? { message }
}

struct Edit {
    let range: NSRange
    let category: Category
    let key: String?
    let replacement: String?

    init(_ range: NSRange, _ category: Category, key: String? = nil, replacement: String? = nil) {
        self.range = range
        self.category = category
        self.key = key
        self.replacement = replacement
    }
}

struct MappingEntry: Sendable {
    let original: String
    let category: Category
}

public struct RestoreMap: Sendable {
    public let id: String
    let entries: [String: MappingEntry]
    public var count: Int { entries.count }
}

public struct Preview: Sendable {
    public let text: String
    public let highlights: [Highlight]
    public let mapping: RestoreMap
}

public struct RestorePreview: Sendable {
    public let text: String
    public let replaced: Int
    public let unknown: Int
    public let absent: Int
}

public struct SessionStore: Sendable {
    struct Session: Sendable {
        let map: RestoreMap
        let expires: ContinuousClock.Instant
    }

    private var session: Session?
    public static let lifetime: Duration = .seconds(30 * 60)

    public init() {}

    public mutating func commit(_ map: RestoreMap, now: ContinuousClock.Instant = .now) {
        session = map.count == 0 ? nil : Session(map: map, expires: now.advanced(by: Self.lifetime))
    }

    public mutating func current(now: ContinuousClock.Instant = .now) -> RestoreMap? {
        guard let session, now < session.expires else {
            clear()
            return nil
        }
        return session.map
    }

    public mutating func clear() {
        session = nil
    }
}

public enum Redactor {
    public static let maxInputBytes = 256 * 1024

    public static func makeNonce(for text: String) -> String {
        let uppercase = text.uppercased()
        while true {
            let nonce = String(UUID().uuidString.prefix(8))
            if !uppercase.contains(nonce) { return nonce }
        }
    }

    public static func canMark(_ range: NSRange, in text: String) -> Bool {
        canMark(range, in: text as NSString)
    }

    private static func canMark(_ range: NSRange, in source: NSString) -> Bool {
        range.location >= 0 && range.location <= source.length
            && range.length > 0 && range.length <= source.length - range.location
            && source.rangeOfComposedCharacterSequences(for: range) == range
    }

    public static func matchingRanges(for selection: NSRange, in text: String) -> [NSRange] {
        let source = text as NSString
        guard canMark(selection, in: source) else { return [] }
        let selected = source.substring(with: selection)
        var cursor = 0
        var ranges: [NSRange] = []
        while cursor < source.length {
            let search = NSRange(location: cursor, length: source.length - cursor)
            let found = source.range(of: selected, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            cursor = NSMaxRange(found)
            guard canMark(found, in: source) else { continue }

            // Adjacent matches can share one replacement, even for single-character selections.
            if let previous = ranges.last, NSMaxRange(previous) == found.location {
                ranges[ranges.count - 1] = NSUnionRange(previous, found)
            } else {
                ranges.append(found)
            }
        }
        if !ranges.contains(where: { NSIntersectionRange($0, selection) == selection }) {
            ranges.append(selection)
        }
        return ranges
    }

    public static func prepare(
        _ text: String,
        mode: RedactionMode,
        options: RedactionOptions = RedactionOptions(),
        manual: [NSRange] = [],
        nonce: String? = nil
    ) throws -> Preview {
        try validate(text)
        let source = text as NSString
        let session = nonce ?? makeNonce(for: text)
        guard session.utf8.count == 8,
              session.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              text.range(of: session, options: .caseInsensitive) == nil else {
            throw RedactionError("本次占位符与原文冲突。请重新载入文本。")
        }
        let marks = try manual.map { range in
            guard canMark(range, in: source) else {
                throw RedactionError("手动遮盖选区已失效。请重新选择。")
            }
            return Edit(range, .manual)
        }
        let detected: [Edit]
        switch mode {
        case .oracle:
            detected = try OracleRedaction.detect(text, options: options)
        case .log:
            detected = SensitiveRules.detect(text, options: options)
        }
        return render(source, edits: merge(detected + marks), nonce: session)
    }

    public static func restore(_ text: String, with mapping: RestoreMap) throws -> RestorePreview {
        try validate(text)
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        var cursor = 0
        var replaced = 0
        var unknown = 0
        var found: Set<String> = []
        var output = ""
        for match in candidates.matches(in: text, range: range) {
            let token = source.substring(with: match.range).uppercased()
            guard let entry = mapping.entries[token] else {
                let tokenRange = NSRange(location: 0, length: token.utf16.count)
                if token.contains(mapping.id) || placeholder.firstMatch(in: token, range: tokenRange) != nil {
                    unknown += 1
                }
                continue
            }

            var replacementRange = match.range
            if entry.category.isSQLName,
               match.range.location > 0, NSMaxRange(match.range) < source.length,
               source.character(at: match.range.location - 1) == 34,
               source.character(at: NSMaxRange(match.range)) == 34,
               source.substring(with: match.range) == token {
                replacementRange = NSRange(location: match.range.location - 1, length: match.range.length + 2)
            } else if entry.category.isSQLName,
                      match.range.location > 0, NSMaxRange(match.range) < source.length,
                      source.character(at: match.range.location - 1) == 34,
                      source.character(at: NSMaxRange(match.range)) == 34 {
                unknown += 1
                continue
            }
            output += source.substring(with: NSRange(location: cursor, length: replacementRange.location - cursor))
            output += entry.original
            cursor = NSMaxRange(replacementRange)
            found.insert(token)
            replaced += 1
        }
        output += source.substring(from: cursor)
        return RestorePreview(text: output, replaced: replaced, unknown: unknown, absent: mapping.count - found.count)
    }

    static func validate(_ text: String) throws {
        guard text.utf8.count <= maxInputBytes else {
            throw RedactionError("文本超过 256 KiB。请分段复制。")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RedactionError("没有可处理的纯文本。")
        }
        guard !text.utf16.contains(0) else {
            throw RedactionError("文本包含空字符。请复制纯文本片段。")
        }
    }

    private static let markers = "(?:S|T|A|C|IP|EMAIL|HOST)"
    private static let placeholder = try! NSRegularExpression(
        pattern: #"^\#(markers)_[A-Z0-9]{8}_[0-9]+$"#
    )
    private static let candidates = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}\p{M}_$#])\#(markers)_[\p{L}\p{N}\p{M}_$#]+(?![\p{L}\p{N}\p{M}_$#])"#
    )

    private static func merge(_ edits: [Edit]) -> [Edit] {
        let sorted = edits.sorted {
            $0.range.location == $1.range.location
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }
        var merged: [Edit] = []
        for edit in sorted {
            guard let previous = merged.last, NSMaxRange(previous.range) > edit.range.location else {
                merged.append(edit)
                continue
            }
            if previous.category == .manual || edit.category == .manual {
                merged[merged.count - 1] = Edit(NSUnionRange(previous.range, edit.range), .manual)
            } else if previous.category == .secret || edit.category == .secret {
                merged[merged.count - 1] = Edit(NSUnionRange(previous.range, edit.range), .secret)
            } else if previous.range != edit.range, NSMaxRange(edit.range) > NSMaxRange(previous.range) {
                // An unfamiliar overlap must never expose the uncovered tail.
                merged[merged.count - 1] = Edit(NSUnionRange(previous.range, edit.range), .manual)
            }
        }
        return merged
    }

    private static func render(_ source: NSString, edits: [Edit], nonce: String) -> Preview {
        var cursor = 0
        var outputOffset = 0
        var output = ""
        var highlights: [Highlight] = []
        var aliases: [Category: [String: String]] = [:]
        var entries: [String: MappingEntry] = [:]

        for edit in edits {
            let original = source.substring(with: edit.range)
            let prefixLength = edit.range.location - cursor
            output += source.substring(with: NSRange(location: cursor, length: prefixLength))
            outputOffset += prefixLength

            let replacement: String
            if let custom = edit.replacement {
                replacement = custom
            } else if let marker = edit.category.marker {
                let key = edit.key ?? original
                if let existing = aliases[edit.category]?[key] {
                    replacement = existing
                } else {
                    let count = aliases[edit.category, default: [:]].count + 1
                    let token = "\(marker)_\(nonce)_\(String(format: "%02d", count))"
                    aliases[edit.category, default: [:]][key] = token
                    entries[token] = MappingEntry(original: original, category: edit.category)
                    replacement = token
                }
            } else {
                switch edit.category {
                case .secret: replacement = "REDACTED_SECRET"
                case .literal: replacement = "REDACTED_STRING"
                default: replacement = "REDACTED"
                }
            }

            let outputLength = replacement.utf16.count
            output += replacement
            highlights.append(Highlight(
                category: edit.category, source: edit.range,
                output: NSRange(location: outputOffset, length: outputLength)
            ))
            outputOffset += outputLength
            cursor = NSMaxRange(edit.range)
        }
        output += source.substring(from: cursor)
        return Preview(text: output, highlights: highlights, mapping: RestoreMap(id: nonce, entries: entries))
    }
}
