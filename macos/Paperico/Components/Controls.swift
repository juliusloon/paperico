import SwiftUI

// MARK: - 统一控件规格
//
// 全 app 的下拉选择框 / 搜索框 / 工具栏按钮共用一套尺寸:
// 高 38，胶囊边框；图标操作为同高圆钮，输入与动作分开保持命中区域。

enum ControlSpec {
    static let height: CGFloat = 38
    static let radius: CGFloat = height / 2
}

/// Shared title size; list pages leave a little space before the title.
enum PageTitleSpec {
    static let font = Font.system(size: 24, weight: .medium)
    static let listInset: CGFloat = 10
    static let contentInset: CGFloat = 20
    // List titles sit beside 38pt controls, about 5pt taller than the text.
    static let toolbarTopInset: CGFloat = 15
}

/// 下拉选择框(可带前导图标)。width 为 nil 时横向撑满(可再以 maxWidth 封顶)。
struct PillPicker: View {
    @Environment(\.palette) private var palette
    var icon: String? = nil
    @Binding var selection: String
    let options: [(String, String)]
    var width: CGFloat? = nil
    var maxWidth: CGFloat? = nil
    var disabled = false

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image.ic(icon)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.gray400)
            }
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.gray700)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: maxWidth)
        .frame(width: width)
        .frame(height: ControlSpec.height)
        .liquidInset(cornerRadius: ControlSpec.radius)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

/// 搜索框(论文库 / 方法索引工具栏)。
struct PillSearchField: View {
    @Environment(\.palette) private var palette
    @Binding var text: String
    let prompt: String
    var maxWidth: CGFloat = 420
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(onSubmit)
                    .accessibilityLabel(prompt)
                if !text.isEmpty {
                    Button {
                        text = ""
                        onSubmit()
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(palette.gray400) }
                    .buttonStyle(.plain).help("清除搜索")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: ControlSpec.height)
            .liquidInset(cornerRadius: ControlSpec.radius)
            Button(action: onSubmit) {
                Image.ic(Ic.search)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .frame(width: ControlSpec.height, height: ControlSpec.height)
            }
            .buttonStyle(.plain)
            .liquidTool(cornerRadius: ControlSpec.height / 2)
            .contentShape(Circle())
            .help("搜索").accessibilityLabel("搜索")
        }
        .frame(maxWidth: maxWidth)
    }
}

/// Compact toolbar actions share the search button's height and hit area.
struct PillIconButton: View {
    @Environment(\.palette) private var palette
    let title: String
    let icon: String
    var active = false
    var size: CGFloat = ControlSpec.height
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image.ic(icon)
                .font(.system(size: min(15, size / 2), weight: .medium))
                .foregroundStyle(active ? palette.accent : palette.gray600)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain).noFocusRing()
        .liquidTool(tint: active ? palette.accentFaint : nil)
        .help(title).accessibilityLabel(title)
    }
}

struct PillIconMenu: View {
    @Environment(\.palette) private var palette
    let title: String
    let icon: String
    @Binding var selection: String
    let options: [(String, String)]
    var active = false

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image.ic(icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? palette.accent : palette.gray600)
                .frame(width: ControlSpec.height, height: ControlSpec.height)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: ControlSpec.height, height: ControlSpec.height)
        .noFocusRing()
        .liquidTool(tint: active ? palette.accentFaint : nil)
        .help(title).accessibilityLabel(title)
        .accessibilityValue(options.first(where: { $0.0 == selection })?.1 ?? selection)
    }
}

/// 工具栏 / 动作行按钮:primary = 强调色填充,secondary = 描边。
struct ToolbarButton: View {
    @Environment(\.palette) private var palette

    enum Kind {
        case primary, secondary, danger
    }

    let title: String
    var icon: String? = nil
    var kind: Kind = .secondary
    var busy = false
    var disabled = false
    var flexible = false
    var active = false
    let action: () -> Void

    var body: some View {
        styledButton
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(disabled || busy)
            .help(title)
    }

    @ViewBuilder private var styledButton: some View {
        button.buttonStyle(LiquidActionButtonStyle(prominent: kind == .primary,
            foreground: kind == .danger ? palette.danger : (active ? palette.accent : nil)))
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                else if let icon { Image.ic(icon) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .frame(maxWidth: flexible ? .infinity : nil, minHeight: 22)
        }
    }
}

/// One native action shared by the PDF and bilingual document selections.
struct SelectionConversationButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "text.bubble")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(LiquidActionButtonStyle(prominent: true, horizontalPadding: 10, verticalPadding: 10))
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("加入论文对话")
        .help("把选中的原文加入论文对话")
    }
}

/// Places the native selection action above or below the visible selection,
/// keeping the whole hit target inside the document viewport.
struct SelectionActionOverlay: View {
    let selectionRect: CGRect
    let viewport: CGSize
    let action: () -> Void
    private var center: CGPoint {
        let halfWidth: CGFloat = 22
        let halfHeight: CGFloat = 22
        let x = min(max(selectionRect.midX, halfWidth + 8), max(halfWidth + 8, viewport.width - halfWidth - 8))
        let proposedY = selectionRect.minY >= 112 ? selectionRect.minY - halfHeight - 8 : selectionRect.maxY + halfHeight + 8
        let y = min(max(proposedY, 76 + halfHeight), max(76 + halfHeight, viewport.height - halfHeight - 8))
        return CGPoint(x: x, y: y)
    }
    var body: some View {
        SelectionConversationButton(action: action)
            .position(center)
    }
}

/// 设置页带边框的文本输入框(与 PillPicker 同规格;placeholder 承载提示文字)。
struct FormTextField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: ControlSpec.height)
            .frame(maxWidth: .infinity)
            .liquidInset(cornerRadius: ControlSpec.radius)
    }
}

/// 设置页带边框的 Stepper(与 PillPicker 同规格)。
struct FormStepper: View {
    @Environment(\.palette) private var palette
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    init(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { value = max(range.lowerBound, value - step) } label: {
                Image(systemName: "minus").frame(width: 24, height: 28)
            }.disabled(value <= range.lowerBound).accessibilityLabel("减少")
            Text(title).font(.system(size: 12.5)).frame(maxWidth: .infinity)
            Button { value = min(range.upperBound, value + step) } label: {
                Image(systemName: "plus").frame(width: 24, height: 28)
            }.disabled(value >= range.upperBound).accessibilityLabel("增加")
        }
        .buttonStyle(.plain).foregroundStyle(palette.gray700)
        .padding(.horizontal, 8).frame(height: ControlSpec.height)
        .liquidInset(cornerRadius: ControlSpec.radius)
    }
}

/// 设置页密钥输入(明文/安全切换),placeholder 承载提示文字。
struct FormSecretField: View {
    @Environment(\.palette) private var palette
    @Binding var text: String
    let placeholder: String
    @Binding var visible: Bool

    var body: some View {
        HStack(spacing: 0) {
            SecureOrPlainField(text: $text, visible: visible, placeholder: placeholder)
                .padding(.leading, 10)
            Button {
                visible.toggle()
            } label: {
                Image.ic(visible ? Ic.eyeOff : Ic.eye)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.gray400)
                    .padding(.horizontal, 10)
                    .frame(height: ControlSpec.height)
            }
            .buttonStyle(.plain)
        }
        .frame(height: ControlSpec.height)
        .frame(maxWidth: .infinity)
        .liquidInset(cornerRadius: ControlSpec.radius)
    }
}

/// Discrete choices with a sliding glass selection; labels remain readable at narrow widths.
struct SlidingChoice: View {
    @Binding var selection: String
    let options: [(String, String)]
    var icons: [String: String] = [:]
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Group {
                        if let icon = icons[value] { Image(systemName: icon).font(.system(size: 15)) }
                        else { Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .foregroundStyle(selection == value ? palette.accent : palette.gray500)
                    .background {
                        if selection == value {
                            Capsule().fill(palette.accentSoft).matchedGeometryEffect(id: "choice", in: selectionMotion)
                        }
                    }
                    .contentShape(Capsule())
                }.buttonStyle(.plain).noFocusRing().help(label).accessibilityLabel(label)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }.padding(3).liquidInset(cornerRadius: ControlSpec.radius)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: selection)
    }
}

struct ReasoningSlider: View {
    @Binding var selection: String
    let options: [(String, String)]
    private var index: Binding<Double> {
        Binding(get: { Double(options.firstIndex(where: { $0.0 == selection }) ?? 0) }, set: { value in
            let i = min(options.count - 1, max(0, Int(value.rounded())))
            if options.indices.contains(i) { selection = options[i].0 }
        })
    }
    var body: some View {
        HStack(spacing: 9) {
            Slider(value: index, in: 0...Double(max(1, options.count - 1)), step: 1)
                .disabled(options.count < 2).accessibilityLabel("思考强度")
            Text(options.first(where: { $0.0 == selection })?.1 ?? "关闭")
                .font(.system(size: 12.5)).frame(minWidth: 26).lineLimit(1)
        }.padding(.horizontal, 10).frame(height: ControlSpec.height)
    }
}

/// Softens the edge where scrolling cards meet the fixed page title/actions.
struct ScrollTitleFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.7), location: 0.5),
                .init(color: .white, location: 1)
            ], startPoint: .top, endPoint: .bottom).frame(height: 28)
            Rectangle().fill(.white)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
