// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ds4gui",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DS4Audio", targets: ["DS4Audio"]),
    ],
    targets: [
        .executableTarget(
            name: "DS4Audio",
            path: "Sources/DS4Audio"
        ),
    ]
)
