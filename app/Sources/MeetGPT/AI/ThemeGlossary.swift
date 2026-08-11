import Foundation

/// Topic-routed glossary: the vocabulary specific to the KIND of call, loaded
/// once the call's theme is known.
///
/// `DomainLexicon.productManagement` is the always-on ICP default; this adds the
/// terms that only a legal / engineering / fundraising / sales / hiring call
/// actually uses, keyed on the `CallTheme` already inferred from the goal +
/// transcript (no model call). The transcript decides the topic, not the terms:
/// the theme classifier reads the gist and survives ASR errors — a call about
/// routing is still "engineering" even when "PCE" came back as "piece" — so the
/// CORRECT term then loads from here and `GlossaryRestore` repairs the garble.
/// This is deliberately NOT mining terms out of the transcript, which the whisper
/// work measured worse (a mishearing teaches the engine its own mistake).
///
/// Every entry rides `GlossaryRestore` (text-level, measured WER-neutral), so it
/// must be **restore-actionable and collision-safe**, exactly the `DomainLexicon`
/// discipline: an acronym, a digit-bearing token, a CamelCase product, or a
/// multi-word name — NEVER a plain lowercase word, because "clause", "contract",
/// "renewal", "churn", "pipeline", "vesting", "safe" would recase ordinary prose.
/// When a domain term is an everyday word it stays OUT; a wrong recasing is worse
/// than a missing one. The structural invariant (every term carries an uppercase
/// letter, a digit, a hyphen, a slash, or a space) is pinned by a test.
enum ThemeGlossary {

    /// The theme-specific casing glossary to layer on top of the default. Empty
    /// for themes whose vocabulary the PM default already covers.
    static func terms(for theme: CallTheme) -> [String] {
        switch theme {
        case .sales:
            return ["MEDDIC", "MEDDPICC", "MEDDICC", "BANT", "SPIFF", "ICP", "MQL", "SAL",
                    "POC", "RFP", "RFI", "MSA", "SOW", "ACV", "TCV", "OTE", "QBR"]
        case .hiring:
            return ["ATS", "HRIS", "EEOC", "RSU", "ESPP", "PTO", "PIP", "DEI", "ERG",
                    "JD", "401k", "H-1B", "EOR", "PEO"]
        case .engineering:
            return ["API", "SDK", "CLI", "CI", "CD", "gRPC", "GraphQL", "OAuth", "JWT",
                    "CORS", "CDN", "DNS", "TLS", "mTLS", "SSH", "SSL", "ORM", "RBAC", "ACL",
                    "CRUD", "SLA", "SLO", "SLI", "k8s", "Kubernetes", "Postgres", "PostgreSQL",
                    "Redis", "Kafka", "WebSocket", "WebRTC", "IPv4", "IPv6", "BGP", "VPC",
                    "IAM", "SQL", "NoSQL", "CIDR", "TCP", "UDP", "HTTP", "HTTPS", "GPU",
                    "WAF", "KMS", "ETL", "LLM", "RAG", "YAML", "JSON", "p95", "p99", "P0", "P1"]
        case .fundraising:
            return ["ARR", "MRR", "NRR", "LTV", "CAC", "409A", "SPV", "LP", "GP", "IRR",
                    "TVPI", "DPI", "MOIC", "AUM", "VC", "PE", "SaaS", "CAGR",
                    "pre-money", "post-money", "cap table", "term sheet", "pro rata", "83(b)"]
        case .customerSuccess:
            return ["QBR", "NPS", "CSAT", "NRR", "GRR", "CSM", "TTV", "SLA",
                    "time to value", "health score"]
        case .legal:
            return ["NDA", "GDPR", "CCPA", "DPA", "MSA", "SOW", "LOI", "MOU", "EULA", "SLA",
                    "HIPAA", "PII", "PHI", "SOC 2", "ISO 27001", "CDA", "force majeure"]
        case .strategy:
            return ["SWOT", "PESTEL", "TAM", "SAM", "SOM", "BHAG"]
        case .leadership:
            return ["PIP", "IDP", "IC"]
        case .standup:
            return ["WIP", "ETA", "EOD", "PR"]
        case .product, .general:
            // The PM default (DomainLexicon.productManagement) already carries the
            // product vocabulary; a general call has no specialised lexicon.
            return []
        }
    }
}
