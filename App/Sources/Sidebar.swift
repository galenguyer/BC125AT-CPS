import BC125ATKit
import SwiftUI

struct Sidebar: View {
    var config: ScannerConfig
    var issues: [ValidationIssue]
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Channels") {
                Label("All Channels", systemImage: "list.bullet")
                    .badge(config.usedChannelCount)
                    .tag(SidebarItem.allChannels)
                ForEach(1...ScannerConfig.bankCount, id: \.self) { bank in
                    BankRow(bank: bank, config: config, hasErrors: bankHasErrors(bank))
                        .tag(SidebarItem.bank(bank))
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
                .foregroundStyle(scanEnabled ? Color.accentColor : Color.secondary)
        }
        .badge(config.usedChannelCount(inBank: bank))
        .help(scanEnabled ? "Bank \(bank) is included when scanning" : "Bank \(bank) is skipped when scanning")
        .accessibilityValue(scanEnabled ? "Scan enabled" : "Scan disabled")
    }
}
