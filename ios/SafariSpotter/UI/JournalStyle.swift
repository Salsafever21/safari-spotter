import SwiftUI

enum JournalStyle {
    static let paper = Color(hex: 0xF7F2E7)
    static let card = Color(hex: 0xFFFCF5)
    static let ink = Color(hex: 0x182820)
    static let muted = Color(hex: 0x555D51)
    static let forest = Color(hex: 0x294539)
    static let line = Color(hex: 0xDEDACE)
    static let amber = Color(hex: 0xF4C477)
    static let moss = Color(hex: 0xEAE8D9)
    static let camera = Color(hex: 0x16231B)
    static let red = Color(hex: 0xC9473D)

    static func title(_ size: CGFloat = 34) -> Font {
        .custom("Fraunces-Bold", size: size, relativeTo: .largeTitle)
    }

    static let body = Font.custom("DMSans-Regular", size: 15, relativeTo: .body)
    static let bold = Font.custom("DMSans-Bold", size: 15, relativeTo: .body)
    static let label = Font.custom("DMSans-Bold", size: 13, relativeTo: .subheadline)
    static let caption = Font.custom("DMSans-Regular", size: 13, relativeTo: .caption)
    static let micro = Font.custom("DMSans-Bold", size: 11, relativeTo: .caption2)
    static let heading = Font.custom("DMSans-Bold", size: 19, relativeTo: .headline)
}

struct JournalIcon: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        Image(name).resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct JournalActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(JournalStyle.bold)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 12)
            .foregroundStyle(enabled ? Color.white : JournalStyle.muted)
            .background(enabled ? JournalStyle.forest : JournalStyle.moss, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}

struct JournalThumbnail: View {
    let image: UIImage?
    let height: CGFloat
    let placeholder: String

    var body: some View {
        Color.clear.frame(height: height)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    JournalStyle.moss.overlay {
                        Image(systemName: placeholder).font(.title2).foregroundStyle(JournalStyle.muted)
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
