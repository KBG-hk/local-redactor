import Foundation
import RedactionCore
import Testing

private struct Trial: Sendable {
    let title: String
    let mode: RedactionMode
    let source: String
    let hidden: [String]
    let clues: [String]
}

private let trials: [Trial] = [
    Trial(title: "日期过滤", mode: .oracle,
          source: "SELECT id FROM LEDGER_OWNER.MONTHLY_ENTRIES WHERE TRUNC(posted_at) = :posting_day",
          hidden: ["LEDGER_OWNER", "MONTHLY_ENTRIES"], clues: ["TRUNC(posted_at) = :posting_day"]),
    Trial(title: "关联过滤", mode: .oracle,
          source: "SELECT a.id FROM PRIVATE_ACCOUNTS a JOIN PRIVATE_EVENTS e ON a.id = e.account_id WHERE e.kind = :kind",
          hidden: ["PRIVATE_ACCOUNTS", "PRIVATE_EVENTS"], clues: [".id = ", ".account_id", ".kind = :kind"]),
    Trial(title: "相关子查询", mode: .oracle,
          source: "SELECT r.id FROM PRIVATE_BATCH r WHERE EXISTS (SELECT 1 FROM PRIVATE_ITEMS i WHERE i.batch_id = r.id)",
          hidden: ["PRIVATE_BATCH", "PRIVATE_ITEMS"], clues: ["WHERE EXISTS (SELECT 1", ".batch_id = "]),
    Trial(title: "窗口函数去重", mode: .oracle,
          source: "SELECT v.id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY series_id ORDER BY observed_at DESC) rn FROM INTERNAL_TICKS) v WHERE v.rn = 1",
          hidden: ["INTERNAL_TICKS"], clues: ["PARTITION BY series_id ORDER BY observed_at DESC", ".rn = 1"]),
    Trial(title: "CTE 预聚合", mode: .oracle,
          source: "WITH sensitive_total AS (SELECT account_id, SUM(value) total FROM PRIVATE_LINES GROUP BY account_id) SELECT q.total FROM sensitive_total q WHERE q.total > :threshold",
          hidden: ["sensitive_total", "PRIVATE_LINES"], clues: ["SUM(value)", "GROUP BY account_id", ".total > :threshold"]),
    Trial(title: "重复记录", mode: .oracle,
          source: "SELECT id FROM PRIVATE_CURRENT WHERE id = :id UNION SELECT id FROM PRIVATE_ARCHIVE WHERE id = :id",
          hidden: ["PRIVATE_CURRENT", "PRIVATE_ARCHIVE"], clues: ["UNION SELECT", "WHERE id = :id"]),
    Trial(title: "Oracle 监听", mode: .log,
          source: "ORA-12541: TNS:no listener (host 192.0.2.31 port 1521)",
          hidden: ["192.0.2.31"], clues: ["ORA-12541", "TNS:no listener", "port 1521"]),
    Trial(title: "连接池耗尽", mode: .log,
          source: "pool=maxPool active=30 idle=0 acquireTimeoutMs=15000 endpoint=[2001:db8::80]:1521",
          hidden: ["2001:db8::80"], clues: ["active=30 idle=0", "acquireTimeoutMs=15000", ":1521"]),
    Trial(title: "HTTP 鉴权", mode: .log,
          source: "HTTP 401 endpoint=192.0.2.41\nAuthorization: Bearer synthetic-expired-value\nWWW-Authenticate: Bearer error=invalid_token",
          hidden: ["192.0.2.41", "synthetic-expired-value"], clues: ["HTTP 401", "invalid_token"]),
    Trial(title: "SQL 异常栈", mode: .log,
          source: "jdbc:oracle:thin:@192.0.2.50:1521/service ORA-01017\npassword=\"synthetic-wrong-value\"\n at demo.db.connect(DemoDB.java:52)",
          hidden: ["192.0.2.50", "synthetic-wrong-value"], clues: ["ORA-01017", "DemoDB.java:52", "jdbc:oracle:thin"]),
]

@Suite("代表性试用样本")
struct TrialTests {
    @Test(arguments: 0..<trials.count)
    func preservesDiagnosticClues(index: Int) throws {
        let trial = trials[index]
        let result = try Redactor.prepare(trial.source, mode: trial.mode, nonce: "ABCD1234")
        for hidden in trial.hidden {
            #expect(!result.text.contains(hidden))
        }
        for clue in trial.clues {
            #expect(result.text.contains(clue))
        }
        let restored = try Redactor.restore(result.text, with: result.mapping)
        #expect(restored.unknown == 0)
        #expect(restored.absent == 0)
        if trial.mode == .oracle {
            #expect(restored.text == trial.source)
        }
        if ProcessInfo.processInfo.environment["LOCAL_REDACTOR_SHOW_TRIALS"] == "1" {
            print("TRIAL \(index + 1) \(trial.title)\n\(result.text)\nEND TRIAL \(index + 1)")
        }
    }

    @Test func obscuresRawDigestAndPGPBlocks() throws {
        let text = """
        Authorization: Digest username="demo", nonce="synthetic", response="fake-hash"
        -----BEGIN PGP PRIVATE KEY BLOCK-----
        fake-test-body
        -----END PGP PRIVATE KEY BLOCK-----
        ORA-01017
        """
        let result = try Redactor.prepare(text, mode: .log)
        #expect(result.mapping.count == 0)
        #expect(result.text == "Authorization: REDACTED_SECRET\nREDACTED_SECRET\nORA-01017")
    }
}
