// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Typer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Typer", targets: ["Typer"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Typer",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Typer"
        ),
        .testTarget(
            name: "TyperTests",
            dependencies: ["Typer"],
            path: "tests/TyperTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
