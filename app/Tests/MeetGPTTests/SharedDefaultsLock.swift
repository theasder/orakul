import Foundation

/// Serializes tests that write the SAME `UserDefaults` key from different
/// suites.
///
/// `.serialized` orders tests within one suite; it says nothing about two
/// suites running at once. `Config` is backed by the process-wide standard
/// defaults, so a suite that sets `localWhisperModel` and reads it back races
/// any other suite doing the same — which is exactly how
/// `LocalWhisperModelTests` came to read the `"small"` that
/// `SettingsDuringCallTests` had just written. It failed roughly one full run
/// in ten and passed in isolation every time.
///
/// One lock rather than one per key: the set of shared keys is small, the
/// critical sections are microseconds, and a per-key registry is a lot of
/// machinery to make a test suite marginally more parallel.
enum SharedDefaults {
    nonisolated(unsafe) private static let lock = NSLock()

    /// Run `body` with exclusive access to the shared defaults.
    ///
    /// Take this around the WHOLE set-then-assert, not just the write — the
    /// race is between one suite's write and another suite's read.
    static func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
