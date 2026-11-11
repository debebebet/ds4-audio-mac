// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ds4probe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ds4probe", targets: ["ds4probe"]),
    ],
    targets: [
        // C-таргет с эталонным кодеком SBC (libsbc 2.1, исходники bluez/nefarius).
        // Только переносимая реализация: NEON/SSE/MMX-примитивы на arm64 не собираются.
        .target(
            name: "CSBC",
            path: "Sources/CSBC",
            publicHeadersPath: "include",
            cSettings: [
                .define("DS4_DISABLE_X86_SIMD"),
            ]
        ),
        .executableTarget(
            name: "ds4probe",
            dependencies: ["CSBC"],
            path: "Sources/ds4probe"
        ),
    ]
)
