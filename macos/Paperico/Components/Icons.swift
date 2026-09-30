import SwiftUI

/// Lucide icon → SF Symbol mapping used across the app.
enum Ic {
    static func symbol(_ name: String, fallback: String) -> String {
        UIImageOrNSSymbolExists(name) ? name : fallback
    }

    private static func UIImageOrNSSymbolExists(_ name: String) -> Bool {
        #if os(iOS)
        return UIImage(systemName: name) != nil
        #else
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }

    // Navigation
    static let feather = symbol("feather", fallback: "text.book.closed")
    static let house = symbol("house", fallback: "house.fill")
    static let library = symbol("books.vertical", fallback: "book")
    static let layers = symbol("square.stack.3d.up", fallback: "square.on.square")
    static let bookOpen = symbol("book", fallback: "text.book.closed")
    static let settings = symbol("gearshape", fallback: "gear")
    static let chevronDown = "chevron.down"
    static let chevronRight = "chevron.right"
    static let sun = symbol("sun.max", fallback: "sun.max.fill")
    static let moon = "moon"
    static let panelLeft = symbol("sidebar.left", fallback: "rectangle.leadinghalf.inset.filled")
    static let panelLeftClose = symbol("sidebar.squares.left", fallback: "sidebar.left")
    static let arrowRight = "arrow.right"

    // Home
    static let sparkles = "sparkles"
    static let brain = symbol("brain.head.profile", fallback: "brain")
    static let fileSearch = symbol("text.magnifyingglass", fallback: "magnifyingglass")

    // Library
    static let upload = "square.and.arrow.up"
    static let folderPlus = "folder.badge.plus"
    static let trash = "trash"
    static let fileText = "doc.text"
    static let search = "magnifyingglass"
    static let close = "xmark"
    static let shieldAlert = symbol("exclamationmark.triangle", fallback: "exclamationmark.circle")
    static let check = "check"
    static let checkSquare = symbol("checkmark.square", fallback: "checkmark")
    static let square = "square"
    static let grip = symbol("line.3.horizontal", fallback: "circle.grid.2x2")
    static let folderInput = symbol("tray.and.arrow.down", fallback: "folder.badge.plus")
    static let listFilter = symbol("line.3.horizontal.decrease", fallback: "list.bullet")
    static let refresh = "arrow.clockwise"
    static let cursor = symbol("cursorarrow", fallback: "hand.draw")
    static let pencil = "pencil"

    // Reader
    static let alertCircle = "exclamationmark.circle"
    static let alertTriangle = "exclamationmark.triangle"
    static let bookText = symbol("text.book.closed", fallback: "book")
    static let listTree = symbol("list.bullet.indent", fallback: "list.bullet")
    static let messagesSquare = symbol("bubble.left.and.bubble.right", fallback: "bubble.left")
    static let messageCircle = "bubble.left"
    static let fileDoc = symbol("doc.richtext", fallback: "doc.text")
    static let fileType = symbol("doc.badge.arrow.up", fallback: "doc")
    static let pilcrow = symbol("pilcrow", fallback: "textformat")
    static let languages = symbol("globe", fallback: "character.bubble")
    static let zoomIn = "plus.magnifyingglass"
    static let zoomOut = "minus.magnifyingglass"
    static let gauge = "gauge"
    static let rotateCcw = "arrow.counterclockwise"
    static let alignLeft = "text.alignleft"
    static let grid2 = "square.grid.2x2"
    static let listBullet = "list.bullet"
    static let maximize = symbol("arrow.up.left.and.arrow.down.right", fallback: "plus.viewfinder")
    static let clock = "clock"
    static let eye = "eye"
    static let eyeOff = "eye.slash"
    static let palette = "paintpalette"
    static let save = "square.and.arrow.down"
    static let server = symbol("server.rack", fallback: "externaldrive")
    static let testTube = symbol("testtube.2", fallback: "flask")
    static let bolt = "bolt"
    static let image = "photo"
    static let tag = "tag"
    static let copy = "doc.on.doc"
    static let send = "paperplane.fill"
    static let penLine = symbol("pencil.line", fallback: "pencil")
    static let plus = "plus"
    static let bot = symbol("bubbles.and.sparkles", fallback: "text.bubble")
    static let astroid = "sparkle"
}

extension Image {
    /// Icon in a symbol with our default rendering mode.
    static func ic(_ name: String) -> Image {
        Image(systemName: name)
    }
}

// MARK: - Spinner stand-in for Loader2

struct SpinnerIcon: View {
    var size: CGFloat = 14

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: size, height: size)
    }
}

// MARK: - Status dot

struct StatusDot: View {
    @Environment(\.palette) private var palette
    let status: PaperStatus

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        switch status {
        case .ready: return palette.success
        case .error: return palette.danger
        case .unknown: return Color(hex: "#9a9a9a")!
        default: return palette.amber
        }
    }
}

// MARK: - Skeleton card (library / methods loading)

struct SkeletonCard: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            bar
            bar.frame(width: 68)
            bar.frame(width: 42)
        }
        .padding(18)
        .frame(minHeight: 142, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.gray200))
        .background(palette.gray0)
        .cornerRadius(12)
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(
                LinearGradient(
                    colors: [palette.gray100, palette.gray50, palette.gray100],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(height: 13)
    }
}

// MARK: - Icon button (reader-nav-action / icon-button)

struct RoundIconButton: View {
    @Environment(\.palette) private var palette
    let systemName: String
    var size: CGFloat = 32
    var title: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image.ic(systemName)
                .font(.system(size: size * 0.47, weight: .medium))
                .foregroundStyle(palette.gray500)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Color.clear))
        .contentShape(Rectangle())
        .help(Text(title))
    }
}

// MARK: - Primary / secondary action buttons (home hero + reader error states)

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)

        Group {
            #if os(macOS)
            if #available(macOS 26.0, *) {
                label.glassEffect(accentGlass(palette.accent), in: Capsule())
            } else {
                label.background(RoundedRectangle(cornerRadius: 9).fill(palette.accent))
            }
            #elseif os(iOS)
            if #available(iOS 26.0, *) {
                label.glassEffect(accentGlass(palette.accent), in: Capsule())
            } else {
                label.background(RoundedRectangle(cornerRadius: 9).fill(palette.accent))
            }
            #endif
        }
        .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct PrimaryActionButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(title)
                if let systemImage { Image.ic(systemImage).font(.system(size: 13, weight: .semibold)) }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .noFocusRing()
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.gray700)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)

        Group {
            #if os(macOS)
            if #available(macOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label
                    .background(RoundedRectangle(cornerRadius: 9).fill(palette.gray0))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray300))
            }
            #elseif os(iOS)
            if #available(iOS 26.0, *) {
                label.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label
                    .background(RoundedRectangle(cornerRadius: 9).fill(palette.gray0))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray300))
            }
            #endif
        }
        .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct SecondaryActionButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(title)
                if let systemImage { Image.ic(systemImage).font(.system(size: 13, weight: .semibold)) }
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .noFocusRing()
    }
}
