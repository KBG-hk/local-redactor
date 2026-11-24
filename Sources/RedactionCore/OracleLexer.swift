import Foundation

struct OracleToken {
    enum Kind {
        case word(String), quoted(String), literal(NSRange), bind, number, symbol(UInt16)
    }

    let kind: Kind
    let range: NSRange

    var name: String? {
        switch kind {
        case let .word(keyword), let .quoted(keyword): keyword
        default: nil
        }
    }

    var keyword: String? {
        if case let .word(value) = kind { return value }
        return nil
    }

    func isSymbol(_ value: UInt16) -> Bool {
        if case let .symbol(symbol) = kind { return symbol == value }
        return false
    }
}

struct OracleLexer {
    let source: NSString
    private let units: [UInt16]
    private var cursor = 0
    private var tokens: [OracleToken] = []
    private var edits: [Edit] = []
    private var opens: [Int] = []
    private var closes: [Int: Int] = [:]

    init(_ text: String) {
        source = text as NSString
        units = Array(text.utf16)
    }

    mutating func scan() throws -> (tokens: [OracleToken], edits: [Edit], closes: [Int: Int]) {
        while cursor < units.count {
            let start = cursor
            let unit = at(cursor)
            if isWhitespace(unit) {
                cursor += 1
            } else if unit == 45 && at(cursor + 1) == 45 {
                try lineComment()
            } else if unit == 47 && at(cursor + 1) == 42 {
                try blockComment()
            } else if unit == 34 {
                try quotedName()
            } else if unit == 39 || (fold(unit) == 78 && at(cursor + 1) == 39) {
                try singleQuoted(start: start, quote: unit == 39 ? cursor : cursor + 1)
            } else if fold(unit) == 81 && at(cursor + 1) == 39 {
                try alternativeQuoted(start: start, quote: cursor + 1)
            } else if fold(unit) == 78 && fold(at(cursor + 1)) == 81 && at(cursor + 2) == 39 {
                try alternativeQuoted(start: start, quote: cursor + 2)
            } else if isLetter(unit) {
                cursor += 1
                while isNameUnit(at(cursor)) { cursor += 1 }
                emit(.word(source.substring(with: span(from: start)).uppercased()), from: start)
            } else if isDigit(unit) {
                cursor += 1
                while isDigit(at(cursor)) { cursor += 1 }
                emit(.number, from: start)
            } else if unit == 58 && (isLetter(at(cursor + 1)) || isDigit(at(cursor + 1))) {
                cursor += 2
                while isNameUnit(at(cursor)) { cursor += 1 }
                emit(.bind, from: start)
            } else if unit == 64 {
                throw error("首版暂不处理包含 DB Link 的查询。", at: start)
            } else {
                try symbol(at: start)
            }
        }
        if let open = opens.last {
            throw RedactionError("括号未闭合。", range: tokens[open].range)
        }
        return (tokens, edits, closes)
    }

    private mutating func lineComment() throws {
        let start = cursor
        if at(cursor + 2) == 43 { throw error("首版暂不处理包含 Oracle Hint 的查询。", at: start) }
        cursor += 2
        while cursor < units.count, at(cursor) != 10, at(cursor) != 13 { cursor += 1 }
        edits.append(Edit(span(from: start), .comment, replacement: " "))
    }

    private mutating func blockComment() throws {
        let start = cursor
        if at(cursor + 2) == 43 { throw error("首版暂不处理包含 Oracle Hint 的查询。", at: start) }
        cursor += 2
        var breaks = " "
        while cursor < units.count {
            if at(cursor) == 42 && at(cursor + 1) == 47 {
                cursor += 2
                edits.append(Edit(span(from: start), .comment, replacement: breaks))
                return
            }
            if at(cursor) == 10 { breaks.append("\n") }
            if at(cursor) == 13 { breaks.append("\r") }
            cursor += 1
        }
        throw error("SQL 注释未闭合。", at: start)
    }

    private mutating func quotedName() throws {
        let start = cursor
        cursor += 1
        while cursor < units.count && at(cursor) != 34 { cursor += 1 }
        guard cursor < units.count, cursor > start + 1 else {
            throw error("双引号标识符不完整。", at: start)
        }
        let name = source.substring(with: NSRange(location: start + 1, length: cursor - start - 1))
        cursor += 1
        emit(.quoted(name), from: start)
    }

    private mutating func singleQuoted(start: Int, quote: Int) throws {
        cursor = quote + 1
        while cursor < units.count {
            if at(cursor) == 39 {
                if at(cursor + 1) == 39 {
                    cursor += 2
                    continue
                }
                let inside = NSRange(location: quote + 1, length: cursor - quote - 1)
                cursor += 1
                emit(.literal(inside), from: start)
                return
            }
            cursor += 1
        }
        throw error("SQL 字符串未闭合。", at: start)
    }

    private mutating func alternativeQuoted(start: Int, quote: Int) throws {
        let delimiter = at(quote + 1)
        guard delimiter > 0, delimiter < 128, !isWhitespace(delimiter), delimiter != 39 else {
            throw error("无法识别这个 Oracle 字符串分隔符。", at: start)
        }
        let close: UInt16
        switch delimiter {
        case 91: close = 93
        case 123: close = 125
        case 40: close = 41
        case 60: close = 62
        default: close = delimiter
        }
        cursor = quote + 2
        while cursor < units.count {
            if at(cursor) == close && at(cursor + 1) == 39 {
                let inside = NSRange(location: quote + 2, length: cursor - quote - 2)
                cursor += 2
                emit(.literal(inside), from: start)
                return
            }
            cursor += 1
        }
        throw error("Oracle q 引号字符串未闭合。", at: start)
    }

    private mutating func symbol(at start: Int) throws {
        let unit = at(start)
        switch unit {
        case 40:
            guard opens.count < 64 else { throw error("SQL 嵌套过深。请分段处理。", at: start) }
            opens.append(tokens.count)
        case 41:
            guard let open = opens.popLast() else { throw error("括号不匹配。", at: start) }
            closes[open] = tokens.count
        case 33, 37, 42, 43, 44, 45, 46, 47, 58, 59, 60, 61, 62, 94, 124, 126:
            break
        default:
            throw error("发现首版无法分析的 SQL 字符。非 ASCII 对象名请使用双引号。", at: start)
        }
        cursor += 1
        emit(.symbol(unit), from: start)
    }

    private mutating func emit(_ kind: OracleToken.Kind, from start: Int) {
        tokens.append(OracleToken(kind: kind, range: span(from: start)))
    }

    private func span(from start: Int) -> NSRange {
        NSRange(location: start, length: cursor - start)
    }

    private func error(_ message: String, at start: Int) -> RedactionError {
        let location = source.rangeOfComposedCharacterSequence(at: start)
        return RedactionError(message, range: location)
    }

    private func at(_ location: Int) -> UInt16 { location < units.count ? units[location] : 0 }
    private func fold(_ value: UInt16) -> UInt16 { (97...122).contains(value) ? value - 32 : value }
    private func isLetter(_ value: UInt16) -> Bool { (65...90).contains(fold(value)) }
    private func isDigit(_ value: UInt16) -> Bool { (48...57).contains(value) }
    private func isNameUnit(_ value: UInt16) -> Bool {
        isLetter(value) || isDigit(value) || value == 95 || value == 36 || value == 35
    }
    private func isWhitespace(_ value: UInt16) -> Bool {
        value == 32 || (9...13).contains(value) || value == 0xFEFF
    }
}
