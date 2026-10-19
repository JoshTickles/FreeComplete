// swift-tools-version: 6.2
import PackageDescription

// llama.cpp is linked statically from libraries that scripts/build-app.sh builds and
// stages under .build/llama (pinned upstream source, Metal backend embedded).
let llama = Context.packageDirectory + "/.build/llama/lib"

let package = Package(
    name: "FreeComplete",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FreeComplete", targets: ["FreeComplete"])],
    targets: [
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        .executableTarget(
            name: "FreeComplete",
            dependencies: ["CLlama"],
            path: "Sources/FreeComplete",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", llama]),
                .linkedLibrary("llama"), .linkedLibrary("ggml"), .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"), .linkedLibrary("ggml-metal"), .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"), .linkedFramework("Foundation")
            ]
        )
    ]
)
