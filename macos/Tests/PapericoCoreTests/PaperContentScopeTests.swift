import XCTest
@testable import PapericoCore

final class PaperContentScopeTests: XCTestCase {
    private func item(_ text: String, heading: Bool = false, section: String = "") -> PaperContentScope.Item {
        .init(kind: heading ? "section_heading" : "paragraph", text: text, section: section)
    }

    func testAbstractBoundaryOmitsFrontMatterAndReferencesThroughEnd() {
        let regions = PaperContentScope.regions([
            item("Paper title", heading: true), item("Jane Doe and John Smith"),
            item("https://doi.org/10.1234/test"), item("Abstract", heading: true),
            item("Scientific summary"), item("1 Introduction", heading: true),
            item("Prior studies [1, 2] establish the scientific result."), item("Methods", heading: true),
            item("Protocol"), item("References", heading: true), item("1. Author. Journal."),
            item("Author contributions", heading: true), item("Author statement")
        ])
        XCTAssertEqual(regions, [.frontMatter, .frontMatter, .frontMatter, .body, .body, .body, .body, .body, .body,
                                 .backMatter, .backMatter, .backMatter, .backMatter])
    }

    func testUnlabelledAbstractAndInterleavedAffiliations() {
        let prose = String(repeating: "The results demonstrate molecular activity prediction. ", count: 5)
        let regions = PaperContentScope.regions([
            item("Article"), item("https://doi.org/10.1234/test"), item("Paper title", heading: true),
            item("Received: 5 October 2026"), item("Chao Cui<sup>1,2</sup>, Xiaorui Su<sup>3</sup>"),
            item(prose), item("Research introduction"),
            item("<sup>1</sup>College of Science, Example University. E-mail: a@example.com"),
            item("Results", heading: true), item("Model evidence"),
            item("Data availability", heading: true), item("Dataset repository")
        ])
        XCTAssertEqual(regions, [.frontMatter, .frontMatter, .frontMatter, .frontMatter, .frontMatter,
                                 .body, .body, .frontMatter, .body, .body, .backMatter, .backMatter])
    }

    func testMissingBoundaryKeepsScientificBodyAndNumberedCitations() {
        XCTAssertEqual(PaperContentScope.regions([
            item("First scientific paragraph"), item("References to [1] motivated our work."),
            item("2.1 Methods", heading: true), item("A doi identifier was used in the experiment.")
        ]), [.body, .body, .body, .body])
    }

    func testNatureMethodsResumeAfterReferencesAndEndAtPublicationSections() {
        XCTAssertEqual(PaperContentScope.regions([
            item("Abstract", heading: true), item("Summary"),
            item("References", heading: true), item("1. Smith, J. Journal (2026).", section: "References"),
            item("Methods", heading: true, section: "Methods"), item("Dataset curation and processing", heading: true),
            item("Scientific protocol"), item("Data availability", heading: true), item("Repository"),
            item("References", heading: true), item("Methods are discussed in this cited paper."),
            item("Reporting Summary", heading: true), item("Statistics", heading: true), item("Checklist")
        ]), [.body, .body, .backMatter, .backMatter, .body, .body, .body,
              .backMatter, .backMatter, .backMatter, .backMatter, .backMatter, .backMatter, .backMatter])
    }

    func testAppendixResumesAfterAcknowledgmentsAndReferences() {
        XCTAssertEqual(PaperContentScope.regions([
            item("1 Introduction", heading: true), item("Research"),
            item("7 Acknowledgments", heading: true), item("Funding statement"),
            item("References", heading: true), item("Citation"),
            item("Appendix", heading: true), item("A Related Work", heading: true), item("Related studies"),
            item("B Details of method", heading: true), item("Supplementary protocol"),
            item("References", heading: true), item("Second bibliography")
        ]), [.body, .body, .backMatter, .backMatter, .backMatter, .backMatter,
              .body, .body, .body, .body, .body, .backMatter, .backMatter])
    }

    func testSectionOnlyMethodsAndSpacedHeadingResumeBody() {
        XCTAssertEqual(PaperContentScope.regions([
            item("Scientific body"), item("References", heading: true), item("Citation"),
            item("Protocol", section: "Materials and Methods"), item("Another step", section: "Materials and Methods"),
            item("Data availability", heading: true), item("Repository"),
            item("**M E T H O D S**", heading: true), item("Rest of protocol")
        ]), [.body, .backMatter, .backMatter, .body, .body, .backMatter, .backMatter, .body, .body])
    }

    func testExtendedDataPanelsResumeDespiteStalePublicationSection() {
        XCTAssertEqual(PaperContentScope.regions([
            item("Research"), item("References", heading: true), item("Citation"),
            item("Additional information", heading: true, section: "Additional information"), item("Publication links", section: "Additional information"),
            .init(kind: "figure", text: "a", section: "Additional information"),
            .init(kind: "figure", text: "b Extended Data Fig. 1 | Scientific evidence.", section: "Additional information"),
            .init(kind: "table", text: "Extended Data Table 1 | Cohorts", section: "Additional information"),
            item("Reporting Summary", heading: true),
            .init(kind: "table", text: "Methods", section: "Reporting Summary")
        ]), [.body, .backMatter, .backMatter, .backMatter, .backMatter, .body, .body, .body, .backMatter, .backMatter])
    }

    func testReaderUsesFigureCaptionForTheSameScopeAsAnalysis() {
        func block(_ id: String, kind: String, text: String = "", caption: String = "") -> Block {
            Block(id: id, order: 0, kind: kind, pageIdx: 0, bbox: nil,
                  sectionTitle: "Additional information", textOriginal: text, textZh: "", oneLiner: "",
                  keywords: [], roleInNarrative: "", imagePath: "", captionOriginal: caption, captionZh: "",
                  figureType: "", coreTakeaways: [], dataReadingNotes: "", tableHtml: "", latex: "",
                  plainExplanation: "", entityRefs: [])
        }
        XCTAssertEqual(PaperContentScope.regions([
            block("links", kind: "section_heading", text: "Additional information"),
            block("panel", kind: "figure", caption: "a"),
            block("caption", kind: "figure", caption: "b Extended Data Fig. 1 | Experimental results")
        ]), [.backMatter, .body, .body])
    }

    func testInlineAbstractAndSectionOnlyBoundaries() {
        XCTAssertEqual(PaperContentScope.regions([
            item("Paper.pdf"), item("摘要：本文提出一种方法。"), item("正文内容"),
            item("文献条目", section: "参考文献")
        ]), [.frontMatter, .body, .body, .backMatter])
    }

    func testFormattedSpacedBoundariesAndAuthorLabelsAreExcluded() {
        let regions = PaperContentScope.regions([
            item("Authors: Jane Doe"), item("Affiliations: Example University"),
            item("**A B S T R A C T**", heading: true), item("Scientific summary"),
            item("**6. References and Notes**", heading: true), item("Citation")
        ])
        XCTAssertEqual(regions, [.frontMatter, .frontMatter, .body, .body, .backMatter, .backMatter])
    }

    func testMissingReferenceHeadingRequiresConsecutiveBibliography() {
        let regions = PaperContentScope.regions([
            item("Abstract", heading: true), item("Summary"), item("Methods", heading: true), item("Experiments"),
            item("Results", heading: true), item("Measured outcomes"),
            item("1. Smith, J. Molecular design. Journal 10, 1–9 (2024)."),
            item("2. Doe, A. Model training. Journal 20, 10–19 (2025)."),
            item("3. Brown, B. Prediction. Journal 30, 20–29 (2026).")
        ])
        XCTAssertEqual(regions, Array(repeating: .body, count: 6) + Array(repeating: .backMatter, count: 3))
        XCTAssertEqual(PaperContentScope.regions([
            item("Introduction", heading: true), item("References to earlier studies motivate the model."),
            item("1. Samples collected in 2024"), item("2. Data processed in 2025"), item("3. Results validated in 2026")
        ]), Array(repeating: .body, count: 5))
    }
}
