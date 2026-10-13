import AppKit
import BC125ATKit
import SwiftUI

struct Sidebar: View {
    @Binding var config: ScannerConfig
    var issues: [ValidationIssue]
    @Binding var selection: SidebarItem?
    var window: UUID

    var body: some View {
        List(selection: $selection) {
            Section("Channels") {
                Label("All Channels", systemImage: "list.bullet")
                    .badge(config.usedChannelCount)
                    .tag(SidebarItem.allChannels)
                ForEach(1...ScannerConfig.bankCount, id: \.self) { bank in
                    BankRow(bank: bank, config: config, hasErrors: bankHasErrors(bank))
                        .tag(SidebarItem.bank(bank))
                        .contextMenu {
                            Toggle("Include in Scan", isOn: $config.bankScanEnabled[bank - 1])
                        }
                        .dropDestination(for: ChannelDrag.self) { items, _ in
                            dropIntoBank(items, bank: bank)
                        }
                }
            }
            Section("Scanner") {
                Label("Search & Close Call", systemImage: "antenna.radiowaves.left.and.right")
                    .tag(SidebarItem.search)
                Label("Global Lockouts", systemImage: "nosign")
                    .badge(config.globalLockouts.count)
                    .tag(SidebarItem.globalLockouts)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
    }

    /// Dropping channels on a bank moves them (or copies them, from another document) into that
    /// bank's first empty slots. Refuses with a beep if there isn't room.
    private func dropIntoBank(_ items: [ChannelDrag], bank: Int) -> Bool {
        var updated = config
        if items.allSatisfy({ $0.source == window }) {
            guard updated.moveChannels(items.map(\.number), intoBank: bank) != nil else { NSSound.beep(); return false }
        } else {
            let free = Channel.channels(inBank: bank).filter { updated[channel: $0].isEmpty }
            guard free.count >= items.count else { NSSound.beep(); return false }
            for (slot, item) in zip(free, items.sorted { $0.number < $1.number }) { updated[channel: slot] = item.channel }
        }
        config = updated
        return true
    }

    private func bankHasErrors(_ bank: Int) -> Bool {
        issues.contains { issue in
            guard issue.severity == .error, case .channel(let number) = issue.location else { return false }
            return Channel.bank(ofChannel: number) == bank
        }
    }
}

private struct BankRow: View {
    var bank: Int
    var config: ScannerConfig
    var hasErrors: Bool
    /// `.increased` on the selected row, whose background is the accent colour.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let name = config.bankNames[bank - 1]
        let scanEnabled = config.bankScanEnabled[bank - 1]
        Label {
            HStack(spacing: 4) {
                Text(name.isEmpty ? "Bank \(bank)" : "\(bank) · \(name)")
                if hasErrors {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).imageScale(.small)
                        .accessibilityLabel("Has errors")
                }
            }
        } icon: {
            Image(systemName: scanEnabled ? "\(bank % 10).circle.fill" : "\(bank % 10).circle")
                .foregroundStyle(iconStyle(scanEnabled: scanEnabled))
        }
        .badge(config.usedChannelCount(inBank: bank))
        .help(scanEnabled ? "Bank \(bank) is included when scanning" : "Bank \(bank) is skipped when scanning")
        .accessibilityValue(scanEnabled ? "Scan enabled" : "Scan disabled")
    }

    /// Accent for a scanned bank, grey for a skipped one; on the selected row's accent
    /// background, white so the circle stays visible.
    private func iconStyle(scanEnabled: Bool) -> AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.white.opacity(scanEnabled ? 1 : 0.7)) }
        return scanEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }
}
