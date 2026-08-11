import Foundation

/// Removes secrets from text on its way to a model.
///
/// Nothing inspected the transcript, attached context or connector snippets
/// before they left the machine. A card number read aloud on a call, an API key
/// pasted into a doc that got attached, a bearer token echoed back by a
/// connector — all of it went verbatim to a provider.
///
/// Deterministic detectors rather than a classifier: card numbers, keys and
/// government IDs have strong structural signatures, so patterns do this
/// offline, testably, and with a failure mode you can read. A probabilistic
/// filter over a privacy promise fails silently and cannot be audited.
///
/// **Redacts and proceeds; never blocks.** A false positive then costs a
/// slightly poorer answer rather than a dead end, and the user can see what was
/// withheld and correct it — you cannot correct a redaction on an answer you
/// never received.
///
/// The hard requirement is the opposite of aggression. This runs over MEETING
/// SPEECH, which is full of ordinary numbers: dates, prices, headcounts, room
/// numbers, percentages. A filter that eats those destroys the product to
/// protect it, so every detector here demands structural evidence — a Luhn
/// check, a known key prefix, a labelled field — and never merely a shape.
enum OutboundRedactor {

    struct Finding: Equatable {
        enum Kind: String, Equatable {
            case paymentCard
            case apiKey
            case governmentID
            case credential
            case userTerm
        }
        let kind: Kind
        /// What was replaced, so a session-level correction can name it.
        let matched: String
    }

    struct Result: Equatable {
        let text: String
        let findings: [Finding]
        var didRedact: Bool { !findings.isEmpty }
    }

    static let marker = "[redacted]"

    /// Key prefixes that are unambiguous by construction — no ordinary sentence
    /// contains them.
    static let keyPrefixes = [
        "sk-", "sk_live_", "sk_test_", "pk_live_", "rk_live_",
        "ghp_", "gho_", "ghu_", "ghs_", "github_pat_",
        "xoxb-", "xoxp-", "xoxa-", "AKIA", "ASIA",
        "AIza", "ya29.", "SG.", "hf_", "glpat-",
    ]

    /// Redact `text`, returning what was removed.
    static func redact(_ text: String, userTerms: [String] = []) -> Result {
        guard !text.isEmpty else { return Result(text: text, findings: []) }
        var output = text
        var findings: [Finding] = []

        // User terms first: the user asked for these by name, so they win over
        // any heuristic about whether they look sensitive.
        for term in userTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            while let range = output.range(of: trimmed, options: [.caseInsensitive]) {
                findings.append(Finding(kind: .userTerm, matched: String(output[range])))
                output.replaceSubrange(range, with: marker)
            }
        }

        // PEM private-key blocks first: they span multiple lines, so the
        // token splitter below would never see them whole. Unambiguous by
        // construction — no meeting transcript contains a BEGIN PRIVATE KEY
        // armour line — which is the same rationale the key-prefix list uses.
        output = redactPEMBlocks(in: output, findings: &findings)

        output = replaceTokens(in: output, findings: &findings) { token in
            if let prefix = keyPrefixes.first(where: { token.hasPrefix($0) }),
               token.count >= prefix.count + 8 {
                return .apiKey
            }
            // A JWT is a bearer credential: pasted from an auth header or a
            // debug log, the whole session token would otherwise go to the
            // provider. Its three-part base64url structure is distinctive
            // enough to catch without a label.
            if isJWT(token) { return .credential }
            if isPaymentCard(token) { return .paymentCard }
            if isGovernmentID(token) { return .governmentID }
            return nil
        }

        output = redactLabelledCredentials(in: output, findings: &findings)
        return Result(text: output, findings: findings)
    }

    // MARK: - Detectors

    /// A payment card: 13–19 digits that PASS LUHN.
    ///
    /// The Luhn check is what makes this safe on meeting speech. Without it,
    /// "the contract is 4532015112830366 lines long" and a 16-digit order
    /// number are indistinguishable from a card; with it, the false-positive
    /// rate on arbitrary digit runs is about one in ten.
    static func isPaymentCard(_ token: String) -> Bool {
        let digits = token.filter(\.isNumber)
        guard digits.count >= 13, digits.count <= 19 else { return false }
        // Separators are allowed, but nothing else — a long word with digits in
        // it is not a card.
        guard token.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }) else { return false }
        return passesLuhn(digits)
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard let value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return sum % 10 == 0 && !digits.isEmpty
    }

    /// A US-shaped SSN: `123-45-6789`. Requires the separators.
    ///
    /// Nine bare digits are far too common in speech — a phone number, an
    /// order id, a figure — so the hyphenated form is the only one taken.
    static func isGovernmentID(_ token: String) -> Bool {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 3, parts[1].count == 2, parts[2].count == 4,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        // 000, 666 and 900+ are never issued; excluding them removes a slab of
        // ordinary number sequences.
        guard let area = Int(parts[0]), area != 0, area != 666, area < 900 else { return false }
        return true
    }

    /// A JSON Web Token: three base64url segments joined by dots, the first
    /// decoding to a `{"..."` header — which is what makes `eyJ` its universal
    /// start. Length-bounded so a short dotted identifier is not mistaken for
    /// one.
    static func isJWT(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        guard token.hasPrefix("eyJ") else { return false }
        let base64url = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        // Header and payload carry real content; the signature may be empty on
        // an unsigned token, so only the first two segments must be substantial.
        guard parts[0].count >= 8, parts[1].count >= 8 else { return false }
        return parts.allSatisfy { segment in
            !segment.isEmpty && segment.unicodeScalars.allSatisfy(base64url.contains)
                || segment.isEmpty
        }
    }

    // MARK: - Internals

    private static func replaceTokens(in text: String,
                                      findings: inout [Finding],
                                      classify: (String) -> Finding.Kind?) -> String {
        var output: [String] = []
        var localFindings: [Finding] = []
        // Split on whitespace only, so punctuation stays attached and is
        // stripped per token — a card at the end of a sentence keeps its stop.
        for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
            let raw = String(piece)
            let core = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'"))
            if !core.isEmpty, let kind = classify(core) {
                localFindings.append(Finding(kind: kind, matched: core))
                output.append(raw.replacingOccurrences(of: core, with: marker))
            } else {
                output.append(raw)
            }
        }
        findings.append(contentsOf: localFindings)
        return output.joined(separator: " ")
    }

    /// PEM-armoured private keys: everything between a BEGIN and END line,
    /// inclusive. Matches RSA, EC, OPENSSH and generic PRIVATE KEY blocks. The
    /// armour is the evidence, so the body is never inspected — a partial or
    /// malformed key between real armour lines is still a key, and still goes.
    private static func redactPEMBlocks(in text: String,
                                        findings: inout [Finding]) -> String {
        guard text.contains("-----BEGIN") else { return text }
        let pattern = "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let full = NSRange(text.startIndex..., in: text)
        var output = text
        // Replace from the back so earlier ranges stay valid.
        for match in regex.matches(in: text, range: full).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            findings.append(Finding(kind: .credential, matched: "PRIVATE KEY block"))
            output.replaceSubrange(range, with: marker)
        }
        return output
    }

    /// `password: hunter2`, `Authorization: Bearer abc…` — a labelled secret.
    ///
    /// The label is the evidence. Without it, "hunter2" is a word.
    private static func redactLabelledCredentials(in text: String,
                                                  findings: inout [Finding]) -> String {
        let labels = ["password", "passwd", "secret", "api_key", "apikey",
                      "access_token", "refresh_token", "client_secret", "bearer"]
        var output = text
        for line in text.components(separatedBy: .newlines) {
            let lowered = line.lowercased()
            guard let label = labels.first(where: { lowered.contains($0) }) else { continue }
            // Take what follows the separator on that line.
            guard let separatorIndex = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let value = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.count >= 6, !value.contains(" ") else { continue }
            findings.append(Finding(kind: .credential, matched: value))
            output = output.replacingOccurrences(of: value, with: marker)
            _ = label
        }
        return output
    }
}
