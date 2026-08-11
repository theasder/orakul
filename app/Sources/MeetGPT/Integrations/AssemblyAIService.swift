import Foundation

/// One diarized utterance from AssemblyAI.
struct DiarizedUtterance {
    let speaker: String   // "A", "B", …
    let text: String
    let startMs: Int
}

enum AssemblyAIError: LocalizedError {
    case missingKey
    case badURL
    case http(Int)        // status only — never the response body (may echo data)
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingKey:       return "Speaker diarization isn't available in this build."
        case .badURL:           return "Invalid AssemblyAI endpoint."
        case .http(let code):   return "AssemblyAI responded \(code)."
        case .failed(let m):    return "AssemblyAI: \(m)"
        case .timedOut:         return "AssemblyAI transcription timed out."
        }
    }
}

/// Transcribes a recording with speaker diarization via AssemblyAI's async REST
/// API: upload bytes → create transcript (`speaker_labels`) → poll until done.
enum AssemblyAIService {
    private static let base = "https://api.assemblyai.com/v2"
    private static let pollIntervalNs: UInt64 = 3_000_000_000   // 3s
    private static let maxPolls = 200                            // ≈10 min ceiling

    static func diarize(wav: Data, apiKey: String, speakersExpected: Int? = nil,
                        language: String = Config.transcriptionLanguage,
                        session: URLSession = .shared) async throws -> [DiarizedUtterance] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AssemblyAIError.missingKey }

        let audioURL = try await upload(wav, key: key, session: session)
        let id = try await createTranscript(audioURL: audioURL, key: key, speakersExpected: speakersExpected,
                                            keyterms: Config.glossaryTerms,
                                            language: language,
                                            session: session)
        return try await poll(id: id, key: key, session: session)
    }

    /// Diarization speaker hint from the calendar attendee count. The diarized
    /// track is the REMOTE audio, so the local participant (self) is excluded;
    /// nil when unknown, clamped to AssemblyAI's supported 1–10 range.
    static func speakersExpected(attendeeCount: Int) -> Int? {
        let remote = attendeeCount - 1   // exclude the local user (not on the system track)
        guard remote >= 1 else { return nil }
        return min(remote, 10)
    }

    /// The `POST /transcript` request body. Pure — extracted for testing the
    /// speaker-label / speakers-expected / custom-vocabulary plumbing.
    static func transcriptPayload(audioURL: String, speakersExpected: Int?, keyterms: [String],
                                  language: String = Config.transcriptionLanguage) -> [String: Any] {
        var payload: [String: Any] = ["audio_url": audioURL, "speaker_labels": true]
        if let speakersExpected { payload["speakers_expected"] = speakersExpected }
        if language == "multi" || language.isEmpty {
            // AssemblyAI requires this nested flag for mixed-language files;
            // language_detection alone only chooses one dominant language.
            payload["language_detection"] = true
            payload["language_detection_options"] = [
                "code_switching": true
            ]
        } else {
            payload["language_code"] = language
        }
        // Custom vocabulary — word_boost biases recognition toward these terms.
        if !keyterms.isEmpty { payload["word_boost"] = keyterms }
        return payload
    }

    // MARK: Steps

    private static func upload(_ data: Data, key: String, session: URLSession) async throws -> String {
        guard let url = URL(string: base + "/upload") else { throw AssemblyAIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600   // large WAV (up to ~115 MB) needs headroom
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (body, response) = try await session.upload(for: request, from: data)
        try check(response)
        guard let json = json(body) else { throw AssemblyAIError.failed("upload: invalid JSON response") }
        guard let uploadURL = json["upload_url"] as? String else { throw AssemblyAIError.failed("upload: missing upload_url") }
        return uploadURL
    }

    private static func createTranscript(audioURL: String, key: String, speakersExpected: Int?,
                                         keyterms: [String] = [], language: String,
                                         session: URLSession) async throws -> String {
        guard let url = URL(string: base + "/transcript") else { throw AssemblyAIError.badURL }
        let payload = transcriptPayload(audioURL: audioURL, speakersExpected: speakersExpected,
                                        keyterms: keyterms, language: language)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (body, response) = try await session.data(for: request)
        try check(response)
        guard let json = json(body) else { throw AssemblyAIError.failed("create: invalid JSON response") }
        guard let id = json["id"] as? String else { throw AssemblyAIError.failed("create: missing transcript id") }
        return id
    }

    private static func poll(id: String, key: String, session: URLSession) async throws -> [DiarizedUtterance] {
        guard let url = URL(string: base + "/transcript/\(id)") else { throw AssemblyAIError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "Authorization")

        for _ in 0..<maxPolls {
            let body: Data
            let response: URLResponse
            do {
                (body, response) = try await session.data(for: request)
            } catch {
                // Transient transport hiccup — wait and retry within the ceiling.
                try await Task.sleep(nanoseconds: pollIntervalNs)
                continue
            }
            try check(response)
            guard let json = json(body) else { throw AssemblyAIError.failed("poll: invalid JSON response") }

            switch json["status"] as? String {
            case "completed":
                let utterances = (json["utterances"] as? [[String: Any]]) ?? []
                return try utterances.compactMap { utterance in
                    guard let speaker = utterance["speaker"] as? String,
                          let text = utterance["text"] as? String, !text.isEmpty else { return nil }
                    guard let start = intOrNil(utterance["start"]) else {
                        throw AssemblyAIError.failed("malformed utterance (start not a number)")
                    }
                    return DiarizedUtterance(speaker: speaker, text: text, startMs: start)
                }
            case "error":
                throw AssemblyAIError.failed((json["error"] as? String) ?? "transcription error")
            default:
                try await Task.sleep(nanoseconds: pollIntervalNs)
            }
        }
        throw AssemblyAIError.timedOut
    }

    // MARK: Helpers

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AssemblyAIError.http(http.statusCode)
        }
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func intOrNil(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return nil
    }
}
