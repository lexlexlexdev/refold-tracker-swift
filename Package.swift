// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RefoldTracker",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RefoldTracker", targets: ["RefoldTracker"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .executableTarget(name: "RefoldTracker", dependencies: ["CSQLite"],
                          resources: [.copy("Bridge.js")])
    ]
)
