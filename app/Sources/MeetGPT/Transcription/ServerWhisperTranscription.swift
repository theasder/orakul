import Foundation

/// Sends audio chunks to Cruxwing's managed Whisper gateway (`POST /api/transcribe`).
/// Provider keys and the large-v3 upstream stay on the server; the Mac only
/// needs `BACKEND_URL` + a signed-in Wheespr session.
final class ServerWhisperTranscription: TranscriptionService {
    private let session: URLSession
    private let language: String
    private let glossary: String
    private let tokenProvider: () async -> String?

    init(session: URLSession = BackendPinning.shared,
         language: String = Config.transcriptionLanguage,
         glossary: String = Config.transcriptionGlossary,
         tokenProvider: @escaping () async -> String? = { await WheesprAuth.validAccessToken() }) {
        self.session = session
        self.language = language
        self.glossary = glossary
        self.tokenProvider = tokenProvider
    }

    /// Internal regression seam matching the other engines' recording snapshot.
    func languageSnapshot() -> String { language }
    func glossarySnapshot() -> String { glossary }

    func transcribe(wav: Data) async throws -> String {
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw NSError(domain: "CruxwingWhisper", code: 503,
                          userInfo: [NSLocalizedDescriptionKey: "Cruxwing Whisper needs BACKEND_URL configured in this build."])
        }
        guard let token = await tokenProvider(), !token.isEmpty else {
            throw NSError(domain: "CruxwingWhisper", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Sign in to use Cruxwing Whisper large-v3 on our servers."])
        }
        guard wav.count <= 25 * 1024 * 1024 else {
            throw NSError(domain: "CruxwingWhisper", code: 413,
                          userInfo: [NSLocalizedDescriptionKey: "Audio is too large to transcribe (max ~25 MB / ~13 min). Use a shorter clip."])
        }

        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(root)/api/transcribe") else {
            throw NSError(domain: "CruxwingWhisper", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid BACKEND_URL for Cruxwing Whisper."])
        }

        let boundary = "meetgpt-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendField(to: &body, boundary: boundary, name: "response_format", value: "json")
        // Omit language in Auto so each chunk is detected independently.
        if let language = WhisperAPITranscription.languageField(language) {
            appendField(to: &body, boundary: boundary, name: "language", value: language)
        }
        let glossaryHint = Glossary.promptHint(from: glossary)
        if !glossaryHint.isEmpty {
            appendField(to: &body, boundary: boundary, name: "prompt", value: glossaryHint)
        }
        appendFile(to: &body, boundary: boundary, name: "file",
                   filename: "audio.wav", mime: "audio/wav", data: wav)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (responseData, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: responseData)
                ?? String(data: responseData, encoding: .utf8)
                ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            throw NSError(domain: "CruxwingWhisper",
                          code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cruxwing Whisper: \(message)"])
        }

        struct TranscriptionResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: responseData)
        return TranscriptArtifacts.clean(decoded.text)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String, !error.isEmpty else { return nil }
        return error
    }

    private func appendField(to body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append(value.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
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
