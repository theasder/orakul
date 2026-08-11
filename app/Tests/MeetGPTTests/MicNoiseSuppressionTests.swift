import Foundation
import Testing
@testable import MeetGPT

/// Mic voice-processing toggle. The AVAudioEngine wiring itself needs real
/// hardware (a device smoke test); the unit-testable surface is the flag that
/// gates it — default off so recording never ducks playback, and it round-trips.
@Suite("Mic noise suppression flag", .serialized)
struct MicNoiseSuppressionTests {
    @Test("defaults off and round-trips through UserDefaults")
    func flag() {
        let key = "mic.noiseSuppression"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(Config.micNoiseSuppressionEnabled == false)

        Config.micNoiseSuppressionEnabled = false
        #expect(Config.micNoiseSuppressionEnabled == false)
        Config.micNoiseSuppressionEnabled = true
        #expect(Config.micNoiseSuppressionEnabled == true)
    }
}
