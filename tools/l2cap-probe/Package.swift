// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "l2cap-probe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "l2cap-probe", targets: ["l2cap-probe"]),
    ],
    targets: [
        .target(
            name: "L2CAPShim",
            path: "Sources/L2CAPShim",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "l2cap-probe",
            dependencies: ["L2CAPShim"],
            path: "Sources/l2cap-probe",
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
    ]
)
