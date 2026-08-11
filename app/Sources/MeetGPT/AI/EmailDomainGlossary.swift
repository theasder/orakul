import Foundation

/// Glossary candidates from the sign-in email's domain.
///
/// A corporate domain names the employer, and the employer's name is the term
/// most likely to be spoken on every call this account ever records — said in
/// the first minute, and worth spelling right before any app is connected or
/// any agenda is pasted. A freemail domain names nobody, so it yields nothing.
///
/// Candidates feed the same `GlossaryAutoApply` gate as connected-app
/// suggestions: bounded, deduplicated against the existing glossary, and
/// never re-proposed after a rejection.
enum EmailDomainGlossary {

    /// Providers whose domain says "person", not "company". Includes the
    /// Russian and Chinese majors — this product's audience uses them.
    static let freemailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "msn.com", "yahoo.com", "ymail.com", "icloud.com", "me.com", "mac.com",
        "proton.me", "protonmail.com", "pm.me", "aol.com", "gmx.com", "gmx.de",
        "gmx.net", "web.de", "fastmail.com", "hey.com", "zoho.com", "mail.com",
        "yandex.ru", "yandex.com", "ya.ru", "mail.ru", "bk.ru", "inbox.ru",
        "list.ru", "internet.ru", "rambler.ru", "qq.com", "163.com", "126.com",
        "foxmail.com", "sina.com", "naver.com", "daum.net", "hanmail.net",
        "example.com", "test.com",
    ]

    /// Second-level labels that are part of the public suffix, not the name:
    /// "acme.co.uk" is Acme, not "Co".
    private static let publicSecondLevels: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne",
    ]

    /// Freemail brands appear under many country TLDs — yahoo.co.uk,
    /// yandex.kz, outlook.de — so the registrable label is checked too.
    private static let freemailBrands: Set<String> = [
        "gmail", "googlemail", "yahoo", "ymail", "hotmail", "outlook", "live",
        "msn", "yandex", "icloud", "proton", "protonmail", "gmx", "aol",
        "qq", "foxmail", "naver", "daum", "hanmail", "rambler", "fastmail",
        "zoho", "mail", "inbox",
    ]

    /// A label this short is said letter by letter — "IBM", not "Ibm".
    private static let acronymMaximumLength = 3

    static func candidates(fromEmail email: String) -> [String] {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = cleaned.lastIndex(of: "@") else { return [] }
        let domain = String(cleaned[cleaned.index(after: at)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard domain.contains("."), !freemailDomains.contains(domain) else { return [] }

        var labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return [] }
        labels.removeLast()                       // the TLD proper
        if let last = labels.last, publicSecondLevels.contains(last), labels.count >= 2 {
            labels.removeLast()                   // co.uk, com.au, ac.jp …
        }
        // The registrable label is the company; subdomains (mail., corp.) are
        // plumbing.
        guard let company = labels.last, !company.isEmpty,
              !freemailBrands.contains(company) else { return [] }

        let words = company.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let name = words.map { word in
            word.count <= acronymMaximumLength && words.count == 1
                ? word.uppercased()
                : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        return [name]
    }
}
