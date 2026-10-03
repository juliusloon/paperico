import SwiftUI

// MARK: - 本地服务环境

@MainActor
@Observable
final class AppServices {
    let library: PaperLibrary
    let pipeline: PaperPipeline

    init(library: PaperLibrary, pipeline: PaperPipeline) {
        self.library = library
        self.pipeline = pipeline
    }
}
