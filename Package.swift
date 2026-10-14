// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FreeComplete",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FreeComplete", targets: ["FreeComplete"])],
    targets: [
        .executableTarget(
            name: "FreeComplete",
            path: "Sources/FreeComplete",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
