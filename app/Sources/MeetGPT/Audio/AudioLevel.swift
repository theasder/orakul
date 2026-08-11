import AVFoundation
import CoreGraphics
import Foundation

/// Cheap RMS metering off the raw mic buffer, normalized to roughly 0...1 for
/// speech. Runs on the audio thread, so it stays allocation-free and fast.
enum AudioLevel {
    static func rms(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        if let float = buffer.floatChannelData {
            let samples = float[0]
            var sum: Float = 0
            for i in 0..<frames {
                let s = samples[i]
                sum += s * s
            }
            return normalize(sqrt(sum / Float(frames)))
        }

        if let int16 = buffer.int16ChannelData {
            let samples = int16[0]
            var sum: Float = 0
            for i in 0..<frames {
                let s = Float(samples[i]) / 32_768
                sum += s * s
            }
            return normalize(sqrt(sum / Float(frames)))
        }

        return 0
    }

    /// Speech RMS lives around 0.01–0.25; scale into a lively 0...1 range.
    private static func normalize(_ rms: Float) -> CGFloat {
        CGFloat(min(1, max(0, rms * 6.5)))
    }
}
