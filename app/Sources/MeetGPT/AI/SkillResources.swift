import Foundation

/// Resolves the SwiftPM resource bundle (vendored skills + role matrix) in ALL
/// launch modes — replacing the generated `Bundle.module` accessor, which for
/// an *executable* target only checks two places: the app-bundle ROOT (a
/// location codesign forbids — "unsealed contents") and an absolute path into
/// the build machine's `.build` directory. That combination works in dev by
/// accident and `fatalError`s at launch on every other machine.
///
/// Search order:
///   1. `Contents/Resources/` — the packaged .app (where build.sh installs it,
///      and the only codesign-legal home for a resource bundle),
///   2. next to the bare binary — `swift build` / `swift run` layouts,
///   3. next to the bundle hosting this module's code — under `swift test`
///      that's the `.xctest` bundle, whose parent (the build products dir)
///      holds the resource bundle; probed live, no env vars exist there.
///
/// Missing everywhere → nil, and callers degrade to "no bundled resources"
/// instead of crashing.
enum SkillResources {
    /// Anchor for Bundle(for:) — resolves to whatever bundle carries the
    /// MeetGPT module's code (the .app when packaged, the .xctest under tests).
    private final class BundleFinder {}

    static let bundle: Bundle? = {
        let name = "MeetGPT_MeetGPT.bundle"
        let hostBundle = Bundle(for: BundleFinder.self)
        var candidates: [URL] = []
        if let url = Bundle.main.resourceURL { candidates.append(url) }          // .app/Contents/Resources
        candidates.append(Bundle.main.bundleURL)                                  // bare-binary directory
        candidates.append(hostBundle.bundleURL.deletingLastPathComponent())       // .xctest sibling (tests)
        if let url = hostBundle.resourceURL { candidates.append(url) }
        for candidate in candidates {
            let url = candidate.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()

    /// URL of the bundled `Skills` directory, if resources are present.
    static var skillsDirectory: URL? {
        bundle?.url(forResource: "Skills", withExtension: nil)
    }
}
