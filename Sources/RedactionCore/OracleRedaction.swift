import Foundation

struct OracleRedaction {
    private struct Symbol {
        let category: Category
        let key: String
    }

    private struct Scope {
        var names: [String: [Symbol?]] = [:]
        var qualified: [String: [String: (Symbol, Symbol)]] = [:]
    }

    private struct Sources {
        var scope = Scope()
        var names: Set<Int> = []
        var derived: [Int: Range<Int>] = [:]
    }

    private let source: NSString
    private let tokens: [OracleToken]
    private let closes: [Int: Int]
    private var edits: [Edit]

    private static let setOperators: Set<String> = ["UNION", "INTERSECT", "MINUS"]
    private static let endOfSources: Set<String> = ["WHERE", "GROUP", "HAVING", "ORDER", "OFFSET", "FETCH"]
    private static let unsupported: Set<String> = [
        "PIVOT", "UNPIVOT", "MATCH_RECOGNIZE", "MODEL", "CONNECT", "START", "VERSIONS", "LATERAL",
        "APPLY", "RETURNING", "INSERT", "UPDATE", "DELETE", "INTO", "MERGE", "EXCEPT", "FOR",
    ]
    private static let relationWords: Set<String> = [
        "SELECT", "AS", "ON", "USING", "ONLY", "TABLE", "XMLTABLE", "JSON_TABLE",
        "JOIN", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "NATURAL",
        "PARTITION", "SUBPARTITION", "SAMPLE", "FLASHBACK", "ASOF", "WITH", "SEARCH", "CYCLE",
        "FUNCTION", "PROCEDURE",
    ]

    static func detect(_ text: String, options: RedactionOptions) throws -> [Edit] {
        var lexer = OracleLexer(text)
        let lexed = try lexer.scan()
        var parser = Self(source: lexer.source, tokens: lexed.tokens, closes: lexed.closes, edits: lexed.edits)
        var end = lexed.tokens.count
        if parser.isSymbol(end - 1, 59) { end -= 1 }
        guard end > 0 else { throw RedactionError("请复制一条 Oracle SELECT 查询。") }
        if let extra = (0..<end).first(where: { parser.isSymbol($0, 59) }) {
            throw parser.issue("首版一次处理一条 Oracle SELECT 查询。", at: extra)
        }
        try parser.query(0..<end, ctes: [:], parents: [], forbiddenCTEs: [])
        parser.addLiteralEdits(options: options)
        return parser.edits
    }

    private mutating func query(
        _ range: Range<Int>, ctes inherited: [String: Symbol], parents: [Scope], forbiddenCTEs: Set<String>
    ) throws {
        var ctes = inherited
        var start = range.lowerBound
        if keyword(start) == "WITH" {
            var localNames: Set<String> = []
            start += 1
            while true {
                guard start < range.upperBound, let name = name(at: start), localNames.insert(name).inserted else {
                    throw issue("无法识别这个 WITH 定义。", at: start)
                }
                let symbol = Symbol(category: .cte, key: "\(start)")
                mark(start, as: symbol)
                start += 1
                if isSymbol(start, 40), let end = closes[start], end < range.upperBound {
                    guard (start + 1..<end).allSatisfy({ self.name(at: $0) != nil || isSymbol($0, 44) }) else {
                        throw issue("无法识别 CTE 的列别名。", at: start)
                    }
                    start = end + 1
                }
                guard keyword(start) == "AS", isSymbol(start + 1, 40),
                      let end = closes[start + 1], end < range.upperBound else {
                    throw issue("首版只支持普通 WITH 查询。", at: start)
                }
                try query((start + 2)..<end, ctes: ctes, parents: parents, forbiddenCTEs: forbiddenCTEs.union([name]))
                ctes[name] = symbol
                start = end + 1
                guard isSymbol(start, 44) else { break }
                start += 1
            }
        }
        guard start < range.upperBound, keyword(start) == "SELECT" else {
            throw issue("Oracle SQL 模式只接受单条 SELECT 查询。", at: start)
        }

        let direct = topLevel(start..<range.upperBound)
        var branch = start
        for index in direct where Self.setOperators.contains(keyword(index) ?? "") {
            try select(branch..<index, ctes: ctes, parents: parents, forbiddenCTEs: forbiddenCTEs)
            branch = index + 1
            if keyword(branch) == "ALL" || keyword(branch) == "DISTINCT" { branch += 1 }
        }
        guard branch <= range.upperBound else { throw issue("集合查询不完整。", at: branch) }
        try select(branch..<range.upperBound, ctes: ctes, parents: parents, forbiddenCTEs: forbiddenCTEs)
    }

    private mutating func select(
        _ range: Range<Int>, ctes: [String: Symbol], parents: [Scope], forbiddenCTEs: Set<String>
    ) throws {
        guard !range.isEmpty, keyword(range.lowerBound) == "SELECT" else {
            throw issue("缺少 SELECT 查询。", at: range.lowerBound)
        }
        let direct = topLevel(range)
        if let index = direct.dropFirst().first(where: {
            let word = keyword($0) ?? ""
            return Self.unsupported.contains(word) || word == "SELECT" || word == "WITH"
        }) {
            throw issue("发现超出首版支持范围的 Oracle 查询语法。", at: index)
        }
        let from = direct.filter { keyword($0) == "FROM" }
        guard from.count == 1, let start = from.first, start > range.lowerBound + 1 else {
            throw issue("每个 SELECT 查询需要一处可识别的 FROM。", at: from.last ?? range.lowerBound)
        }
        let end = direct.first { $0 > start && Self.endOfSources.contains(keyword($0) ?? "") } ?? range.upperBound
        let parsed = try sources((start + 1)..<end, ctes: ctes, forbiddenCTEs: forbiddenCTEs)
        try expressions(
            (range.lowerBound + 1)..<range.upperBound,
            sources: parsed,
            ctes: ctes,
            scopes: [parsed.scope] + parents,
            parents: parents,
            forbiddenCTEs: forbiddenCTEs
        )
    }

    private mutating func sources(
        _ range: Range<Int>, ctes: [String: Symbol], forbiddenCTEs: Set<String>
    ) throws -> Sources {
        var result = Sources()
        var cursor = range.lowerBound

        while true {
            guard cursor < range.upperBound else { throw issue("缺少 FROM 或 JOIN 的数据来源。", at: cursor) }
            let start = cursor
            var relation: Symbol?
            var defaultName: String?
            var qualified: (String, String, Symbol, Symbol)?

            if isSymbol(cursor, 40), let close = closes[cursor], close < range.upperBound {
                guard isQuery(cursor + 1), cursor + 1 < close else {
                    throw issue("首版只支持表、视图或 SELECT 子查询作为数据来源。", at: cursor)
                }
                result.derived[cursor] = (cursor + 1)..<close
                cursor = close + 1
            } else {
                guard let first = name(at: cursor) else {
                    throw issue("无法识别 FROM 或 JOIN 后的表名。", at: cursor)
                }
                result.names.insert(cursor)
                cursor += 1
                if isSymbol(cursor, 46) {
                    guard cursor + 1 < range.upperBound, let second = name(at: cursor + 1) else {
                        throw issue("表名限定不完整。", at: cursor)
                    }
                    result.names.insert(cursor + 1)
                    if first == "SYS", second == "DUAL" {
                        defaultName = second
                    } else {
                        let schema = Symbol(category: .schema, key: first)
                        let table = Symbol(category: .table, key: "\(first)\u{0}\(second)")
                        mark(start, as: schema)
                        mark(cursor + 1, as: table)
                        defaultName = second
                        relation = table
                        qualified = (first, second, schema, table)
                    }
                    cursor += 2
                } else if forbiddenCTEs.contains(first) {
                    throw issue("首版暂不处理递归或重名歧义的 CTE。", at: start)
                } else {
                    defaultName = first
                    if let cte = ctes[first] {
                        relation = cte
                    } else if first != "DUAL" {
                        relation = Symbol(category: .table, key: "\u{0}\(first)")
                    }
                    if let relation { mark(start, as: relation) }
                }
            }

            if cursor < range.upperBound, keyword(cursor) == "AS" {
                throw issue("Oracle 表别名请使用无 AS 的写法。", at: cursor)
            }
            if cursor < range.upperBound, let alias = name(at: cursor) {
                let symbol = Symbol(category: .alias, key: "\(cursor)")
                guard result.scope.names[alias] == nil else {
                    throw issue("表别名重复，无法可靠定位引用。", at: cursor)
                }
                result.names.insert(cursor)
                mark(cursor, as: symbol)
                result.scope.names[alias] = [symbol]
                cursor += 1
            } else if let defaultName {
                result.scope.names[defaultName, default: []].append(relation)
                if let (schema, table, schemaSymbol, tableSymbol) = qualified {
                    result.scope.qualified[schema, default: [:]][table] = (schemaSymbol, tableSymbol)
                }
            }

            if cursor == range.upperBound { return result }
            if isSymbol(cursor, 44) {
                cursor += 1
                continue
            }
            if keyword(cursor) == "ON" {
                let conditionStart = cursor + 1
                cursor = conditionStart
                while cursor < range.upperBound, !isSymbol(cursor, 44), joinEnd(cursor) == nil {
                    cursor = closes[cursor].map { $0 + 1 } ?? cursor + 1
                }
                guard cursor > conditionStart else { throw issue("JOIN ON 缺少连接条件。", at: cursor) }
            } else if keyword(cursor) == "USING" {
                guard isSymbol(cursor + 1, 40), let close = closes[cursor + 1], close < range.upperBound,
                      close > cursor + 2,
                      (cursor + 2..<close).allSatisfy({ name(at: $0) != nil || isSymbol($0, 44) }) else {
                    throw issue("无法识别 JOIN USING 后的列列表。", at: cursor)
                }
                cursor = close + 1
            }
            if cursor == range.upperBound { return result }
            if isSymbol(cursor, 44) {
                cursor += 1
                continue
            }
            guard let next = joinEnd(cursor) else {
                throw issue("无法可靠识别这个 FROM 或 JOIN 子句。", at: cursor)
            }
            cursor = next
        }
    }

    private mutating func expressions(
        _ range: Range<Int>, sources: Sources, ctes: [String: Symbol], scopes: [Scope],
        parents: [Scope], forbiddenCTEs: Set<String>
    ) throws {
        var index = range.lowerBound
        while index < range.upperBound {
            if let end = closes[index] {
                if let child = sources.derived[index] {
                    try query(child, ctes: ctes, parents: parents, forbiddenCTEs: forbiddenCTEs)
                } else if isQuery(index + 1) {
                    try query((index + 1)..<end, ctes: ctes, parents: scopes, forbiddenCTEs: forbiddenCTEs)
                } else {
                    try expressions(
                        (index + 1)..<end, sources: sources, ctes: ctes, scopes: scopes,
                        parents: parents, forbiddenCTEs: forbiddenCTEs
                    )
                }
                index = end + 1
                continue
            }
            if !sources.names.contains(index), isSymbol(index + 1, 46), index + 2 < range.upperBound,
               let first = tokens[index].name {
                if let second = tokens[index + 2].name, isSymbol(index + 3, 46) {
                    let binding = scopes.lazy.compactMap { $0.qualified[first]?[second] }.first
                    if let (schema, table) = binding {
                        mark(index, as: schema)
                        mark(index + 2, as: table)
                    } else if first != "SYS" || second != "DUAL" {
                        throw issue("无法可靠定位这个多段限定名。请用表别名明确引用。", at: index)
                    }
                    index += 4
                    continue
                }
                if let matches = scopes.lazy.compactMap({ $0.names[first] }).first {
                    guard matches.count == 1 else {
                        throw issue("出现同名表的歧义引用。请用表别名明确引用。", at: index)
                    }
                    if let symbol = matches[0] { mark(index, as: symbol) }
                }
                index += 2
                continue
            }
            index += 1
        }
    }

    private mutating func addLiteralEdits(options: RedactionOptions) {
        for (index, token) in tokens.enumerated() {
            guard case let .literal(range) = token.kind, range.length > 0 else { continue }
            if isSymbol(index - 1, 61), let field = name(at: index - 2), SensitiveRules.isCredentialField(field) {
                edits.append(Edit(range, .secret))
            } else if options.sqlStrings {
                edits.append(Edit(range, .literal))
            } else {
                let text = source.substring(with: range)
                edits.append(contentsOf: SensitiveRules.detect(text, offset: range.location, options: options))
            }
        }
    }

    private func topLevel(_ range: Range<Int>) -> [Int] {
        var index = range.lowerBound
        var result: [Int] = []
        while index < range.upperBound {
            result.append(index)
            index = closes[index].map { $0 + 1 } ?? index + 1
        }
        return result
    }

    private func isQuery(_ index: Int) -> Bool {
        keyword(index) == "SELECT" || keyword(index) == "WITH"
    }

    private func joinEnd(_ start: Int) -> Int? {
        var index = start
        if keyword(index) == "NATURAL" { index += 1 }
        switch keyword(index) {
        case "LEFT", "RIGHT", "FULL":
            index += 1
            if keyword(index) == "OUTER" { index += 1 }
        case "INNER", "CROSS":
            index += 1
        default:
            break
        }
        return keyword(index) == "JOIN" ? index + 1 : nil
    }

    private func keyword(_ index: Int) -> String? {
        tokens.indices.contains(index) ? tokens[index].keyword : nil
    }

    private func name(at index: Int) -> String? {
        guard tokens.indices.contains(index) else { return nil }
        if let word = tokens[index].keyword,
           Self.relationWords.contains(word) || Self.endOfSources.contains(word)
           || Self.unsupported.contains(word) || Self.setOperators.contains(word) {
            return nil
        }
        return tokens[index].name
    }

    private func isSymbol(_ index: Int, _ symbol: UInt16) -> Bool {
        tokens.indices.contains(index) && tokens[index].isSymbol(symbol)
    }

    private mutating func mark(_ index: Int, as symbol: Symbol) {
        edits.append(Edit(tokens[index].range, symbol.category, key: symbol.key))
    }

    private func issue(_ message: String, at index: Int) -> RedactionError {
        let range = tokens.indices.contains(index) ? tokens[index].range : tokens.last?.range
        return RedactionError(message, range: range)
    }
}
