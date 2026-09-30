import SwiftUI

// MARK: - 统一控件规格
//
// 全 app 的下拉选择框 / 搜索框 / 工具栏按钮共用一套尺寸:
// 高 38、圆角 9、gray200 描边、12.5pt 字号;框内水平留白 10。

enum ControlSpec {
    static let height: CGFloat = 38
    static let radius: CGFloat = 9
}

/// 下拉选择框(可带前导图标)。width 为 nil 时横向撑满(可再以 maxWidth 封顶)。
struct PillPicker: View {
    @Environment(\.palette) private var palette
    var icon: String? = nil
    @Binding var selection: String
    let options: [(String, String)]
    var width: CGFloat? = nil
    var maxWidth: CGFloat? = nil

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
        .background(RoundedRectangle(cornerRadius: ControlSpec.radius).fill(palette.gray0))
        .overlay(RoundedRectangle(cornerRadius: ControlSpec.radius).stroke(palette.gray200))
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
        HStack(spacing: 6) {
            Image.ic(Ic.search)
                .font(.system(size: 13))
                .foregroundStyle(palette.gray400)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit(onSubmit)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: ControlSpec.height)
        .frame(maxWidth: maxWidth)
        .background(RoundedRectangle(cornerRadius: ControlSpec.radius).fill(palette.gray0))
        .overlay(RoundedRectangle(cornerRadius: ControlSpec.radius).stroke(palette.gray200))
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
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    SpinnerIcon(size: 13)
                } else if let icon {
                    Image.ic(icon).font(.system(size: 12.5))
                }
                Text(title)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: ControlSpec.height)
            .frame(maxWidth: flexible ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: ControlSpec.radius).fill(background))
            .overlay(RoundedRectangle(cornerRadius: ControlSpec.radius).stroke(border))
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .disabled(disabled || busy)
        .opacity(disabled || busy ? 0.55 : 1)
        .help(title)
    }

    private var foreground: Color {
        if active { return palette.accent }
        switch kind {
        case .primary: return .white
        case .secondary: return palette.gray600
        case .danger: return palette.danger
        }
    }

    private var background: Color {
        if active { return palette.accentSoft }
        switch kind {
        case .primary: return palette.accent
        case .secondary: return palette.gray0
        case .danger: return palette.gray0
        }
    }

    private var border: Color {
        if active { return palette.accent.opacity(0.34) }
        switch kind {
        case .primary: return palette.accent
        case .secondary: return palette.gray200
        case .danger: return palette.gray200
        }
    }
}

/// 设置页带边框的文本输入框(与 PillPicker 同规格;placeholder 承载提示文字)。
struct FormTextField: View {
    @Environment(\.palette) private var palette
    @Binding var text: String
    let placeholder: String
    var monospaced = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: ControlSpec.height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: ControlSpec.radius).fill(palette.gray0))
            .overlay(RoundedRectangle(cornerRadius: ControlSpec.radius).stroke(palette.gray200))
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
        Stepper(title, value: $value, in: range, step: step)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.gray700)
            .padding(.horizontal, 10)
            .frame(height: ControlSpec.height)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: ControlSpec.radius).fill(palette.gray0))
            .overlay(RoundedRectangle(cornerRadius: ControlSpec.radius).stroke(palette.gray200))
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
        .background(RoundedRectangle(cornerRadius: ControlSpec.radius).fill(palette.gray0))
        .overlay(RoundedRectangle(cornerRadius: ControlSpec.radius).stroke(palette.gray200))
    }
}

/// 紧凑宽度的顶部导航条(移动端 / 窄窗口),对应 web ≤760px 的 page-nav-slot。
struct CompactTopBar<Trailing: View>: View {
    @Environment(\.palette) private var palette
    var currentPaperId: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(currentPaperId: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.currentPaperId = currentPaperId
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceNav(collapsed: true, currentPaperId: currentPaperId)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.leading, trafficLightLeadingInset)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(palette.gray0)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }
        .zIndex(2)
    }

    /// macOS 隐藏标题栏后红绿灯悬浮在左上角,紧凑顶栏为其让出水平空间。
    private var trafficLightLeadingInset: CGFloat {
        #if os(macOS)
        return 78
        #else
        return 10
        #endif
    }
}
