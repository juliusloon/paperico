// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PapericoMCP",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PapericoMCP", targets: ["PapericoMCP"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "PapericoMCP", dependencies: [.product(name: "MCP", package: "swift-sdk")])
    ]
)
