import SwiftUI

/// Mirrors ReadingArea.tsx BlockRenderer — section headings, figures, tables,
/// equations and bilingual paragraphs with native block-level context attach.
struct BlockRenderer: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore
    @Environment(\.apiClient) private var client

    let block: Block
    let readingFontSize: CGFloat

    private var showOriginal: Bool { readerStore.bilingualMode != .translation }
    private var showTranslation: Bool { readerStore.bilingualMode != .original }

    var body: some View {
        Group {
            switch block.kind {
            case "section_heading": sectionHeading
            case "figure": figure
            case "table": table
            case "equation": equation
            default: paragraph
            }
        }
    }

    // MARK: section heading

    private var sectionHeading: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("§")
                .font(.system(size: 14))
                .foregroundStyle(palette.accent)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 5) {
                if showOriginal {
                    Text(block.textOriginal.isEmpty ? block.sectionTitle : block.textOriginal)
                        .font(.reading(readingFontSize + 6, weight: .semibold))
                        .lineSpacing(4)
                        .foregroundStyle(palette.gray900)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showTranslation, !block.textZh.isEmpty {
                    Text(block.textZh)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.gray500)
                }
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: figure

    private var figure: some View {
        figureContainer {
            figureImage
        }
    }

    @ViewBuilder
    private var figureImage: some View {
        if !block.imagePath.isEmpty, let url = client.filesURL(block.imagePath) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .failure:
                    Image.ic(Ic.image)
                        .font(.system(size: 30))
                        .foregroundStyle(palette.gray400)
                        .frame(maxWidth: .infinity, minHeight: 120)
                default:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .frame(maxHeight: 520)
            .onTapGesture {
                readerStore.addAttachedContext(AttachedContext(
                    type: "figure", refBlockId: block.id, refEntityId: nil, snippet: nil
                ))
            }
            .help("将图表加入论文对话")
        }
    }

    @ViewBuilder
    private func figureContainer<Content: View>(@ViewBuilder imageView: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            imageView()
            if captionOriginalExists || translatedCaptionExists {
                VStack(alignment: .leading, spacing: 0) {
                    if showOriginal, !block.captionOriginal.isEmpty {
                        MarkdownText(text: block.captionOriginal, fontSize: 14, color: palette.gray600)
                    }
                    if showTranslation, let translated = translatedCaption, !translated.isEmpty {
                        MarkdownText(text: translated, fontSize: 14, color: palette.gray800)
                            .padding(.top, 9)
                            .overlay(alignment: .top) { Rectangle().fill(palette.gray200).frame(height: 1) }
                            .padding(.top, 9)
                    }
                }
                .padding(.top, 13)
            }
            if !block.coreTakeaways.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("图表要点")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.accent)
                    ForEach(block.coreTakeaways, id: \.self) { takeaway in
                        Text(takeaway)
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .foregroundStyle(palette.gray600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.accentFaint)
                .overlay(alignment: .leading) { Rectangle().fill(palette.accent).frame(width: 2) }
                .padding(.top, 11)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(palette.gray50.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.gray200))
        .padding(.bottom, 30)
    }

    private var captionOriginalExists: Bool { !block.captionOriginal.isEmpty }
    private var translatedCaption: String? {
        let caption = block.captionZh.isEmpty ? block.textZh : block.captionZh
        return caption.isEmpty ? nil : caption
    }
    private var translatedCaptionExists: Bool { translatedCaption != nil }

    // MARK: table

    private var table: some View {
        figureContainer(imageView: {
            if !block.tableHtml.isEmpty {
                PaperTableView(html: block.tableHtml, fontSize: readingFontSize)
                    .padding(.vertical, 4)
            } else if !block.imagePath.isEmpty, let url = client.filesURL(block.imagePath) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
                .frame(maxHeight: 520)
            }
        })
    }

    // MARK: equation

    private var equation: some View {
        VStack(spacing: 8) {
            Text(block.latex)
                .font(.mono(readingFontSize * 0.92))
                .foregroundStyle(palette.gray800)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .horizontalScrollIfAvailable()
            if !block.plainExplanation.isEmpty {
                Text(block.plainExplanation)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(palette.gray500)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: paragraph

    private var paragraph: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showOriginal, !block.textOriginal.isEmpty {
                MarkdownText(text: block.textOriginal, fontSize: readingFontSize, color: palette.gray800)
            }
            if showTranslation, !block.textZh.isEmpty {
                MarkdownText(text: block.textZh, fontSize: readingFontSize - 1, color: palette.gray500)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(palette.accentSoft)
                            .frame(width: 2)
                    }
            }
        }
        .padding(.bottom, 17)
        .contextMenu {
            Button {
                readerStore.addAttachedContext(AttachedContext(
                    type: "text_selection",
                    refBlockId: block.id,
                    refEntityId: nil,
                    snippet: String(block.textOriginal.prefix(240))
                ))
            } label: {
                Label("加入论文对话", systemImage: Ic.messageCircle)
            }
        }
    }
}
