import Foundation
import RedactionCore
import Testing

private let nonce = "ABCD0123"

@Suite("增强预览")
struct PrivacyOptionsTests {
    @Test func extraRulesAreOptIn() throws {
        let text = "联系 analyst+oncall@example.test。Endpoint https://db1.internal.test:8443/v1"
        let defaults = try Redactor.prepare(text, mode: .log)
        #expect(defaults.text == text)
        #expect(defaults.highlights.isEmpty)

        let options = RedactionOptions(emails: true)
        let emailOnly = try Redactor.prepare(text, mode: .log, options: options, nonce: nonce)
        #expect(emailOnly.text == "联系 EMAIL_ABCD0123_01。Endpoint https://db1.internal.test:8443/v1")
        #expect(try Redactor.restore(emailOnly.text, with: emailOnly.mapping).text == text)
    }

    @Test func URLHostsPreserveContextAndShareAnAlias() throws {
        let log = """
        mail=ops@example.test url=https://alice.name@reports.internal.test:9443/v1
        retry=https://reports.internal.test./v2 instance=jdbc:oracle:thin:@//db.internal.test:1521/service
        literal=http://192.0.2.17:8080/v1 ipv6=https://[2001:db8::7]:443
        """
        let options = RedactionOptions(emails: true, urlHosts: true)
        let result = try Redactor.prepare(log, mode: .log, options: options, nonce: nonce)
        #expect(result.text == """
        mail=EMAIL_ABCD0123_01 url=https://REDACTED_SECRET@HOST_ABCD0123_01:9443/v1
        retry=https://HOST_ABCD0123_01./v2 instance=jdbc:oracle:thin:@//HOST_ABCD0123_02:1521/service
        literal=http://IP_ABCD0123_01:8080/v1 ipv6=https://[IP_ABCD0123_02]:443
        """)
        #expect(result.mapping.count == 5)
        let restored = try Redactor.restore(result.text, with: result.mapping)
        #expect(restored.text == log.replacingOccurrences(of: "alice.name", with: "REDACTED_SECRET"))
        #expect(restored.unknown == 0)
        #expect(restored.absent == 0)
        let unknown = try Redactor.restore("HOST_FAFC8955_01 EMAIL_FAFC8955_02", with: result.mapping)
        #expect(unknown.unknown == 2)
    }

    @Test func detectedCredentialsStayIrreversibleWithPrivacyOptions() throws {
        let source = "api_key='admin@internal.test' connect=https://demo:fake@example.test/v1"
        let options = RedactionOptions(emails: true, urlHosts: true)
        let result = try Redactor.prepare(source, mode: .log, options: options, nonce: nonce)
        #expect(result.text == "api_key='REDACTED_SECRET' connect=https://REDACTED_SECRET@HOST_ABCD0123_01/v1")
        #expect(result.mapping.count == 1)
        let restored = try Redactor.restore(result.text, with: result.mapping)
        #expect(restored.text == "api_key='REDACTED_SECRET' connect=https://REDACTED_SECRET@example.test/v1")
    }

    @Test func SQLStringOptionPreservesQuoteSyntaxAndBindings() throws {
        let source = "SELECT q'[owner@internal.test]', N'can''t', '' FROM ledger WHERE status = :status AND password = 'dummy-value'"
        let options = RedactionOptions(emails: true, urlHosts: true, sqlStrings: true)
        let result = try Redactor.prepare(source, mode: .oracle, options: options, nonce: nonce)
        #expect(result.text == "SELECT q'[REDACTED_STRING]', N'REDACTED_STRING', '' FROM T_ABCD0123_01 WHERE status = :status AND password = 'REDACTED_SECRET'")
        #expect(result.mapping.count == 1)
        #expect(result.highlights.filter { $0.category == .literal }.count == 2)
        let restored = try Redactor.restore(result.text, with: result.mapping)
        #expect(restored.text.contains("FROM ledger WHERE status = :status"))
        #expect(!restored.text.contains("internal.test"))
        #expect(!restored.text.contains("dummy-value"))

        let emailOnly = try Redactor.prepare(source, mode: .oracle, options: RedactionOptions(emails: true), nonce: nonce)
        #expect(emailOnly.text.contains("q'[EMAIL_ABCD0123_01]'"))
        #expect(try Redactor.restore(emailOnly.text, with: emailOnly.mapping).text.contains("q'[owner@internal.test]'"))
    }

    @Test func matchingUsesExactUnicodeText() throws {
        let text = "👩‍💻租户, 👩‍💻租户; 👨‍💻租户"
        let source = text as NSString
        let selection = source.range(of: "👩‍💻租户")
        let ranges = Redactor.matchingRanges(for: selection, in: text)
        #expect(ranges.count == 2)
        let result = try Redactor.prepare(text, mode: .log, manual: ranges)
        #expect(result.text == "REDACTED, REDACTED; 👨‍💻租户")
        #expect(result.mapping.count == 0)
        #expect(Redactor.matchingRanges(for: source.range(of: "💻"), in: text).isEmpty)
    }

    @Test func repeatMatchingKeepsTheSelectedOccurrence() throws {
        let text = "aBaBa"
        let ranges = Redactor.matchingRanges(for: NSRange(location: 2, length: 3), in: text)
        let result = try Redactor.prepare(text, mode: .log, manual: ranges)
        #expect(result.text == "REDACTED")
        let base = "Private private Private"
        let match = (base as NSString).range(of: "Private")
        let caseSensitive = try Redactor.prepare(
            base, mode: .log, manual: Redactor.matchingRanges(for: match, in: base)
        )
        #expect(caseSensitive.text == "REDACTED private REDACTED")
    }
}
