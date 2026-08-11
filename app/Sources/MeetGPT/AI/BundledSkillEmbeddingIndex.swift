import Foundation
import NaturalLanguage

/// Produces fixed-length unit vectors for skill / query text.
protocol SkillTextEmbedder: Sendable {
    /// Returns a unit-length embedding, or nil when the model can't encode `text`.
    func embed(_ text: String) -> [Float]?
}

/// On-device sentence embeddings via Apple's NaturalLanguage framework.
/// No network, no LLM call — the model ships with macOS.
final class NLSkillTextEmbedder: SkillTextEmbedder, @unchecked Sendable {
    static let shared = NLSkillTextEmbedder()

    private let embedding: NLEmbedding?
    /// NLEmbedding is NOT thread-safe: concurrent `vector(for:)` calls corrupt
    /// CoreNLP's heap (nanov2 guard abort — SIGABRT under the parallel test
    /// runner, and the same race exists in-app between the background copilot
    /// loops and a prompt-button ranking). Every CoreNLP call is serialized.
    private let lock = NSLock()

    init(language: NLLanguage = .english) {
        self.embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    var isAvailable: Bool { embedding != nil }

    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let embedding else { return nil }
        // Cap input — sentence models degrade / waste work on huge transcripts.
        let clipped = trimmed.count > 2_000 ? String(trimmed.prefix(2_000)) : trimmed
        lock.lock()
        let vector = embedding.vector(for: clipped)
        lock.unlock()
        guard let vector, !vector.isEmpty else { return nil }
        return VectorMath.l2Normalize(vector.map { Float($0) })
    }
}

/// Deterministic hashed bag-of-tokens embedder for unit tests (no NL model).
struct HashingSkillTextEmbedder: SkillTextEmbedder {
    var dimensions: Int = 64

    func embed(_ text: String) -> [Float]? {
        let tokens = BundledSkillRelevance.tokens(in: text)
        guard !tokens.isEmpty, dimensions > 0 else { return nil }
        var vec = [Float](repeating: 0, count: dimensions)
        for token in tokens {
            var hash: UInt64 = 5381
            for b in token.utf8 {
                hash = ((hash << 5) &+ hash) &+ UInt64(b)
            }
            let idx = Int(hash % UInt64(dimensions))
            let sign: Float = (hash & 1) == 0 ? 1 : -1
            vec[idx] += sign
        }
        return VectorMath.l2Normalize(vec)
    }
}

enum VectorMath {
    static func l2Normalize(_ vector: [Float]) -> [Float]? {
        var sum: Float = 0
        for v in vector { sum += v * v }
        let norm = sqrt(sum)
        guard norm > 1e-8 else { return nil }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity for unit (or unnormalized) vectors. Range roughly [-1, 1].
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 1e-8 else { return 0 }
        return Double(dot / denom)
    }
}

/// Cached on-device embeddings for the vendored skill catalog.
/// Built once (lazily / on warm), then cosine-ranked at prompt-button press.
final class BundledSkillEmbeddingIndexStore: @unchecked Sendable {
    static let shared = BundledSkillEmbeddingIndexStore()

    /// Also coordinates the one cold catalog build. Prompt clicks can race the
    /// launch-time warmer; without a `building` state both callers embedded all
    /// 1,188 skills independently before either could set `built`.
    private let lock = NSCondition()
    private var embedder: (any SkillTextEmbedder)?
    private var vectorsByID: [String: [Float]] = [:]
    private var built = false
    private var building = false

    /// Last query vectors, keyed by query text.
    ///
    /// `rank` embeds the query once, but `BundledSkillRelevance` then calls
    /// `similarity` once per candidate — roughly thirty times with the SAME
    /// query — and each call re-ran NLEmbedding. One prompt-button press paid for
    /// ~30 redundant embeds. Small ring buffer rather than an unbounded map: a
    /// query is a transcript slice, so the cache would otherwise grow with the
    /// meeting.
    private var queryVectors: [String: [Float]] = [:]
    private var queryOrder: [String] = []
    private static let queryCacheLimit = 32

    /// Embed with the cache. Caller must NOT hold `lock`.
    private func queryVector(_ query: String, embedder: any SkillTextEmbedder) -> [Float]? {
        lock.lock()
        if let hit = queryVectors[query] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let vector = embedder.embed(query) else { return nil }

        lock.lock()
        if queryVectors[query] == nil {
            queryVectors[query] = vector
            queryOrder.append(query)
            while queryOrder.count > Self.queryCacheLimit {
                queryVectors.removeValue(forKey: queryOrder.removeFirst())
            }
        }
        lock.unlock()
        return vector
    }

    private init() {
        let nl = NLSkillTextEmbedder.shared
        embedder = nl.isAvailable ? nl : nil
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return built && !vectorsByID.isEmpty
    }

    var cachedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return vectorsByID.count
    }

    func resetForTests(embedder: (any SkillTextEmbedder)?) {
        lock.lock()
        while building { lock.wait() }
        defer { lock.unlock() }
        self.embedder = embedder
        vectorsByID = [:]
        queryVectors = [:]
        queryOrder = []
        built = false
    }

    func ensureBuilt(library: [BundledSkill]) {
        lock.lock()
        while building && !built { lock.wait() }
        if built {
            lock.unlock()
            return
        }
        building = true
        let embedder = self.embedder
        lock.unlock()

        guard let embedder else {
            lock.lock()
            built = true
            building = false
            lock.broadcast()
            lock.unlock()
            return
        }

        var builtMap: [String: [Float]] = [:]
        builtMap.reserveCapacity(library.count)
        for skill in library {
            if let vector = embedder.embed(BundledSkillEmbeddingIndex.documentText(for: skill)) {
                builtMap[skill.id] = vector
            }
        }

        lock.lock()
        if !built {
            vectorsByID = builtMap
            built = true
        }
        building = false
        lock.broadcast()
        lock.unlock()
    }

    func similarity(query: String, skillID: String, library: [BundledSkill]) -> Double? {
        ensureBuilt(library: library)
        lock.lock()
        let vector = vectorsByID[skillID]
        let embedder = self.embedder
        lock.unlock()
        guard let vector, let embedder,
              let queryVector = queryVector(query, embedder: embedder) else { return nil }
        return VectorMath.cosineSimilarity(queryVector, vector)
    }


    func rank(query: String, library: [BundledSkill], limit: Int) -> [(skill: BundledSkill, score: Double)] {
        ensureBuilt(library: library)
        lock.lock()
        let snapshot = vectorsByID
        let embedder = self.embedder
        lock.unlock()
        guard let embedder, let queryVector = queryVector(query, embedder: embedder),
              !snapshot.isEmpty else {
            return []
        }

        var scored: [(BundledSkill, Double)] = []
        scored.reserveCapacity(min(library.count, limit * 2))
        for skill in library {
            guard let vector = snapshot[skill.id] else { continue }
            let sim = VectorMath.cosineSimilarity(queryVector, vector)
            if sim > 0.05 {
                scored.append((skill, sim))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map { (skill: $0.0, score: $0.1) }
    }
}

/// Facade over the shared embedding store.
enum BundledSkillEmbeddingIndex {
    static var isReady: Bool { BundledSkillEmbeddingIndexStore.shared.isReady }
    static var cachedCount: Int { BundledSkillEmbeddingIndexStore.shared.cachedCount }

    static func resetForTests(embedder: (any SkillTextEmbedder)?) {
        BundledSkillEmbeddingIndexStore.shared.resetForTests(embedder: embedder)
    }

    static func documentText(for skill: BundledSkill) -> String {
        let idWords = skill.id.replacingOccurrences(of: "-", with: " ")
        var parts: [String] = []
        if !skill.name.isEmpty { parts.append(skill.name) }
        if !skill.description.isEmpty { parts.append(skill.description) }
        parts.append(idWords)
        return parts.joined(separator: ". ")
    }


    static func ensureBuilt(library: [BundledSkill] = BundledSkillLibrary.all) {
        BundledSkillEmbeddingIndexStore.shared.ensureBuilt(library: library)
    }

    static func similarity(query: String, skillID: String,
                           library: [BundledSkill] = BundledSkillLibrary.all) -> Double? {
        BundledSkillEmbeddingIndexStore.shared.similarity(
            query: query, skillID: skillID, library: library)
    }

    static func rank(
        query: String,
        library: [BundledSkill],
        limit: Int
    ) -> [(skill: BundledSkill, score: Double)] {
        BundledSkillEmbeddingIndexStore.shared.rank(query: query, library: library, limit: limit)
    }

}
