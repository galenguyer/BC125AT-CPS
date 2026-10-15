import SwiftUI

/// A one-line yellow note at the bottom of the sidebar when a newer release is out. Clicking it
/// opens the release on GitHub; the X hides it until the next launch or skips the version.
struct UpdateNotice: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            if let notice = updates.notice {
                note(notice)
            }
        }
        .animation(.default, value: updates.notice)
        .task { await updates.checkOnce() }
    }

    private func note(_ notice: UpdateChecker.Notice) -> some View {
        HStack(spacing: 6) {
            Button {
                openURL(notice.page)
            } label: {
                Label("Update \(notice.version) available", systemImage: "arrow.down.circle.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .help("Open the release on GitHub")
            Menu {
                Button("Remind Me Next Launch") { updates.hideForSession() }
                Button("Skip Version \(notice.version)") { updates.skip(notice.version) }
            } label: {
                Image(systemName: "xmark")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Hide this note")
            .accessibilityLabel("Hide update note")
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .font(.callout)
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .frame(height: LiveBar.height)
        .background(.yellow)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
