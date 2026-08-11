import Foundation

/// Sends audio chunks to OpenAI's Whisper endpoint.
/// Endpoint: POST /v1/audio/transcriptions (multipart/form-data).
final class WhisperAPITranscription: TranscriptionService {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let session: URLSession
    private let apiKey: String
    private let model: String
    private let language: String
    private let glossary: String

    init(session: URLSession = .shared,
         apiKey: String = Config.openAIAPIKey,
         model: String = Config.transcriptionModel,
         language: String = Config.transcriptionLanguage,
         glossary: String = Config.transcriptionGlossary) {
        self.session = session
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.glossary = glossary
    }

    /// Internal regression seam matching the local engine's recording snapshot.
    func languageSnapshot() -> String { language }
    func glossarySnapshot() -> String { glossary }

    func transcribe(wav: Data) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Whisper", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Cloud transcription isn't available in this build — the on-device engine (the default) needs no key."])
        }
        guard wav.count <= 25 * 1024 * 1024 else {
            throw NSError(domain: "Whisper", code: 413,
                          userInfo: [NSLocalizedDescriptionKey: "Audio is too large to transcribe (max ~25 MB / ~13 min). Use a shorter clip."])
        }

        let boundary = "meetgpt-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(to: &body, boundary: boundary, name: "model", value: model)
        appendField(to: &body, boundary: boundary, name: "response_format", value: "json")
        // Omit the optional field in Auto so every uploaded chunk is detected
        // independently and speakers can change languages during a meeting.
        if let language = Self.languageField(language) {
            appendField(to: &body, boundary: boundary, name: "language", value: language)
        }
        // Custom vocabulary as the decoder prompt — biases toward the team's
        // specialized spellings.
        let glossaryHint = Glossary.promptHint(from: glossary)
        if !glossaryHint.isEmpty {
            appendField(to: &body, boundary: boundary, name: "prompt", value: glossaryHint)
        }
        appendFile(to: &body, boundary: boundary, name: "file",
                   filename: "audio.wav", mime: "audio/wav", data: wav)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (responseData, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw NSError(domain: "Whisper",
                          code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Whisper API error: \(body)"])
        }

        struct TranscriptionResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: responseData)
        return TranscriptArtifacts.clean(decoded.text)
    }

    static func languageField(_ configuredLanguage: String) -> String? {
        let language = configuredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty || language == "multi" ? nil : language
    }

    private func appendField(to body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFile(to body: inout Data, boundary: String, name: String,
                            filename: String, mime: String, data: Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }
}
