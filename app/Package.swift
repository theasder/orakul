// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetGPT",
    // v14 is FluidAudio's floor (Parakeet live lane). Sonoma runs on almost
    // exactly the Ventura hardware set, so the cost is a few 2017 Macs.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MeetGPT", targets: ["MeetGPT"])
    ],
    dependencies: [
        // Model Context Protocol client — powers "Connected apps" (Notion,
        // Fireflies, Linear, Asana, …) with keyless OAuth (PKCE + dynamic
        // client registration). Pinned exact: pre-1.0 API churns between minors.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // On-device Whisper (Core ML / ANE) for the local transcription engine —
        // no audio leaves the Mac. Models auto-download on first use.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // Test-only: inspect SwiftUI view hierarchies to assert view-logic
        // (conditional rendering, labels, disabled state) without a UI host.
        .package(url: "https://github.com/nalexn/ViewInspector.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "MeetGPT",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/MeetGPT",
            // Vendored third-party Agent Skills (permissively licensed) copied
            // verbatim; loaded at runtime by BundledSkillLibrary. `.copy` keeps
            // the folder structure so each <id>/SKILL.md stays addressable.
            resources: [
                .copy("Resources/Skills")
            ]
        ),
        // Unit + pipeline tests for the transcription path — the audio → chunk →
        // VAD → transcribe → transcript chain that feeds the live transcript panel.
        .testTarget(
            name: "MeetGPTTests",
            dependencies: [
                "MeetGPT",
                .product(name: "ViewInspector", package: "ViewInspector")
            ],
            path: "Tests/MeetGPTTests"
        )
    ]
)
