// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sleepi",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS(.v15)],
    products: [
        .library(name: "SleepiCore", targets: ["SleepiCore"]),
        .library(name: "SleepiUI", targets: ["SleepiUI"]),
        .library(name: "SleepiAudio", targets: ["SleepiAudio"]),
        .executable(name: "SleepiPreview", targets: ["SleepiPreview"])
    ],
    targets: [
        .target(name: "SleepiCore"),
        .target(name: "SleepiUI", dependencies: ["SleepiCore"], path: "Apps/Shared"),
        .target(name: "SleepiAudio", dependencies: ["SleepiCore"], path: "Apps/Audio"),
        .executableTarget(name: "SleepiPreview", dependencies: ["SleepiUI"], path: "Apps/Preview"),
        .testTarget(name: "SleepiCoreTests", dependencies: ["SleepiCore"]),
        .testTarget(name: "SleepiUITests", dependencies: ["SleepiUI", "SleepiCore"])
    ],
    swiftLanguageModes: [.v6]
)
