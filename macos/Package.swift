// swift-tools-version: 5.9
import PackageDescription

// Exercise persistence/concurrency/archive code without booting SwiftUI or calling paid APIs.
let package = Package(
    name: "PapericoCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PapericoCore", targets: ["PapericoCore"])],
    targets: [
        .target(
            name: "PapericoCore", path: "Paperico",
            exclude: ["App", "Assets.xcassets", "Chat", "Components", "Pages", "Stores", "Resources", "paperico.icon",
                      "Core/KeychainStore.swift", "Core/PaperPipeline.swift",
                      "Support/AppBootstrap.swift", "Support/Info-extra.plist", "Support/LocalPrefs.swift", "Support/MarkdownExporter.swift",
                      "Support/Paperico.entitlements", "Support/PaperMarkdown.swift", "Support/ReaderPerf.swift"],
            sources: ["Models/Models.swift", "Models/PaperStatus.swift", "Support/AppPaths.swift",
                      "Core/PaperLibrary.swift", "Core/LibraryIndex.swift", "Core/LibraryFiles.swift", "Core/MarkdownTable.swift",
                      "Core/ChatService.swift", "Core/ChatRevision.swift", "Core/ReaderAnnotations.swift", "Core/DocumentProgress.swift", "Core/PaperOutline.swift", "Core/PaperContentScope.swift",
                      "Core/JobGate.swift", "Core/ChatContextBuilder.swift", "Core/AnalysisEngine.swift", "Core/LLMClient.swift", "Core/MinerUClient.swift", "Core/ServiceErrors.swift", "Core/ServiceURL.swift", "Core/ZipArchive.swift"]
        ),
        .testTarget(name: "PapericoCoreTests", dependencies: ["PapericoCore"], path: "Tests/PapericoCoreTests")
    ]
)
