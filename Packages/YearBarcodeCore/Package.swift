// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YearBarcodeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "YearBarcodeCore", targets: ["YearBarcodeCore"]),
    ],
    targets: [
        // System zlib: available in the iOS/macOS SDKs and on Linux (zlib1g-dev).
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "YearBarcodeCore", dependencies: ["CZlib"]),
        .testTarget(name: "YearBarcodeCoreTests", dependencies: ["YearBarcodeCore", "CZlib"]),
    ]
)
