import SwiftUI

struct PapericoWordmark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image("PapericoWordmark")
            .renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(palette.accent)
            .accessibilityLabel("Paperico")
    }
}
