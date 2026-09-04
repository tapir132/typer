// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Typer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Typer", targets: ["Typer"])
    ],
    targets: [
        .executableTarget(
            name: "Typer",
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
