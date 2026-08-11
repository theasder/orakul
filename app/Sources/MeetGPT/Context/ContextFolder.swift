import Foundation

/// A folder the user attached as standing context, the way a project folder
/// works in Claude: point at it once and every request sees what is inside.
///
/// Persisted as a security-scoped bookmark rather than a path. A path stops
/// working the moment the app is sandboxed for the App Store — the entitlements
/// already declare `files.user-selected.read-write`, so the bookmark is what
/// carries the user's grant across relaunches instead of silently reading
/// nothing.
struct ContextFolder: Identifiable, Equatable {
    let id: UUID
    /// Display name (the folder's own name, not the whole path).
    let name: String
    /// Full path, shown on hover so two folders called "docs" are tellable apart.
    let path: String
    /// Security-scoped bookmark. Re-resolved on launch; the URL is not stored.
    let bookmark: Data
    /// What the last scan found, already extracted to text.
    var files: [ImportedContextFile]
    /// Files that matched but were left out by a budget or a read failure. Kept
    /// so the UI can say what was dropped — a silent truncation reads as "this
    /// folder is fully attached" when it is not.
    var skipped: [String]
    var scannedAt: Date

    init(id: UUID = UUID(), name: String, path: String, bookmark: Data,
         files: [ImportedContextFile] = [], skipped: [String] = [], scannedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.files = files
        self.skipped = skipped
        self.scannedAt = scannedAt
    }

    var totalChars: Int { files.reduce(0) { $0 + $1.charCount } }
}

/// Scans an attached folder into context files, under explicit budgets.
///
/// The budgets are the whole design. A folder is not a file: pointing at a repo
/// or a Downloads directory can mean thousands of files and megabytes of text,
/// and the cost of sending that is real and per-request. Everything here is
/// tuned to take the useful top slice and SAY what it left behind.
enum ContextFolderScanner {

    /// Per-folder ceilings. Chosen so an attached folder costs about what a
    /// handful of pasted documents costs, not what a codebase costs.
    static let maxFiles = 40
    static let maxTotalChars = 240_000
    static let maxFileChars = 40_000
    /// Raw-input budgets are separate from extracted-character budgets. A tiny
    /// amount of useful text inside a giant document must not make the app read
    /// that giant document during a call.
    static let maxFileBytes: Int64 = 2 * 1_024 * 1_024
    static let maxTotalBytes: Int64 = 8 * 1_024 * 1_024
    /// Enumeration itself is bounded too. This prevents accidentally choosing
    /// a home directory from turning one attachment into an unbounded walk.
    static let maxCandidateFiles = 400
    static let maxEnumeratedEntries = 2_000

    /// Directories that are never worth reading and are usually enormous.
    static let ignoredDirectories: Set<String> = [
        ".git", ".svn", "node_modules", ".build", "build", "dist", "out",
        ".next", ".venv", "venv", "__pycache__", ".idea", ".vscode",
        "DerivedData", "Pods", "target", "vendor", ".terraform", ".cache"
    ]

    /// Extensions worth extracting. Deliberately a allowlist: an unknown binary
    /// read as text is megabytes of noise that costs money to send.
    static let readableExtensions = ContextImporter.supportedExtensions

    enum ScanError: LocalizedError {
        case unresolvable
        case notReadable(String)

        var errorDescription: String? {
            switch self {
            case .unresolvable:
                return "That folder is no longer accessible — re-attach it to grant access again."
            case .notReadable(let detail):
                return "Could not read the folder: \(detail)"
            }
        }
    }

    /// Resolve a stored bookmark back to a usable URL. `isStale` is surfaced to
    /// the caller so it can re-bookmark rather than degrade to reading nothing.
    static func resolve(bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil,
                             relativeTo: nil)
    }

    /// Walk the folder and extract what fits. The complete operation, including
    /// enumeration, runs off the caller's actor: a large project must not stall
    /// typing, transcript scrolling, or a live call.
    static func scan(bookmark: Data) async throws -> (files: [ImportedContextFile], skipped: [String]) {
        let worker = Task.detached(priority: .userInitiated) {
            try await scanOffActor(bookmark: bookmark)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func scanOffActor(bookmark: Data) async throws
        -> (files: [ImportedContextFile], skipped: [String]) {
        try Task.checkCancellation()
        let (folder, _) = try resolve(bookmark: bookmark)
        let needsAccess = folder.startAccessingSecurityScopedResource()
        defer { if needsAccess { folder.stopAccessingSecurityScopedResource() } }
        let urls = try collectURLs(in: folder)

        var files: [ImportedContextFile] = []
        var skipped: [String] = []
        var characterBudget = maxTotalChars
        var byteBudget = maxTotalBytes
        var contentFingerprints: Set<UInt64> = []

        for candidate in urls {
            try Task.checkCancellation()
            let url = candidate.url
            guard files.count < maxFiles else {
                skipped.append(candidate.relativePath)
                continue
            }
            guard characterBudget > 0, byteBudget > 0 else {
                skipped.append(candidate.relativePath)
                continue
            }
            guard candidate.byteCount <= maxFileBytes,
                  candidate.byteCount <= byteBudget else {
                skipped.append(candidate.relativePath)
                continue
            }
            // Count every attempted read, including an unreadable or duplicate
            // document. `maxTotalBytes` is an I/O ceiling, not merely a ceiling
            // on the files that happened to make the final index.
            byteBudget -= candidate.byteCount
            guard var imported = try? await ContextImporter.importFile(at: url) else {
                try Task.checkCancellation()
                skipped.append(candidate.relativePath)
                continue
            }
            // Clip an individual file before it can eat the folder's whole
            // budget, and again to whatever budget is left.
            let allowance = min(maxFileChars, characterBudget)
            if imported.text.count > allowance {
                let marker = "\n… (truncated)"
                let bodyAllowance = max(0, allowance - marker.count)
                imported = ImportedContextFile(
                    id: imported.id,
                    name: candidate.relativePath,
                    text: String(imported.text.prefix(bodyAllowance))
                        + String(marker.prefix(allowance - bodyAllowance)))
            } else {
                imported = ImportedContextFile(
                    id: imported.id,
                    name: candidate.relativePath,
                    text: imported.text)
            }
            let fingerprint = stableFingerprint(imported.text)
            guard contentFingerprints.insert(fingerprint).inserted else {
                skipped.append(candidate.relativePath)
                continue
            }
            characterBudget -= imported.charCount
            files.append(imported)
        }

        return (files, skipped)
    }

    /// Readable files, shallowest first, then alphabetical — so a top-level
    /// README wins the budget over something buried six levels down.
    private struct Candidate {
        let depth: Int
        let relativePath: String
        let byteCount: Int64
        let url: URL
    }

    private static func collectURLs(in folder: URL) throws -> [Candidate] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isPackageKey, .isReadableKey, .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.notReadable("could not enumerate contents")
        }

        var found: [Candidate] = []
        let rootDepth = folder.pathComponents.count
        let canonicalRoot = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        var enumeratedEntries = 0

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            enumeratedEntries += 1
            if enumeratedEntries > maxEnumeratedEntries { break }
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                if values?.isPackage == true
                    || ignoredDirectories.contains(url.lastPathComponent)
                    || url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard values?.isReadable == true,
                  FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard ContextImporter.supports(url) else { continue }

            // Resolve once more even after rejecting links: aliases, unusual
            // file-system mounts, and future enumerator behavior must never let
            // a recursive grant escape the selected directory.
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(rootPrefix) else { continue }
            let relative = String(canonical.path.dropFirst(rootPrefix.count))
            guard !relative.isEmpty,
                  !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }

            guard let fileSize = values?.fileSize else { continue }
            found.append(Candidate(
                depth: url.pathComponents.count - rootDepth,
                relativePath: relative,
                byteCount: Int64(max(0, fileSize)),
                url: canonical))
            if found.count >= maxCandidateFiles { break }
        }

        return found
            .sorted { lhs, rhs in
                lhs.depth == rhs.depth
                    ? lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
                    : lhs.depth < rhs.depth
            }
            .reduce(into: (seen: Set<String>(), values: [Candidate]())) { result, candidate in
                // Canonical-path dedupe removes aliases without collapsing two
                // legitimate case-distinct files on a case-sensitive volume.
                let key = candidate.url.path
                if result.seen.insert(key).inserted { result.values.append(candidate) }
            }.values
    }

    /// A deterministic non-cryptographic fingerprint is sufficient here: this
    /// is only used to avoid paying twice for byte-identical files, never for a
    /// security decision.
    private static func stableFingerprint(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

/// Query-time retrieval over already-scanned folders. Scanning is bounded for
/// memory; retrieval is separately bounded for token economy. A folder may hold
/// 240k extracted characters, but one answer sees only a few relevant excerpts.
enum ContextFolderRetriever {
    static let maxFilesPerPrompt = 6
    static let maxSnippetChars = 2_400
    static let maxTotalChars = 12_000
    static let maxQueryChars = 4_000
    static let maxQueryTerms = 24

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "do",
        "for", "from", "how", "i", "in", "is", "it", "me", "my", "of",
        "on", "or", "please", "that", "the", "this", "to", "we", "what",
        "when", "where", "which", "with", "would", "you"
    ]

    static func render(folders: [ContextFolder], query: String,
                       characterLimit: Int = maxTotalChars,
                       fileLimit: Int = maxFilesPerPrompt) -> String {
        let cap = max(0, min(characterLimit, maxTotalChars))
        let countCap = max(0, min(fileLimit, maxFilesPerPrompt))
        guard cap > 0, countCap > 0, !folders.isEmpty else { return "" }

        let terms = queryTerms(query)
        var candidates: [(score: Int, folder: String, file: ImportedContextFile)] = []
        for folder in folders.sorted(by: folderOrder) {
            for file in folder.files {
                let score = relevance(file: file, terms: terms)
                candidates.append((score, folder.name, file))
            }
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let leftFallback = fallbackPriority($0.file.name)
            let rightFallback = fallbackPriority($1.file.name)
            if leftFallback != rightFallback { return leftFallback > rightFallback }
            let left = "\($0.folder)/\($0.file.name)"
            let right = "\($1.folder)/\($1.file.name)"
            return left.localizedStandardCompare(right) == .orderedAscending
        }

        var output = ""
        var fingerprints: Set<UInt64> = []
        var included = 0
        let hasRelevantMatch = candidates.contains { $0.score > 0 }
        for candidate in candidates {
            guard included < countCap, output.count < cap else { break }
            // When there are useful matches, unrelated files do not get a free
            // ride into the prompt. For an entirely generic request, a small
            // deterministic README-first fallback remains useful.
            if !terms.isEmpty, candidate.score == 0, hasRelevantMatch { continue }
            if !terms.isEmpty, !hasRelevantMatch, included >= 1 { break }
            let fingerprint = stableFingerprint(candidate.file.text)
            guard fingerprints.insert(fingerprint).inserted else { continue }

            let excerpt = snippet(from: candidate.file.text, terms: terms)
            guard !excerpt.isEmpty else { continue }
            let separator = output.isEmpty ? "" : "\n\n"
            let header = "=== Folder: \(candidate.folder)/\(candidate.file.name) ===\n"
            let fixed = separator + header
            let remaining = cap - output.count
            guard remaining > fixed.count else { break }
            let bodyAllowance = min(maxSnippetChars, remaining - fixed.count)
            output += fixed + String(excerpt.prefix(bodyAllowance))
            included += 1
        }
        return String(output.prefix(cap))
    }

    private static func folderOrder(_ lhs: ContextFolder, _ rhs: ContextFolder) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private static func fallbackPriority(_ name: String) -> Int {
        let basename = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        if basename.hasPrefix("readme") { return 3 }
        if basename.contains("overview") || basename.contains("index") { return 2 }
        return 1
    }

    private static func queryTerms(_ query: String) -> [String] {
        let bounded: String
        if query.count <= maxQueryChars {
            bounded = query
        } else {
            // User intent tends to live at the start and the concrete quoted
            // material at the end; retain both without tokenizing an unbounded
            // pasted transcript on the MainActor.
            bounded = String(query.prefix(maxQueryChars / 2))
                + " " + String(query.suffix(maxQueryChars / 2))
        }
        let raw = bounded.lowercased().components(
            separatedBy: CharacterSet.alphanumerics.inverted)
        var seen: Set<String> = []
        var terms: [String] = []
        for term in raw where term.count >= 2 && !stopWords.contains(term) {
            if seen.insert(term).inserted { terms.append(term) }
            if terms.count == maxQueryTerms { break }
        }
        return terms
    }

    private static func relevance(file: ImportedContextFile, terms: [String]) -> Int {
        let name = file.name.lowercased()
        let body = file.text.lowercased()
        guard !terms.isEmpty else {
            let basename = URL(fileURLWithPath: file.name).lastPathComponent.lowercased()
            if basename.hasPrefix("readme") { return 30 }
            if basename.contains("overview") || basename.contains("index") { return 20 }
            return max(1, 10 - file.name.split(separator: "/").count)
        }
        return terms.reduce(into: 0) { score, term in
            if name.contains(term) { score += 40 }
            var searchStart = body.startIndex
            var hits = 0
            while hits < 8,
                  let range = body.range(of: term, range: searchStart..<body.endIndex) {
                hits += 1
                score += 4
                searchStart = range.upperBound
            }
        }
    }

    private static func snippet(from text: String, terms: [String]) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maxSnippetChars else { return clean }
        let lower = clean.lowercased()
        let match = terms.compactMap { lower.range(of: $0)?.lowerBound }.min()
        guard let match else { return String(clean.prefix(maxSnippetChars)) }

        let offset = lower.distance(from: lower.startIndex, to: match)
        let desiredStart = max(0, offset - maxSnippetChars / 3)
        let start = clean.index(clean.startIndex, offsetBy: desiredStart)
        let available = clean.distance(from: start, to: clean.endIndex)
        let end = clean.index(start, offsetBy: min(maxSnippetChars, available))
        let prefix = desiredStart > 0 ? "… " : ""
        let suffix = end < clean.endIndex ? " …" : ""
        return prefix + String(clean[start..<end]) + suffix
    }

    private static func stableFingerprint(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
