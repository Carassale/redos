// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RedOS",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "RedOS", targets: ["RedOS"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(name: "RedOSCore"),
        .target(name: "RedOSActions", dependencies: ["RedOSCore"]),
        .target(name: "RedOSVoice"),
        .target(
            name: "RedOSWakeWord",
            dependencies: ["RedOSVoice", .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]
        ),
        .executableTarget(
            name: "RedOS",
            dependencies: [
                "RedOSCore", "RedOSActions", "RedOSVoice", "RedOSWakeWord",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(name: "RedOSEval", dependencies: ["RedOSCore", "RedOSActions"]),
        .testTarget(name: "RedOSCoreTests", dependencies: ["RedOSCore", "RedOSActions", "RedOSWakeWord"]),
    ]
)
