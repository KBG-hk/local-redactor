import Darwin
import Foundation

enum SensitiveRules {
    private struct Rule {
        let pattern: NSRegularExpression
        let group: Int

        init(_ pattern: String, group: Int = 0) {
            self.pattern = try! NSRegularExpression(pattern: pattern)
            self.group = group
        }
    }

    private static let credentialFields = #"password|passwd|pwd|api[_-]?key|client[_-]?secret|private[_-]?key|secret(?:[_-]?(?:access[_-]?)?key)?|(?:access[_-]?|refresh[_-]?|auth[_-]?)?token"#

    private static let rules: [Rule] = [
        Rule(#"(?is)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|\z)"#),
        Rule(#"(?im)(?<![\w-])(?:proxy-)?authorization["']?[ \t]*[:=][ \t]*("[^"\r\n]*"|'[^'\r\n]*'|Digest[ \t]+[^\r\n}\]]+|(?:Bearer|Basic|Token)[ \t]+[^\r\n,;}\]]+|[^\s,;}\]]+)"#, group: 1),
        Rule(#"(?i)(?<![\w.-])(?:[a-z][\w.-]*[_.-])?(?:\#(credentialFields))["']?[ \t]*[:=][ \t]*("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|"[^\r\n]*|'[^\r\n]*|[^\s,;&}\]]+)"#, group: 1),
        Rule(#"(?<![\w-])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{12,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)(?![\w-])"#),
    ]

    private static let urlStart = #"(?<![\p{L}\p{N}+.-])(?:[a-z][a-z0-9+.-]*://|jdbc:oracle:thin:@//)"#
    private static let userInfo = #"[^/\s?#@"'<>(){}\[\]\\]+"#
    private static let dnsLabel = #"[\p{L}\p{N}](?:[\p{L}\p{N}-]*[\p{L}\p{N}])?"#
    private static let dnsName = #"\#(dnsLabel)(?:\.\#(dnsLabel))*"#
    private static let urlCredentials = try! NSRegularExpression(
        pattern: #"(?i)\#(urlStart)(\#(userInfo))@"#
    )
    private static let urlHosts = try! NSRegularExpression(
        pattern: #"(?i)\#(urlStart)(?:\#(userInfo)@)?(\#(dnsName))(?=\.?(?:[:/?#\s"',;)\]}]|\z))"#
    )
    private static let emails = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.%+!-])[\p{L}\p{N}_%+!-]+(?:\.[\p{L}\p{N}_%+!-]+)*@\#(dnsName)\.[\p{L}]{2,63}(?![\p{L}\p{N}_-]|\.[\p{L}\p{N}])"#
    )

    private static let ipv4 = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![\p{L}\p{N}_]|\.[0-9])"#
    )
    private static let ipv6 = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_:.])[a-f0-9:]*:[a-f0-9:.]*:[a-f0-9:.]*(?:%[a-z0-9_.-]+)?(?![\p{L}\p{N}_:])"#
    )
    private static let credentialName = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[_.-])(?:authorization|\#(credentialFields))$"#
    )

    static func isCredentialField(_ text: String) -> Bool {
        credentialName.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    static func detect(_ text: String, offset: Int = 0, options: RedactionOptions) -> [Edit] {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        var result: [Edit] = []
        for rule in rules {
            for match in rule.pattern.matches(in: text, range: full) {
                var found = match.range(at: rule.group)
                guard found.length > 0 else { continue }
                if rule.group == 1, found.length > 1 {
                    let first = source.character(at: found.location)
                    if (first == 34 || first == 39), source.character(at: NSMaxRange(found) - 1) == first {
                        found = NSRange(location: found.location + 1, length: found.length - 2)
                    }
                }
                guard found.length > 0 else { continue }
                result.append(Edit(NSRange(location: offset + found.location, length: found.length), .secret))
            }
        }

        let credentials = urlCredentials.matches(in: text, range: full).map { $0.range(at: 1) }
        for span in credentials {
            result.append(Edit(NSRange(location: offset + span.location, length: span.length), .secret))
        }

        if options.emails {
            let authoritySeparators = Set(credentials.map(NSMaxRange))
            for match in emails.matches(in: text, range: full) {
                let span = match.range
                let separator = source.range(of: "@", options: .literal, range: span).location
                // A URL username and its hostname can look like an email address.
                guard !authoritySeparators.contains(separator) else { continue }
                result.append(Edit(NSRange(location: offset + span.location, length: span.length), .email))
            }
        }
        if options.urlHosts {
            for match in urlHosts.matches(in: text, range: full) {
                let span = match.range(at: 1)
                let host = source.substring(with: span)
                guard ipv4Key(host) == nil else { continue }
                result.append(Edit(NSRange(location: offset + span.location, length: span.length), .host, key: host.lowercased()))
            }
        }

        // Match IPv6 first so embedded IPv4 addresses remain one replacement.
        var ipv6Ranges: [NSRange] = []
        for match in ipv6.matches(in: text, range: full) {
            var span = match.range
            while span.length > 0, source.character(at: NSMaxRange(span) - 1) == 46 {
                span.length -= 1
            }
            guard span.length > 1 else { continue }
            let address = source.substring(with: span)
            let host = String(address.prefix { $0 != "%" })
            var parsed = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else { continue }
            let key = withUnsafeBytes(of: &parsed) { Data($0).base64EncodedString() }
            let zone = address.dropFirst(host.count)
            ipv6Ranges.append(span)
            result.append(Edit(NSRange(location: offset + span.location, length: span.length), .ip, key: key + zone))
        }

        var ipv6Index = 0
        for match in ipv4.matches(in: text, range: full) {
            while ipv6Index < ipv6Ranges.count, NSMaxRange(ipv6Ranges[ipv6Index]) <= match.range.location {
                ipv6Index += 1
            }
            if ipv6Index < ipv6Ranges.count, NSIntersectionRange(ipv6Ranges[ipv6Index], match.range).length > 0 {
                continue
            }
            let address = source.substring(with: match.range)
            guard let key = ipv4Key(address) else { continue }
            result.append(Edit(NSRange(location: offset + match.range.location, length: match.range.length), .ip, key: key))
        }
        return result
    }

    private static func ipv4Key(_ address: String) -> String? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.map(String.init).joined(separator: ".")
    }
}
