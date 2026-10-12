import BC125ATKit
import SwiftUI

/// Editors for everything except channels (SPEC.md §8.3–8.5). Each control writes straight into
/// the document, so every change is one undo step.

struct SettingsView: View {
    @Binding var config: ScannerConfig
    var issues: [ValidationIssue]

    var body: some View {
        Form {
            IssuesSection(issues: issues.filter { $0.location == .settings || $0.location == .bank(1) })
            Section("Display & Keypad") {
                Picker("Backlight", selection: $config.settings.backlight) {
                    ForEach(Backlight.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper("Contrast: \(config.settings.contrast)", value: $config.settings.contrast, in: SystemSettings.contrastRange)
                Picker("Key Beep", selection: $config.settings.keyBeep) {
                    ForEach(KeyBeep.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Key Lock", isOn: $config.settings.keyLock)
            }
            Section("Audio") {
                Stepper("Volume: \(config.settings.volume)", value: $config.settings.volume, in: SystemSettings.levelRange)
                Stepper(value: $config.settings.squelch, in: SystemSettings.levelRange) {
                    Text("Squelch: \(config.settings.squelch)") + Text(squelchNote).foregroundStyle(.secondary)
                }
            }
            Section("Scanning") {
                Picker("Priority Mode", selection: $config.settings.priorityMode) {
                    ForEach(PriorityMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Weather Alert Priority", isOn: $config.settings.weatherAlertPriority)
            }
            Section {
                Stepper("Charge Time: \(config.settings.batteryChargeHours) hours", value: $config.settings.batteryChargeHours,
                        in: SystemSettings.batteryChargeRange)
            } header: {
                Text("Battery")
            } footer: {
                Text("For NiMH cells: 1500 mAh → 9 h, 1800 → 11, 2000 → 12, 2100–2200 → 13, 2300 → 14, 2500 → 15, 2700 → 16.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(1...ScannerConfig.bankCount, id: \.self) { bank in
                    HStack {
                        Text("Bank \(bank)").frame(width: 60, alignment: .leading)
                        CommitTextField(title: "Name (saved in this file only)", value: config.bankNames[bank - 1]) { text in
                            config.bankNames[bank - 1] = text
                            return true
                        }
                        .labelsHidden()
                        Toggle("Scan", isOn: $config.bankScanEnabled[bank - 1])
                    }
                }
            } header: {
                Text("Banks")
            } footer: {
                Text("Bank names are kept in this file; the scanner has no place to store them.")
                    .foregroundStyle(.secondary)
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

    private var squelchNote: String {
        switch config.settings.squelch {
        case 0: " (open)"
        case 15: " (closed)"
        default: ""
        }
    }
}

struct SearchView: View {
    @Binding var config: ScannerConfig
    var issues: [ValidationIssue]

    var body: some View {
        Form {
            IssuesSection(issues: issues.filter { $0.location == .search || $0.location == .closeCall })
            Section("Search") {
                Picker("Delay", selection: $config.search.delay) {
                    ForEach(Delay.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("CTCSS/DCS Code Search", isOn: $config.search.codeSearch)
            }
            Section("Service Search Groups") {
                ForEach(ServiceSearchGroup.allCases, id: \.self) { group in
                    Toggle(group.displayName, isOn: $config.search.serviceGroupsEnabled[group.rawValue])
                }
            }
            Section("Custom Search Ranges") {
                ForEach(config.search.customRanges.indices, id: \.self) { index in
                    HStack {
                        Toggle("Range \(index + 1)", isOn: $config.search.customRanges[index].enabled)
                        Spacer()
                        FrequencyField(title: "Lower", frequency: config.search.customRanges[index].lower) { frequency in
                            if let frequency { config.search.customRanges[index].lower = frequency }
                        }
                        .frame(width: 100)
                        Text("–")
                        FrequencyField(title: "Upper", frequency: config.search.customRanges[index].upper) { frequency in
                            if let frequency { config.search.customRanges[index].upper = frequency }
                        }
                        .frame(width: 100)
                        Text("MHz").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Close Call") {
                Picker("Mode", selection: $config.closeCall.mode) {
                    ForEach(CloseCallMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Alert Beep", isOn: $config.closeCall.alertBeep)
                Toggle("Alert Light", isOn: $config.closeCall.alertLight)
                Toggle("Lock Out Hits While Scanning", isOn: $config.closeCall.lockOutHits)
                ForEach(CloseCallBand.allCases, id: \.self) { band in
                    Toggle(band.displayName, isOn: $config.closeCall.bandsEnabled[band.rawValue])
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .navigationTitle("Search & Close Call")
    }
}

struct GlobalLockoutsView: View {
    @Binding var config: ScannerConfig
    var issues: [ValidationIssue]
    @State private var selection = Set<Frequency>()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                IssuesSection(issues: issues.filter { $0.location == .globalLockouts })
                Section("\(config.globalLockouts.count) of \(ScannerConfig.maxGlobalLockouts)") {
                    ForEach(config.globalLockouts, id: \.self) { frequency in
                        Text("\(frequency.megahertzString) MHz").monospacedDigit()
                    }
                }
            }
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if config.globalLockouts.isEmpty {
                    ContentUnavailableView("No Global Lockouts", systemImage: "nosign",
                                           description: Text("Frequencies skipped during search and Close Call appear here."))
                }
            }
            Divider()
            HStack {
                FrequencyField(title: "Add frequency (MHz)", frequency: nil) { frequency in
                    guard let frequency else { return }
                    config.globalLockouts = Array(Set(config.globalLockouts + [frequency])).sorted()
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .id(config.globalLockouts.count) // a fresh, empty field after each addition
                .disabled(config.globalLockouts.count >= ScannerConfig.maxGlobalLockouts)
                Spacer()
                Button("Remove", systemImage: "minus", action: removeSelected)
                    .disabled(selection.isEmpty)
            }
            .padding(10)
        }
        .navigationTitle("Global Lockouts")
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        config.globalLockouts.removeAll { selection.contains($0) }
        selection.removeAll()
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
