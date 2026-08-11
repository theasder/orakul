import Foundation

/// The ICP's vocabulary, shipped: product managers at VC-backed companies.
///
/// Every entry is restore-actionable — an acronym, a digit-bearing term, a
/// CamelCase product name, or a multi-word name — because the lexicon rides
/// `GlossaryRestore` (text-level, measured WER-neutral at scale) and restore
/// can only fix casing and garbles. Plain words are excluded as no-ops, and
/// the decoder prompt never sees any of this: prompts collapse at 25 terms.
///
/// **The collision audit is the curation.** An entry whose normalised form is
/// a common English word would recase prose: SAFE would rewrite "a safe
/// choice", SAM someone's name, IT the pronoun, US the pronoun, REST the
/// noun, Linear the adjective, Zoom the verb, Whisper the noun. Every entry
/// below survived that check; when in doubt a term stays out, because a wrong
/// recasing is worse than a missing one. Acronym families ship together
/// (CTO/CTR/CPC/CPA…) so the rival-term rule protects each from being
/// fuzzy-repaired into a neighbour.
enum DomainLexicon {

    static let productManagement: [String] = [
        // Revenue and unit economics
        "ARR", "MRR", "NRR", "NDR", "GRR", "ARPU", "ARPA", "ACV", "TCV",
        "CAC", "LTV", "ROI", "ROAS", "GMV", "AOV", "COGS", "EBITDA", "CAGR",
        "FCF", "IRR", "DPI", "TVPI", "MOIC", "AUM",
        // Product and growth metrics
        "NPS", "CSAT", "DAU", "WAU", "MAU", "PMF", "TAM", "SOM",
        "YoY", "MoM", "QoQ", "K-factor",
        // Roles
        "CEO", "CTO", "CPO", "CFO", "COO", "CMO", "CRO", "CISO", "CIO",
        "VP", "PM", "PMM", "IC", "HR", "GM", "PR", "BD",
        "SDR", "BDR", "AE", "CSM", "SRE", "QA", "UX", "UI", "EIR",
        // Go-to-market
        "GTM", "ICP", "PLG", "SLG", "ABM", "SEO", "SEM", "ASO", "PPC",
        "CTR", "CPC", "CPM", "CPA", "CPL", "UTM",
        "B2B", "B2C", "B2B2C", "D2C", "SMB",
        // Process and planning
        "OKR", "KPI", "PRD", "MVP", "RFC", "SLA", "SLO", "SLI",
        "QBR", "WBR", "RACI", "DACI", "SWOT", "JTBD", "ETA", "EOD",
        // Fundraising and corporate
        "VC", "LP", "GP", "YC", "a16z", "IPO", "ESOP", "RSU", "SPV", "SPAC",
        "NDA", "MOU", "LOI", "IP", "Series A", "Series B", "Series C",
        "Y Combinator", "Sequoia", "TechCrunch", "G2",
        // AI stack and practitioner slang. Plurals come free ("LLMs", "GPUs")
        // via the inflection branch; lowercase slang ("evals", "agentic") is
        // untouchable by design — restore cannot act on a plain word.
        "AI", "ML", "LLM", "GPT", "GPT-4", "GPT-4o", "GPT-5", "RAG", "MCP",
        "NLP", "OCR", "TTS", "ASR", "STT", "AGI", "ASI", "GPU", "TPU", "CPU",
        "RLHF", "SFT", "DPO", "MoE", "SOTA", "OSS", "GA", "PoC", "A2A",
        "MMLU", "SWE-bench", "GenAI", "MLOps", "DevOps",
        "zero-shot", "few-shot", "fine-tuning", "AI-native", "AI-first",
        "OpenAI", "Anthropic", "Claude", "Claude Code", "ChatGPT", "Gemini",
        "Llama", "Mistral", "Midjourney", "DALL-E", "Hugging Face",
        "LangChain", "DeepSeek", "Qwen", "Perplexity", "NotebookLM",
        "Replit", "Windsurf", "Ollama", "xAI", "DeepMind", "NVIDIA", "CUDA",
        // Engineering-adjacent
        "API", "SDK", "SQL", "NoSQL", "JSON", "YAML", "XML", "HTML", "CSS",
        "TypeScript", "JavaScript", "Python", "GraphQL", "gRPC", "JWT",
        "SSO", "OAuth", "SAML", "MFA", "2FA", "CLI", "IDE", "CI",
        "SaaS", "PaaS", "IaaS", "GDPR", "CCPA", "HIPAA", "PII",
        "SOC 2", "ISO 27001",
        "Kubernetes", "K8s", "Docker", "Terraform", "GitHub", "GitLab",
        "PostgreSQL", "MySQL", "MongoDB", "Redis", "Firebase", "Supabase",
        "Vercel", "Snowflake", "Databricks", "BigQuery", "Kafka", "Grafana",
        "Datadog", "PagerDuty",
        // Product, analytics and revenue tools
        // "Confluence" is deliberately absent, on the same rule that keeps out
        // Zoom, Segment and Whisper: measured on a real webinar transcript it
        // recased "around that confluence" — the ordinary English word — and a
        // wrong recasing costs more than a missing one.
        "Jira", "Notion", "Figma", "Slack", "Miro", "Canva",
        "Airtable", "Asana", "Trello", "Webflow", "Retool", "Zapier", "n8n",
        "Calendly", "Amplitude", "Mixpanel", "PostHog", "Pendo", "Hotjar",
        "FullStory", "Tableau", "Metabase", "Looker",
        "Salesforce", "HubSpot", "Marketo", "Intercom", "Zendesk", "Stripe",
        "Plaid", "Twilio", "SendGrid", "Mailchimp", "Braze", "OneSignal",
        "LaunchDarkly", "Optimizely", "Statsig", "Gong", "Apollo", "Fivetran",
        // Distribution surfaces
        "LinkedIn", "YouTube", "TikTok", "Instagram", "Product Hunt",
        // Spoken internet vernacular. Only shapes that survive being SAID
        // aloud on a call and pass the collision audit — "GOAT" stays out
        // (the animal), "based"/"mid"/"cooked" are plain words restore can
        // never touch, which is exactly the protection working.
        "ASAP", "FYI", "FOMO", "YOLO", "IRL", "AMA", "ELI5", "PSA", "OOO",
        "WFH", "PTO", "LGTM", "GG", "NPC", "POV", "TL;DR", "TBH", "NGL",
        "FWIW", "IMO", "IYKYK", "DM", "DEI", "ESG", "UGC", "CTA", "10x",
    ]

    // MARK: - Vertical packs (F7)

    /// A vocabulary that only some meetings need.
    ///
    /// The base lexicon ships to everyone because every VC-backed PM says ARR
    /// and OKR. Vertical words do not travel: PCI in a healthcare call, or NDC
    /// in a payments call, is vocabulary the room never uses, and every term
    /// that cannot appear is a term that can only misfire. So a pack carries
    /// its own activation `signals` and loads for one session at a time.
    struct Pack: Equatable {
        let id: String
        let label: String
        /// Lowercased trigger words. One is enough — these are words a meeting
        /// in that vertical says in the first minutes, and nowhere else.
        let signals: [String]
        let terms: [String]
    }

    /// At most this many packs load at once. Two is a real case (a fintech
    /// company's compliance call is fintech + security); three means the
    /// signals are too loose and the vocabulary stops being a lexicon.
    static let maxActivePacks = 2

    static let verticalPacks: [Pack] = [
        Pack(id: "fintech", label: "Fintech & payments",
             signals: ["chargeback", "kyc", "pci", "interchange", "underwriting",
                       "payments", "acquirer", "aml", "payout", "settlement"],
             terms: [
                "KYC", "KYB", "AML", "CDD", "EDD", "SAR", "PEP", "OFAC", "BSA",
                "PCI", "PCI DSS", "PSD2", "SCA", "3DS", "MCC", "BIN",
                "ACH", "SEPA", "SWIFT", "IBAN", "BIC", "RTP", "FedNow", "P2P",
                "APR", "APY", "NIM", "GPV", "TPV", "FX", "PnL", "KYT",
                "BNPL", "POS", "ISO 8583", "EMV", "AVS", "CVV",
                "FDIC", "FinCEN", "SEC", "FINRA", "CFPB", "MSB",
                "Adyen", "Marqeta", "Modern Treasury",
             ]),
        Pack(id: "healthtech", label: "Healthcare & life sciences",
             signals: ["hipaa", "patient", "clinician", "ehr", "payer",
                       "provider network", "phi", "clinical", "prior authorization"],
             terms: [
                "PHI", "ePHI", "BAA", "HITECH", "HL7", "FHIR", "EHR", "EMR",
                "CPT", "ICD-10", "NPI", "NDC", "SNOMED", "LOINC", "RxNorm",
                "CMS", "FDA", "IRB", "PHR", "RCM", "HCC", "DRG",
                "EOB", "ACO", "HMO", "PPO", "TPA",
                "IEC 62304", "ISO 13485", "510(k)", "PMA", "GxP", "GCP",
                "Epic", "Cerner", "Athenahealth", "Redox",
             ]),
        Pack(id: "devtools", label: "Developer tools & infrastructure",
             signals: ["latency", "p99", "deploy", "incident", "observability",
                       "kubernetes", "runtime", "self-hosted", "throughput"],
             terms: [
                "p50", "p95", "p99", "QPS", "RPS", "TPS", "MTTR", "MTBF",
                "RTO", "RPO", "DAG", "ETL", "ELT", "CDC",
                "WebSocket", "SSE", "CRDT", "RBAC", "ABAC",
                "CI/CD", "IaC", "VPC", "CDN", "DNS", "TLS", "mTLS", "WAF",
                "OTel", "OpenTelemetry", "eBPF", "WASM", "ARM64", "x86",
                "GPU", "TPU", "vCPU", "IOPS", "TTL", "CVE", "SBOM",
                "AWS", "GCP", "Azure", "Cloudflare", "Fastly", "HashiCorp",
             ]),
        Pack(id: "ecommerce", label: "E-commerce & marketplaces",
             signals: ["merchant", "sku", "fulfillment", "basket", "listing",
                       "marketplace", "returns rate", "shopper", "catalog"],
             terms: [
                "SKU", "ASIN", "UPC", "EAN", "GTIN", "PLP", "PDP",
                "RPV", "CVR", "ATC", "COD", "3PL", "4PL",
                "FBA", "FBM", "MSRP", "MAP", "GMROI", "DSO",
                "ERP", "PIM", "OMS", "WMS", "TMS", "EDI",
                "Shopify", "BigCommerce", "WooCommerce", "Magento", "Klaviyo",
                "Algolia", "ShipBob", "Recharge",
             ]),
    ]

    /// Packs whose vocabulary this meeting visibly needs, strongest first.
    ///
    /// Signal counting, not fuzzy matching: a pack that loads on a single
    /// ambiguous word would ship the whole vertical into an unrelated call.
    /// Ties are broken by declaration order so activation is deterministic.
    static func activePacks(for context: String) -> [Pack] {
        let haystack = context.lowercased()
        return verticalPacks
            .map { pack in (pack, pack.signals.filter { haystack.contains($0) }.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(maxActivePacks)
            .map(\.0)
    }

    /// The casing-only vocabulary for one session: the ICP lexicon always,
    /// plus whichever verticals the meeting signalled. Deduplicated — a term
    /// listed twice would run restore over the same text twice for nothing.
    static func casingOnlyTerms(for context: String) -> [String] {
        var seen = Set(productManagement.map { $0.lowercased() })
        var terms = productManagement
        for pack in activePacks(for: context) {
            for term in pack.terms where seen.insert(term.lowercased()).inserted {
                terms.append(term)
            }
        }
        return terms
    }
}
