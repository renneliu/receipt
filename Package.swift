// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReceiptPrinter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ReceiptPrinter",
            path: "ReceiptPrinter",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ReceiptPrinterCoreTests",
            dependencies: ["ReceiptPrinter"],
            path: "Tests/ReceiptPrinterCoreTests"
        )
    ]
)
