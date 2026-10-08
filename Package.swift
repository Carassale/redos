// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RedOS",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "RedOS", targets: ["RedOS"])
    ],
    targets: [
        .target(name: "RedOSCore"),
        .target(name: "RedOSActions", dependencies: ["RedOSCore"]),
        .executableTarget(name: "RedOS", dependencies: ["RedOSCore", "RedOSActions"]),
        .testTarget(name: "RedOSCoreTests", dependencies: ["RedOSCore"]),
    ]
)
