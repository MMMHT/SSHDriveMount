import SwiftUI

enum TailTheme {
    static let accent = Color(red: 0.36, green: 0.38, blue: 0.96)
    static let ink = Color(red: 0.08, green: 0.13, blue: 0.21)
    static let muted = Color(red: 0.43, green: 0.49, blue: 0.59)
    static let sidebar = Color(red: 0.045, green: 0.08, blue: 0.14)
    static let success = Color(red: 0.17, green: 0.65, blue: 0.49)
    static let warning = Color(red: 0.93, green: 0.58, blue: 0.19)
    static let danger = Color(red: 0.91, green: 0.29, blue: 0.36)
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(22)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.black.opacity(0.055)))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 7)
    }
}

struct StatusBadge: View {
    let quality: ConnectionQuality
    var color: Color {
        switch quality {
        case .excellent, .good: TailTheme.success
        case .slow, .unstable: TailTheme.warning
        case .offline: TailTheme.danger
        case .idle: TailTheme.muted
        }
    }
    var body: some View {
        Label(quality.rawValue, systemImage: quality.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(color.opacity(0.11), in: Capsule())
    }
}

struct DependencyRow: View {
    let name: String
    let installed: Bool
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(installed ? TailTheme.success : TailTheme.danger).frame(width: 7, height: 7)
            Text(name).foregroundStyle(.white.opacity(0.72))
            Spacer()
            Text(installed ? "已安装" : "缺少")
                .foregroundStyle(installed ? TailTheme.success : Color(red: 1, green: 0.53, blue: 0.57))
        }
        .font(.system(size: 12))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(TailTheme.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 11))
    }
}
