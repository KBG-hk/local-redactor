import Foundation
import RedactionCore
import Testing

private let nonce = "A1B2C3D4"

@Suite("脱敏引擎")
struct RedactionTests {
    @Test func schemaQualifiedOracleTableAndAlias() throws {
        let sql = "SELECT l.id FROM FINANCE.LOAN_LEDGER l WHERE l.status = :status;"
        let result = try Redactor.prepare(sql, mode: .oracle, nonce: nonce)
        #expect(result.text == "SELECT A_A1B2C3D4_01.id FROM S_A1B2C3D4_01.T_A1B2C3D4_01 A_A1B2C3D4_01 WHERE A_A1B2C3D4_01.status = :status;")
        #expect(result.mapping.count == 3)
        #expect(try Redactor.restore(result.text, with: result.mapping).text == sql)
    }

    @Test func sameTableInDifferentSchemas() throws {
        let sql = "SELECT pay.ledger.id, acct.ledger.id FROM pay.ledger JOIN acct.ledger ON pay.ledger.id = acct.ledger.id"
        let result = try Redactor.prepare(sql, mode: .oracle, nonce: nonce)
        #expect(result.mapping.count == 4)
        #expect(result.text.contains("S_A1B2C3D4_01.T_A1B2C3D4_01.id, S_A1B2C3D4_02.T_A1B2C3D4_02.id"))
        #expect(try Redactor.restore(result.text, with: result.mapping).text == sql)
        #expect(throws: RedactionError.self) {
            try Redactor.prepare("SELECT ledger.id FROM pay.ledger, acct.ledger", mode: .oracle)
        }
    }

    @Test func nestedScopeAndCTEShadowing() throws {
        let sql = """
        WITH ledger AS (SELECT i.id FROM raw.ledger i),
             result_rows AS (SELECT ledger.id FROM ledger)
        SELECT r.id FROM result_rows r
        WHERE EXISTS (SELECT r.id FROM accounting.detail r WHERE r.id > 1)
          AND EXISTS (SELECT 1 FROM dual WHERE r.id > 1)
        """
        let result = try Redactor.prepare(sql, mode: .oracle, nonce: nonce)
        #expect(result.text.contains("WITH C_A1B2C3D4_01 AS"))
        #expect(result.text.contains("FROM C_A1B2C3D4_01"))
        #expect(result.text.contains("SELECT A_A1B2C3D4_03.id FROM S_A1B2C3D4_02.T_A1B2C3D4_02 A_A1B2C3D4_03"))
        #expect(result.text.contains("FROM dual WHERE A_A1B2C3D4_02.id"))
        #expect(try Redactor.restore(result.text, with: result.mapping).text == sql)
    }

    @Test func quotedNamesAndInlineView() throws {
        let sql = """
        SELECT "明细📋".id FROM (
          SELECT "Client"."Order".id FROM "Client"."Order"
        ) "明细📋"
        UNION ALL
        SELECT "CLIENT"."ORDER".id FROM "CLIENT"."ORDER"
        """
        let result = try Redactor.prepare(sql, mode: .oracle, nonce: nonce)
        #expect(result.mapping.count == 5)
        #expect(result.text.contains("SELECT A_A1B2C3D4_01.id"))
        #expect(result.text.contains("S_A1B2C3D4_02.T_A1B2C3D4_02.id"))
        #expect(try Redactor.restore(result.text, with: result.mapping).text == sql)
        #expect(try Redactor.restore(#"alias "A_A1B2C3D4_01""#, with: result.mapping).text == #"alias "明细📋""#)
    }

    @Test func ordinaryCommentsAndLiteralSecrets() throws {
        let sql = """
        SELECT e.id, q'[text FROM made_up]' FROM ledger -- internal detail
        e WHERE e.password = 'fake only' AND e.server = '192.0.2.1'
        AND e.status = N'can''t' /* extra
        line */
        """
        let result = try Redactor.prepare(sql, mode: .oracle, nonce: nonce)
        #expect(result.text.contains("q'[text FROM made_up]'"))
        #expect(result.text.contains("password = 'REDACTED_SECRET'"))
        #expect(result.text.contains("'IP_A1B2C3D4_01'"))
        #expect(result.text.contains("N'can''t'"))
        #expect(!result.text.contains("internal detail"))
        #expect(!result.text.contains("extra"))
        #expect(result.text.utf16.filter { $0 == 10 }.count == sql.utf16.filter { $0 == 10 }.count)
        let restored = try Redactor.restore(result.text, with: result.mapping)
        #expect(restored.text.contains("'192.0.2.1'"))
        #expect(!restored.text.contains("fake only"))
    }

    @Test(arguments: [
        "SELECT /*+ INDEX(t real_idx) */ t.id FROM t",
        "SELECT t.id FROM t--+ INDEX(t real_idx)\n",
        "SELECT id FROM t@prod_link",
        "BEGIN SELECT id FROM t; END;",
        "SELECT id FROM a; SELECT id FROM b",
        "SELECT id FROM tbl PIVOT (COUNT(id) FOR name IN (1))",
        "SELECT id FROM TABLE(package.get_rows())",
        "WITH a(x) AS (SELECT 1 FROM dual UNION ALL SELECT x FROM a) SELECT x FROM a",
        "SELECT 'broken FROM accounts",
        "SELECT id FROM (SELECT id FROM accounts",
        "SELECT id FROM a LEFT JOIN b ON ",
        "SELECT id FROM a UNION ",
        "SELECT id FROM a, ",
    ])
    func unsupportedSQLHasNoPreview(sql: String) throws {
        #expect(throws: RedactionError.self) { try Redactor.prepare(sql, mode: .oracle) }
    }

    @Test func logNetworkAndCredentials() throws {
        let log = """
        2026-11-23T12:34:56Z [ERROR] ORA-12541 from 192.0.2.22:1521
        retry 192.0.2.22; endpoint=[2001:db8::1]:443 ipv6=2001:0db8:0:0:0:0:0:1
        mapped=::ffff:198.51.100.17. Authorization: Bearer sampleOnly_7f
        {"api_key":"quoted secret","attempt":2} db_password='sample with spaces'
        https://demo:synthetic@example.com/db
        -----BEGIN OPENSSH PRIVATE KEY-----
        fabricated test fixture
        -----END OPENSSH PRIVATE KEY-----
          at com.example.Connection.open(Connection.java:46)
        """
        let result = try Redactor.prepare(log, mode: .log, nonce: nonce)
        #expect(result.text.contains("2026-11-23T12:34:56Z [ERROR] ORA-12541 from IP_A1B2C3D4_01:1521"))
        #expect(result.text.contains("retry IP_A1B2C3D4_01; endpoint=[IP_A1B2C3D4_02]:443 ipv6=IP_A1B2C3D4_02"))
        #expect(result.text.contains("mapped=IP_A1B2C3D4_03. Authorization: REDACTED_SECRET"))
        #expect(result.text.contains(#"{"api_key":"REDACTED_SECRET","attempt":2}"#))
        #expect(result.text.contains("db_password='REDACTED_SECRET'"))
        #expect(result.text.contains("https://REDACTED_SECRET@example.com/db"))
        #expect(result.text.contains("at com.example.Connection.open(Connection.java:46)"))
        #expect(result.mapping.count == 3)
        #expect(!result.text.contains("fabricated test fixture"))
        #expect(!result.text.contains("sampleOnly_7f"))
        #expect(!result.text.contains("BEGIN OPENSSH"))
        #expect(!(try Redactor.restore(result.text, with: result.mapping).text.contains("quoted secret")))
    }

    @Test func incompletePrivateKeyAndOverlappingIP() throws {
        let log = "token=192.0.2.33\n-----BEGIN RSA PRIVATE KEY-----\ntruncated key"
        let result = try Redactor.prepare(log, mode: .log, nonce: nonce)
        #expect(result.mapping.count == 0)
        #expect(result.text == "token=REDACTED_SECRET\nREDACTED_SECRET")
    }

    @Test func manualRangesAreUnicodeSafeAndIrreversible() throws {
        let source = "客户👩‍💻名 host=192.0.2.7"
        let nsSource = source as NSString
        let a = nsSource.range(of: "客户👩‍💻")
        let b = nsSource.range(of: "192.0")
        let result = try Redactor.prepare(source, mode: .log, manual: [a, b], nonce: nonce)
        #expect(result.text == "REDACTED名 host=REDACTED")
        #expect(result.mapping.count == 0)
        #expect((result.text as NSString).substring(with: result.highlights[1].output) == "REDACTED")
        #expect(throws: RedactionError.self) {
            try Redactor.prepare(source, mode: .log, manual: [NSRange(location: 3, length: 1)])
        }
    }

    @Test func restoreOnlyWholeIdentifiersAndReportAbsentOrForeignTokens() throws {
        let preview = try Redactor.prepare("SELECT * FROM bank.table_1", mode: .oracle, nonce: nonce)
        let changed = "t_a1b2c3d4_01 T_A1B2C3D4_010 T_FFFFFFFF_01 旧T_A1B2C3D4_01 T_A1B2C3D4_typo"
        let output = try Redactor.restore(changed, with: preview.mapping)
        #expect(output.text == "table_1 T_A1B2C3D4_010 T_FFFFFFFF_01 旧T_A1B2C3D4_01 T_A1B2C3D4_typo")
        #expect(output.unknown == 3)
        #expect(output.replaced == 1)
        #expect(output.absent == 1)
    }

    @Test func expirationClearAndReplacement() throws {
        let time = ContinuousClock.now
        var store = SessionStore()
        let first = try Redactor.prepare("ip=192.0.2.2", mode: .log, nonce: nonce)
        let second = try Redactor.prepare("ip=192.0.2.3", mode: .log, nonce: "12345678")
        let blankMap = try Redactor.prepare("password=test-only", mode: .log)
        store.commit(first.mapping, now: time)
        #expect(store.current(now: time.advanced(by: .seconds(1799)))?.id == nonce)
        #expect(store.current(now: time.advanced(by: .seconds(1800))) == nil)
        store.commit(first.mapping, now: time)
        store.commit(second.mapping, now: time)
        #expect(store.current(now: time)?.id == second.mapping.id)
        store.clear()
        #expect(store.current(now: time) == nil)
        store.commit(first.mapping, now: time)
        store.commit(blankMap.mapping, now: time)
        #expect(store.current(now: time) == nil)
    }

    @Test func refusesEmptyOversizeAndCollidingInput() throws {
        #expect(throws: RedactionError.self) { try Redactor.prepare("  \n  ", mode: .log) }
        #expect(throws: RedactionError.self) {
            try Redactor.prepare(String(repeating: "中", count: 90_000), mode: .log)
        }
        #expect(throws: RedactionError.self) {
            try Redactor.prepare("A1B2C3D4 192.0.2.12", mode: .log, nonce: nonce)
        }
    }
}
