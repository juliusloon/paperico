import SwiftUI

/// Mirrors projects/HomePage.tsx — hero, orbit art, metrics, recent list, workflow.
/// 窄窗口适配沿用 web 端断点(≤860 单列 hero、≤640 小屏排版)。
struct HomePage: View {
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(PapersStore.self) private var papersStore
    @Environment(ProjectsStore.self) private var projectsStore
    @Environment(Router.self) private var router

    private var isCompact: Bool { containerWidth < LayoutBreakpoint.workspace }

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 0) {
                    CompactTopBar()
                    scrollContent
                }
                .background(palette.gray0)
            } else {
                scrollContent
                    .overlay(alignment: .bottomLeading) {
                        WorkspaceNav(opensUpward: true)
                            .padding(.leading, 14)
                            .padding(.bottom, 14)
                            .zIndex(2)
                    }
                    .background(palette.gray0)
            }
        }
        .task {
            await papersStore.fetch()
            await projectsStore.fetch()
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 10) {
                hero
                metrics
                lowerGrid
            }
            .padding(.horizontal, containerWidth < LayoutBreakpoint.home ? 16 : 22)
            .padding(.bottom, isCompact ? 58 : 86)
            .padding(.top, 12)
            .trafficLightTopPadding(10)
            .frame(maxWidth: .infinity)
        }
    }

    private var readyCount: Int {
        papersStore.papers.filter { $0.statusEnum == .ready }.count
    }

    // MARK: hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 48) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image.ic(Ic.sparkles).font(.system(size: 11, weight: .semibold))
                    Text("PAPER READING WORKBENCH")
                }
                .font(.mono(10, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(palette.accent)
                .padding(.bottom, 18)

                Text("将读 PDF 变成\n真正理解论文。")
                    .font(.reading(heroTitleSize, weight: .medium))
                    .kerning(-0.8)
                    .lineSpacing(6)
                    .foregroundStyle(palette.gray900)

                Text("上传 PDF,自动拆解文本图表,生成双语阅读与逻辑链,并在原文证据范围内持续追问。")
                    .font(.system(size: containerWidth < LayoutBreakpoint.home ? 14 : 16.5))
                    .lineSpacing(7)
                    .foregroundStyle(palette.gray600)
                    .padding(.top, 22)

                HStack(spacing: 12) {
                    PrimaryActionButton(title: "打开论文库", systemImage: Ic.arrowRight) {
                        router.go(.library)
                    }
                    SecondaryActionButton(title: "检查 API 配置") {
                        router.go(.settings)
                    }
                }
                .padding(.top, 26)
            }

            if containerWidth >= LayoutBreakpoint.hero {
                OrbitArt()
                    .frame(height: 280)
            }
        }
        .frame(minHeight: containerWidth >= LayoutBreakpoint.hero ? 300 : 0, alignment: .center)
        .frame(maxWidth: 1240)
    }

    private var heroTitleSize: CGFloat {
        if containerWidth < LayoutBreakpoint.home { return 30 }
        if containerWidth < LayoutBreakpoint.hero { return 38 }
        return 66
    }

    // MARK: metrics

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(icon: Ic.library, value: papersStore.papers.count, label: "篇论文")
            divider
            metric(icon: Ic.bookOpen, value: readyCount, label: "已完成解析")
            divider
            metric(icon: Ic.brain, value: projectsStore.projects.count, label: "个研究项目")
        }
        .frame(maxWidth: 1240)
        .liquidPanel(cornerRadius: 12)
        .padding(.top, 10)
    }

    private var divider: some View {
        Rectangle().fill(palette.gray200).frame(width: 1, height: 40)
    }

    private func metric(icon: String, value: Int, label: String) -> some View {
        HStack(spacing: 10) {
            if containerWidth >= LayoutBreakpoint.home {
                Image.ic(icon)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.accent)
            }
            Text("\(value)")
                .font(.reading(25, weight: .medium))
                .foregroundStyle(palette.gray900)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(palette.gray500)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
    }

    // MARK: lower grid

    private var lowerGrid: some View {
        Group {
            if containerWidth >= LayoutBreakpoint.hero {
                HStack(alignment: .top, spacing: 22) {
                    recentPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                    workflowPanel
                        .frame(width: 300)
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    recentPanel
                    workflowPanel
                }
            }
        }
        .frame(maxWidth: 1240)
        .frame(maxWidth: .infinity)
    }

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RECENT")
                        .font(.mono(10, weight: .bold))
                        .kerning(1.6)
                        .foregroundStyle(palette.accent)
                    Text("继续阅读")
                        .font(.reading(21, weight: .medium))
                        .foregroundStyle(palette.gray900)
                }
                Spacer(minLength: 0)
                Button {
                    router.go(.library)
                } label: {
                    HStack(spacing: 5) {
                        Text("查看全部")
                        Image.ic(Ic.arrowRight).font(.system(size: 10))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(palette.gray500)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 14)

            let recent = Array(papersStore.papers.prefix(4))
            if recent.isEmpty {
                HStack(spacing: 8) {
                    Image.ic(Ic.fileSearch).font(.system(size: 24))
                    Text("还没有论文。前往论文库上传第一份 PDF。")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.gray400)
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, paper in
                        recentRow(index: index, paper: paper)
                    }
                }
            }
        }
        .padding(24)
        .liquidPanel(cornerRadius: 14)
    }

    private func recentRow(index: Int, paper: PaperListItem) -> some View {
        Button {
            router.go(.reader(paperId: paper.id))
        } label: {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index + 1))
                    .font(.mono(10, weight: .semibold))
                    .foregroundStyle(palette.gray400)
                VStack(alignment: .leading, spacing: 4) {
                    Text(paper.displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.gray800)
                        .lineLimit(1)
                    Text(paper.statusEnum == .ready ? (paper.tldr.isEmpty ? "已完成解析" : paper.tldr) : "正在准备阅读内容")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.gray500)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusDot(status: paper.statusEnum)
                Image.ic(Ic.arrowRight)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.gray500)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.gray200).frame(height: index == 0 ? 1 : 0.5).opacity(index == 0 ? 1 : 0.6)
        }
    }

    private var workflowPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKFLOW")
                .font(.mono(10, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(palette.accent)
            Text("一条连贯的阅读路径")
                .font(.reading(21, weight: .medium))
                .foregroundStyle(palette.gray900)
                .padding(.top, 5)

            VStack(spacing: 16) {
                workflowStep(number: "01", title: "文件拆解", detail: "解析文本与图表,重构成连贯的流式阅读版式。")
                workflowStep(number: "02", title: "提炼逻辑", detail: "分析论文叙述逻辑,生成与阅读进度同步的逻辑链。")
                workflowStep(number: "03", title: "证据问答", detail: "与论文解析得到的丰富背景进行直接对话。")
            }
            .padding(.top, 20)
        }
        .padding(24)
        .liquidPanel(cornerRadius: 14)
    }

    private func workflowStep(number: String, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            Text(number)
                .font(.mono(9, weight: .bold))
                .foregroundStyle(palette.accent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.gray800)
                Text(detail).font(.system(size: 12)).foregroundStyle(palette.gray500)
            }
        }
    }
}

// MARK: - Decorative orbit artwork (CSS art redrawn with shapes)

struct OrbitArt: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Circle()
                .stroke(palette.accent.opacity(0.28))
                .frame(width: 260, height: 260)
            Circle()
                .stroke(palette.accent.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: 190, height: 190)
                .rotationEffect(.degrees(16))

            VStack(alignment: .leading, spacing: 0) {
                Text("P / 01")
                    .font(.mono(9, weight: .bold))
                    .kerning(1.1)
                    .foregroundStyle(palette.accent)
                orbitLines
                    .padding(.leading, 29)
                    .padding(.top, 26)
            }
            .frame(width: 158, height: 210, alignment: .topLeading)
            .padding(20)
            .background(
                Rectangle()
                    .fill(palette.gray0)
                    .shadow(color: palette.accent.opacity(0.10), radius: 0, x: 10, y: 12)
                    .shadow(color: palette.shadowCard, radius: 10, y: 6)
            )
            .overlay(Rectangle().stroke(palette.gray200))
            .rotationEffect(.degrees(3))

            orbitRail

            VStack {
                Text("结构化\n精读")
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .foregroundStyle(.white)
            }
            .frame(width: 66, height: 66)
            .background(Circle().fill(palette.accent))
            .rotationEffect(.degrees(-8))
            .offset(x: 105, y: 92)
        }
        .frame(height: 280)
        .accessibilityHidden(true)
    }

    private var orbitLines: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle().fill(palette.gray200).frame(height: 2)
            Rectangle().fill(palette.gray200).frame(height: 2).frame(width: 74, alignment: .leading)
            Rectangle().fill(palette.gray200).frame(height: 2)
            Rectangle().fill(palette.gray200).frame(height: 2)
            Rectangle().fill(palette.gray200).frame(height: 2).frame(width: 74, alignment: .leading)
        }
    }

    private var orbitRail: some View {
        VStack {
            railDot
            Spacer(minLength: 8)
            railDot
            Spacer(minLength: 8)
            railDot
        }
        .frame(width: 158, height: 130)
        .overlay(alignment: .leading) {
            Rectangle()
                .stroke(palette.gray300, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 1)
                .opacity(0.9)
        }
        .offset(x: -49, y: -8)
        .accessibilityHidden(true)
    }

    private var railDot: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: 8, height: 8)
            .background(Circle().fill(palette.accentSoft).frame(width: 16, height: 16))
    }
}
