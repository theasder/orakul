import Foundation

/// On-device (WhisperKit) model options + a hardware-aware default. Bigger
/// models are more accurate but heavier; Apple Silicon's Neural Engine runs the
/// balanced model in real time, Intel Macs stay on the fast one. The variant
/// ids are the unambiguous WhisperKit repo folders (argmaxinc/whisperkit-coreml)
/// — the download resolver globs `*<variant>/*`, so only clean folder names are
/// listed (the turbo builds carry size suffixes that don't resolve reliably).
enum LocalWhisperModel {
    struct Option: Identifiable, Equatable {
        let id: String       // WhisperKit variant, e.g. "small"
        let title: String    // advantage-first
        let caption: String
        /// Download size for THIS variant, as a user-facing string.
        ///
        /// Separate from `caption` because onboarding has to state the size of
        /// the model this particular Mac will fetch. It used to hardcode
        /// "~150 MB", which is only true for `base`: a 16 GB Apple Silicon
        /// machine downloads ~480 MB and an M-series Max/Ultra ~1.5 GB, so the
        /// promise was out by 10x on exactly the hardware most likely to be
        /// on a metered connection.
        let approxDownload: String
    }

    /// Captions describe the measured difference rather than an adjective.
    ///
    /// Measured 2026-08-09 over the WHOLE 16-recording corpus, one method for
    /// every model (whole-file pass, no glossary — `RealCallTranscriptionHarness.modelSweep`):
    ///
    ///     base                  WER 0.2361   term recall 0.519   0.08x realtime
    ///     small                 WER 0.1919   term recall 0.657   0.13x
    ///     medium                WER 0.1844   term recall 0.657   0.31x
    ///     large-v3              WER 0.1704   term recall 0.657   0.57x
    ///     large-v3-v20240930    WER 0.1775   term recall 0.724   0.15x
    ///
    /// These replace captions quoting base 0.26 / small 0.21 / large-v3 0.14.
    /// Those numbers were real but not comparable: each model's mean came from a
    /// DIFFERENT subset of recordings, and base's was measured only on the five
    /// clean Western ones — it had never been run on the accented corpus at all,
    /// which is precisely where the caption claimed the gap widened.
    ///
    /// Two consequences. The gaps are smaller than advertised: large over small
    /// is 11% fewer errors, not "about a third". And `medium` is not worth
    /// offering — it buys 0.008 WER over small for 2.4x the time.
    static let options: [Option] = [
        .init(id: "base",     title: "Fast",
              caption: "Lowest latency, lightest download (~145 MB). Best on Intel Macs. Noticeably weaker on domain terms — it catches about half where the larger models catch three quarters.",
              approxDownload: "~145 MB"),
        .init(id: "small",    title: "Balanced",
              caption: "About 19% fewer errors than Fast and much better on names and jargon, still comfortably real-time on Apple Silicon (~480 MB).",
              approxDownload: "~480 MB"),
        .init(id: largeVariant, title: "Most accurate",
              caption: "Best on domain terms by a clear margin — catches roughly three quarters against two thirds for Balanced — and around 8% fewer errors overall. Heaviest (~1.5 GB).",
              approxDownload: "~1.5 GB"),
    ]

    /// Size of the model THIS Mac will actually download, for onboarding copy.
    ///
    /// Resolves the same way the engine does: an explicit choice in Settings
    /// wins, otherwise the hardware default. Falls back to the `base` figure
    /// only if the id is unrecognised, which is the smallest claim and so the
    /// safest one to make when unsure.
    static func approxDownloadForThisMac(
        selected: String? = nil,
        isAppleSilicon: Bool = Hardware.isAppleSilicon
    ) -> String {
        let id = migrated(selected ?? recommendedDefault(isAppleSilicon: isAppleSilicon))
        return options.first { $0.id == id }?.approxDownload ?? "~145 MB"
    }

    /// The large build the app actually uses.
    ///
    /// Explicit rather than "large-v3", which is AMBIGUOUS: WhisperKit resolves
    /// the model string by matching repo folders, and two cached builds contain
    /// that substring. They are not interchangeable — measured on the same
    /// corpus, plain large-v3 runs at 0.57x realtime while this one runs at
    /// 0.15x, a difference a user feels immediately on a live call.
    ///
    /// This build is chosen despite a marginally higher WER (0.1775 against
    /// 0.1704) because it is nearly four times faster and materially better at
    /// the thing this product needs most: term recall 0.724 against 0.657. WER
    /// counts every word equally; getting the participant's name and the project
    /// right is worth more than getting "the" right, and recall is the measure
    /// that says so.
    static let largeVariant = "large-v3-v20240930"

    /// Ids that older installs may have saved, mapped to what they mean now.
    static func migrated(_ id: String) -> String {
        id == "large-v3" ? largeVariant : id
    }

    static func isKnown(_ id: String) -> Bool { options.contains { $0.id == id } }

    /// Accuracy-preserving downgrade ladder. `tiny` is intentionally not used
    /// until its mixed-language behavior has been validated in this app.
    static func nextLighter(than id: String) -> String? {
        switch id {
        case largeVariant, "large-v3": return "small"
        case "small": return "base"
        default: return nil
        }
    }

    static func title(for id: String) -> String {
        options.first(where: { $0.id == id })?.title ?? id
    }

    /// First Apple Silicon generation whose Pro-class Neural Engine comfortably
    /// holds large-v3 in real time on BOTH capture tracks at once.
    ///
    /// A call transcribes two concurrent streams — the meeting (ScreenCaptureKit)
    /// and the microphone — so the sustained load is roughly double what a
    /// single-stream benchmark suggests. An M1 Pro fits large-v3 in memory and
    /// runs it, then heats the chassis and starts missing real time once the
    /// second stream joins; that is the reported failure, not a memory limit.
    static let largeModelMinimumProGeneration = 3

    /// Hardware-aware default — pure for testing. Local transcription is the
    /// offline/signed-out fallback (quality lives on the VPS), so the default
    /// must be one the machine carries WITHOUT running hot for an hour:
    ///  - Max/Ultra Apple Silicon with ≥16 GB → large-v3.
    ///  - Pro from generation 3 on, with ≥16 GB → large-v3. EARLIER Pro chips
    ///    (M1/M2 Pro) get `small`: they were previously handed large-v3 purely
    ///    on RAM, which is what cooked them under two-stream load.
    ///  - Plain M-chips (every fanless Air, base minis) and low-memory
    ///    machines → small.
    ///  - Intel → base (no Neural Engine; large would run far off realtime).
    /// RAM alone is NOT capability: a 24 GB fanless Air fits large-v3 and
    /// still throttles — the runtime thermal watchdog guards even user
    /// overrides.
    static func recommendedDefault(isAppleSilicon: Bool,
                                   memoryGB: Double = Hardware.physicalMemoryGB,
                                   chipTier: Hardware.AppleChipTier? = Hardware.appleChipTier(),
                                   chipGeneration: Int? = Hardware.appleChipGeneration()) -> String {
        guard isAppleSilicon, memoryGB >= 16 else {
            return isAppleSilicon ? "small" : "base"
        }
        switch chipTier {
        case .max, .ultra:
            return largeVariant
        case .pro:
            // Unknown generation is treated as OLD: the cost of guessing high is
            // a hot machine and dropped captions, the cost of guessing low is
            // slightly softer accuracy on a fallback engine.
            return (chipGeneration ?? 0) >= largeModelMinimumProGeneration ? largeVariant : "small"
        case .plain, .none:
            return "small"
        }
    }
}

/// Minimal, runtime hardware probe.
enum Hardware {
    /// Whether the CPU is Apple Silicon (arm64), read at runtime via sysctl so
    /// it stays correct even when an x86_64 slice runs under Rosetta.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return ok == 0 && value == 1
    }

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Apple Silicon performance class, parsed from the CPU brand string
    /// ("Apple M1 Pro", "Apple M4 Max", …). Plain chips power the fanless
    /// Airs and base minis — the sustained-load heat-risk class.
    enum AppleChipTier: Equatable {
        case plain, pro, max, ultra
    }

    /// Generation digit from the CPU brand string: "Apple M1 Pro" → 1,
    /// "Apple M4 Max" → 4. nil when the string is not an Apple M-series name.
    static func appleChipGeneration(brand: String = cpuBrandString) -> Int? {
        let lowered = brand.lowercased()
        guard let range = lowered.range(of: "apple m") else { return nil }
        let digits = lowered[range.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    static func appleChipTier(brand: String = cpuBrandString) -> AppleChipTier? {
        let lowered = brand.lowercased()
        guard lowered.contains("apple m") else { return nil }
        if lowered.contains("ultra") { return .ultra }
        if lowered.contains("max") { return .max }
        if lowered.contains("pro") { return .pro }
        return .plain
    }

    static var cpuBrandString: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        return String(cString: chars)
    }
}
