// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskEngine", targets: ["DiskEngine"]),
        .executable(name: "diskscan", targets: ["diskscan"]),
        .library(name: "DiskApp", targets: ["DiskApp"]),
        .executable(name: "Hollow", targets: ["Hollow"]),
    ],
    targets: [
        .target(name: "DiskEngine"),
        .executableTarget(name: "diskscan", dependencies: ["DiskEngine"]),
        .testTarget(name: "DiskEngineTests", dependencies: ["DiskEngine"]),
        .target(name: "DiskApp", dependencies: ["DiskEngine"], resources: [.copy("Resources/lenses.json")]),
        .executableTarget(name: "Hollow", dependencies: ["DiskApp"],
                          linkerSettings: [.linkedFramework("DiskArbitration")]),
        .testTarget(name: "DiskAppTests", dependencies: ["DiskApp"]),
    ]
)
