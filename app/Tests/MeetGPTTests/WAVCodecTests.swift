import Foundation
import Testing
@testable import MeetGPT

@Suite("WAV encode / decode")
struct WAVCodecTests {
    @Test("encode → floatSamples round-trips within PCM-16 precision")
    func roundTrip() {
        let samples = AudioFixtures.voicedInt16(count: 8_000)
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
        let floats = LocalWhisperTranscription.floatSamples(fromWAV: wav)
        #expect(floats.count == samples.count)
        for i in stride(from: 0, to: samples.count, by: 257) {
            #expect(abs(floats[i] - Float(samples[i]) / 32_768.0) < 0.0001)
        }
    }

    @Test("header carries RIFF/WAVE/fmt/data markers and PCM-16 mono params")
    func header() {
        let wav = WAVEncoder.encode(samples: [1, -1, 100, -100], sampleRate: 16_000)
        func ascii(_ off: Int, _ len: Int) -> String {
            String(decoding: wav[wav.startIndex + off ..< wav.startIndex + off + len], as: UTF8.self)
        }
        func u16(_ off: Int) -> UInt16 { wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt16.self) } }
        func u32(_ off: Int) -> UInt32 { wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) } }
        #expect(ascii(0, 4) == "RIFF")
        #expect(ascii(8, 4) == "WAVE")
        #expect(ascii(12, 4) == "fmt ")
        #expect(ascii(36, 4) == "data")
        #expect(u16(20) == 1)        // PCM
        #expect(u16(22) == 1)        // mono
        #expect(u32(24) == 16_000)   // sample rate
        #expect(u16(34) == 16)       // bits per sample
        #expect(u32(40) == 8)        // data size = 4 samples * 2 bytes
    }

    @Test("floatSamples walks past an extra RIFF chunk to find data")
    func extraChunk() {
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(Data([0, 0, 0, 0]))                 // riff size (unused by the walker)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("LIST".data(using: .ascii)!)        // a chunk before "data"
        var listSize = UInt32(4).littleEndian; wav.append(Data(bytes: &listSize, count: 4))
        wav.append(Data([9, 9, 9, 9]))
        wav.append("data".data(using: .ascii)!)
        var dataSize = UInt32(4).littleEndian; wav.append(Data(bytes: &dataSize, count: 4))
        var a = Int16(1000).littleEndian, b = Int16(-1000).littleEndian
        wav.append(Data(bytes: &a, count: 2)); wav.append(Data(bytes: &b, count: 2))

        let floats = LocalWhisperTranscription.floatSamples(fromWAV: wav)
        #expect(floats.count == 2)
        #expect(abs(floats[0] - 1000.0 / 32_768.0) < 0.0001)
        #expect(abs(floats[1] - (-1000.0 / 32_768.0)) < 0.0001)
    }

    @Test("floatSamples falls back to a 44-byte offset when there's no data chunk id")
    func fallback() {
        var blob = Data(repeating: 0, count: 44)
        var a = Int16(2000).littleEndian; blob.append(Data(bytes: &a, count: 2))
        let floats = LocalWhisperTranscription.floatSamples(fromWAV: blob)
        #expect(floats.count == 1)
        #expect(abs(floats[0] - 2000.0 / 32_768.0) < 0.0001)
    }

    @Test("floatSamples returns empty for a sub-header blob")
    func tooShort() {
        #expect(LocalWhisperTranscription.floatSamples(fromWAV: Data([1, 2, 3])).isEmpty)
    }
}
