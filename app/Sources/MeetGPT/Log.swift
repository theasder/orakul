import os

/// Shared structured logging. Prefer these over `NSLog`/`print`: dynamic
/// interpolations are marked `privacy: .private` so a future accidental
/// secret/PII value is redacted in the unified system log (Console.app /
/// `log show`) by default, instead of being emitted in the clear. Values that
/// are known-safe config (model names, status codes) may be marked `.public`
/// at the call site.
enum Log {
    private static let subsystem = "ai.wheespr.meetgpt"

    static let general    = Logger(subsystem: subsystem, category: "general")
    static let audio      = Logger(subsystem: subsystem, category: "audio")
    static let transcribe = Logger(subsystem: subsystem, category: "transcription")
    static let network    = Logger(subsystem: subsystem, category: "network")
    static let keychain   = Logger(subsystem: subsystem, category: "keychain")
    static let notify     = Logger(subsystem: subsystem, category: "notifications")
}
