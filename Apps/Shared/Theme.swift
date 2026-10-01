import SwiftUI
import SleepiCore

enum SleepiTheme {
    static let background = Color(red: 0.047, green: 0.063, blue: 0.10)
    static let card = Color(red: 0.082, green: 0.102, blue: 0.15)
    static let ink = Color(red: 0.94, green: 0.94, blue: 0.97)
    static let muted = Color(red: 0.62, green: 0.67, blue: 0.76)
    static let lavender = Color(red: 0.74, green: 0.71, blue: 0.98)
    static let mint = Color(red: 0.64, green: 0.85, blue: 0.78)
    static func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: Color(red: 0.92, green: 0.74, blue: 0.55)
        case .rem: Color(red: 0.74, green: 0.71, blue: 0.98)
        case .core: Color(red: 0.45, green: 0.56, blue: 0.85)
        case .deep: Color(red: 0.32, green: 0.37, blue: 0.65)
        case .unspecified: .gray
        case .inBed: .gray.opacity(0.5)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(SleepiTheme.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.045)))
    }
}
struct Eyebrow: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(SleepiTheme.muted) }
}
struct DetailLine: View {
    var title: String; var value: String
    var body: some View { HStack { Text(title).foregroundStyle(SleepiTheme.muted); Spacer(); Text(value).foregroundStyle(SleepiTheme.ink).monospacedDigit() }.font(.subheadline) }
}
struct PrimaryButton: View {
    var title: String; var symbol: String = "arrow.right"; var action: () -> Void
    var body: some View {
        Button(action: action) { HStack { Text(title); Spacer(); Image(systemName: symbol) }.font(.system(size: 15, weight: .semibold)).padding(18).foregroundStyle(SleepiTheme.background).background(SleepiTheme.lavender, in: RoundedRectangle(cornerRadius: 17)) }
            .buttonStyle(.plain)
    }
}
struct EmptyCard: View {
    var symbol: String; var title: String; var detail: String
    var body: some View {
        Card {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(SleepiTheme.lavender).padding(.bottom, 6)
            Text(title).font(.title3.weight(.medium))
            Text(detail).font(.subheadline).foregroundStyle(SleepiTheme.muted).lineSpacing(5)
        }
    }
}
