// swift-tools-version:5.9
import PackageDescription

// orakul — сборка, отдельная от Cruxwing.
//
// Ядро (OrakulCore) не знает ни про SwiftUI, ни про CoreML, ни про
// ScreenCaptureKit: там разбор каталога кнопок, правила уровней и всё, что
// должно одинаково работать и на macOS, и на Windows. Платформенные слои —
// захват звука и оболочка — лежат снаружи и заменяются целиком.
//
// Такое разделение не вкусовщина: порт на Windows стоит ровно тех модулей,
// которые находятся вне OrakulCore, и это видно прямо из манифеста.
let package = Package(
    name: "Orakul",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrakulCore", targets: ["OrakulCore"])
    ],
    targets: [
        .target(
            name: "OrakulCore",
            resources: [
                // Каталог кнопок — данные, а не код: его правит тот, кто пишет
                // тексты, и его же проверяют тесты на стороне сайта.
                .copy("Resources/prompts.ru.json")
            ]
        ),
        .testTarget(name: "OrakulCoreTests", dependencies: ["OrakulCore"])
    ]
)
