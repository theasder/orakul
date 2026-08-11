import Foundation

/// Post-call speaker labels through the backend, with no vendor key of the
/// user's own.
///
/// D34 parked speaker labels as BYO-AssemblyAI for the MVP because proxying
/// them meant standing up a second vendor relationship. `gpt-4o-transcribe-diarize`
/// removes that reason: it runs on the OpenAI key the server already holds, at
/// the same $0.006/min as the existing whisper-1 bridge, so it is metered from
/// the compute credits the user has already bought.
///
/// Returns `DiarizedUtterance` — the same type `AssemblyAIService` produces — so
/// the merge path in `AppState` is identical and the two engines stay
/// interchangeable. Whichever runs, the caller's code does not change.
enum ServerDiarizationService {
    enum Failure: LocalizedError {
        case notConfigured
        case notSignedIn
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Speaker labels need a backend — set BACKEND_URL, or use a BYO AssemblyAI key."
            case .notSignedIn:
                return "Sign in to label speakers — the pass is metered against your compute credits."
            case .http(let code, let message):
                return message.isEmpty ? "Speaker labelling failed (\(code))." : message
            case .badResponse:
                return "Speaker labelling returned an unreadable response."
            }
        }
    }

    private struct Payload: Decodable {
        struct Utterance: Decodable {
            let speaker: String
            let text: String
            let startMs: Int
        }
        let utterances: [Utterance]?
    }

    /// Label the finished recording. `wav` is the whole session, so this is one
    /// pass billed for the recording's length — not a live stream billed per
    /// open track for the duration of the call.
    static func diarize(wav: Data,
                        language: String?,
                        session: URLSession = BackendPinning.shared) async throws -> [DiarizedUtterance] {
        let base = Config.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw Failure.notConfigured }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(root)/api/diarize") else { throw Failure.notConfigured }

        // Refresh-aware: a stale token is read as anonymous by the server, which
        // would 401 a pass the user has already been charged nothing for.
        guard let token = await WheesprAuth.validAccessToken(), !token.isEmpty else {
            throw Failure.notSignedIn
        }

        let boundary = "cruxwing.\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // A long meeting is a large upload and a slow model pass; the default
        // 60s timeout would abort a legitimate request mid-flight.
        request.timeoutInterval = 600
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(wav: wav, language: language, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw Failure.http(http.statusCode, message)
        }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure.badResponse
        }
        return (decoded.utterances ?? []).map {
            DiarizedUtterance(speaker: $0.speaker, text: $0.text, startMs: $0.startMs)
        }
    }

    static func multipartBody(wav: Data, language: String?, boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"call.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n")

        // "multi" means "let the model decide" — sending it as a language would
        // pin recognition to a language that does not exist.
        if let language, !language.isEmpty, language != "multi" {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }
}
