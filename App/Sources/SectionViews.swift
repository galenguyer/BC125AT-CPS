import BC125ATKit
import SwiftUI

/// Read-only views of the non-channel sections (milestone 2). Editing arrives in milestone 3.

struct SettingsView: View {
    var config: ScannerConfig
    var issues: [ValidationIssue]

    var body: some View {
        let settings = config.settings
        Form {
            IssuesSection(issues: issues.filter { $0.location == .settings })
            Section("Display & Keypad") {
                LabeledContent("Backlight", value: settings.backlight.displayName)
                LabeledContent("Contrast", value: "\(settings.contrast)")
                LabeledContent("Key Beep", value: settings.keyBeep.displayName)
                LabeledContent("Key Lock", value: settings.keyLock ? "On" : "Off")
            }
            Section("Audio") {
                LabeledContent("Volume", value: "\(settings.volume)")
                LabeledContent("Squelch", value: settings.squelch == 0 ? "0 (open)" : settings.squelch == 15 ? "15 (closed)" : "\(settings.squelch)")
            }
            Section("Scanning") {
                LabeledContent("Priority Mode", value: settings.priorityMode.displayName)
                LabeledContent("Weather Alert Priority", value: settings.weatherAlertPriority ? "On" : "Off")
            }
            Section("Battery") {
                LabeledContent("Charge Time", value: "\(settings.batteryChargeHours) hours")
            }
            Section("Banks") {
                ForEach(1...ScannerConfig.bankCount, id: \.self) { bank in
                    LabeledContent(config.bankNames[bank - 1].isEmpty ? "Bank \(bank)" : "Bank \(bank) · \(config.bankNames[bank - 1])",
                                   value: config.bankScanEnabled[bank - 1] ? "Scanned" : "Skipped")
                }
            }
            if let readAt = config.metadata.readAt {
                Section("Source") {
                    LabeledContent("Read From", value: [config.metadata.model, config.metadata.firmware].compactMap { $0 }.joined(separator: ", "))
                    LabeledContent("Read At", value: readAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

struct SearchView: View {
    var config: ScannerConfig
    var issues: [ValidationIssue]

    var body: some View {
        let search = config.search
        let closeCall = config.closeCall
        Form {
            IssuesSection(issues: issues.filter { $0.location == .search || $0.location == .closeCall })
            Section("Search") {
                LabeledContent("Delay", value: search.delay.displayName)
                LabeledContent("CTCSS/DCS Code Search", value: search.codeSearch ? "On" : "Off")
            }
            Section("Service Search Groups") {
                ForEach(ServiceSearchGroup.allCases, id: \.self) { group in
                    EnabledRow(title: group.displayName, enabled: search.serviceGroupsEnabled[group.rawValue])
                }
            }
            Section("Custom Search Ranges") {
                ForEach(search.customRanges.indices, id: \.self) { index in
                    let range = search.customRanges[index]
                    LabeledContent {
                        HStack {
                            Text("\(range.lower.megahertzString) – \(range.upper.megahertzString) MHz").monospacedDigit()
                            EnabledMark(enabled: range.enabled)
                        }
                    } label: {
                        Text("Range \(index + 1)")
                    }
                }
            }
            Section("Close Call") {
                LabeledContent("Mode", value: closeCall.mode.displayName)
                LabeledContent("Alert Beep", value: closeCall.alertBeep ? "On" : "Off")
                LabeledContent("Alert Light", value: closeCall.alertLight ? "On" : "Off")
                LabeledContent("Lock Out Hits While Scanning", value: closeCall.lockOutHits ? "On" : "Off")
                ForEach(CloseCallBand.allCases, id: \.self) { band in
                    EnabledRow(title: band.displayName, enabled: closeCall.bandsEnabled[band.rawValue])
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Search & Close Call")
    }
}

struct GlobalLockoutsView: View {
    var config: ScannerConfig
    var issues: [ValidationIssue]

    var body: some View {
        Group {
            if config.globalLockouts.isEmpty {
                ContentUnavailableView("No Global Lockouts", systemImage: "nosign",
                                       description: Text("Frequencies locked out during search and Close Call appear here."))
            } else {
                List {
                    IssuesSection(issues: issues.filter { $0.location == .globalLockouts })
                    Section("\(config.globalLockouts.count) of \(ScannerConfig.maxGlobalLockouts)") {
                        ForEach(config.globalLockouts, id: \.self) { frequency in
                            Text("\(frequency.megahertzString) MHz").monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("Global Lockouts")
    }
}

private struct IssuesSection: View {
    var issues: [ValidationIssue]

    var body: some View {
        if !issues.isEmpty {
            Section {
                ForEach(issues) { issue in
                    Label {
                        Text(issue.message)
                    } icon: {
                        IssueIcon(severity: issue.severity)
                    }
                }
            }
        }
    }
}

private struct EnabledRow: View {
    var title: String
    var enabled: Bool

    var body: some View {
        LabeledContent(title) { EnabledMark(enabled: enabled) }
    }
}

private struct EnabledMark: View {
    var enabled: Bool

    var body: some View {
        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(enabled ? Color.green : Color.secondary)
            .accessibilityLabel(enabled ? "Enabled" : "Disabled")
    }
}
