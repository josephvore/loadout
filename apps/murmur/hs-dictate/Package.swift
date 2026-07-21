// swift-tools-version: 6.0
// hs-dictate is a SwiftPM package so it can pull in FluidAudio (Parakeet
// CoreML ASR). The target stays in Swift 5 language mode — the daemon code
// predates strict concurrency and manages its tap-thread sharing manually.
import PackageDescription

let package = Package(
    name: "hs-dictate",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 from: "0.15.5"),
    ],
    targets: [
        .executableTarget(
            name: "hs-dictate",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: ".",
            exclude: ["build.sh"],
            sources: ["main.swift", "Parakeet.swift", "Streaming.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
