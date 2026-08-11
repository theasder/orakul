import AVFoundation
import Foundation

enum MediaTranscoderError: LocalizedError {
    case noAudioTrack
    case emptyAudio
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:       return "That file has no audio track to transcribe."
        case .emptyAudio:         return "The audio track could not be decoded."
        case .readFailed(let m):  return "Couldn't read media: \(m)"
        }
    }
}

/// Decodes an audio/video file's audio track to mono 16 kHz PCM-16 and wraps it
/// as WAV — ready for the existing transcription pipeline.
enum MediaTranscoder {
    static func extractWAV(url: URL) async throws -> Data {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        guard let track = try await audioTrack(asset) else { throw MediaTranscoderError.noAudioTrack }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw MediaTranscoderError.readFailed(error.localizedDescription) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaTranscoderError.readFailed("unsupported audio") }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaTranscoderError.readFailed(reader.error?.localizedDescription ?? "reader failed")
        }

        // Cap at ~12 min (≈23 MB WAV) so the result stays under Whisper's 25 MB
        // upload limit and memory stays bounded for long files.
        let maxSamples = 16_000 * 60 * 12
        var samples: [Int16] = []
        while reader.status == .reading, samples.count < maxSamples,
              let buffer = output.copyNextSampleBuffer() {
            try append(from: buffer, into: &samples)
        }
        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            throw MediaTranscoderError.readFailed(reader.error?.localizedDescription ?? "decode failed")
        }
        guard !samples.isEmpty else { throw MediaTranscoderError.emptyAudio }
        return WAVEncoder.encode(samples: samples, sampleRate: 16_000)
    }

    private static func audioTrack(_ asset: AVURLAsset) async throws -> AVAssetTrack? {
        try await asset.loadTracks(withMediaType: .audio).first
    }

    private static func append(from buffer: CMSampleBuffer, into samples: inout [Int16]) throws {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }

        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else {
            throw MediaTranscoderError.readFailed("audio copy failed (status \(copied))")
        }
        data.withUnsafeBytes { raw in
            samples.append(contentsOf: raw.bindMemory(to: Int16.self))
        }
    }
}
