import BC125ATKit
import SwiftUI

/// Editors for everything except channels (SPEC.md §8.3–8.5). Each control writes straight into
/// the document, so every change is one undo step.

struct SettingsView: View {
    @Binding var config: ScannerConfig
    var issues: [ValidationIssue]

    private var bandPlanNote: String {
        var note = "The band plan sets the channel steps the scanner rounds frequencies to (SPEC.md §3.5)."
        if config.settings.bandPlan == .canada {
            note += " Frequencies can't be checked against the Canada plan, so they're written as entered and any the scanner stores differently are shown after writing."
        }
        return note
    }

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
            Section {
                Picker("Priority Mode", selection: $config.settings.priorityMode) {
                    ForEach(PriorityMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Weather Alert Priority", isOn: $config.settings.weatherAlertPriority)
                Picker("Band Plan", selection: $config.settings.bandPlan) {
                    ForEach(BandPlanRegion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Scanning")
            } footer: {
                Text(bandPlanNote).foregroundStyle(.secondary)
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
                    customRangeRow(index)
                }
            }
            Section("Close Call") {
                Picker("Mode", selection: $config.closeCall.mode) {
                    ForEach(CloseCallMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Alert Beep", isOn: $config.closeCall.alertBeep)
                Toggle("Alert Light", isOn: $config.closeCall.alertLight)
                Toggle("Scan Close Call Hits Bank", isOn: $config.closeCall.scanHits)
                ForEach(CloseCallBand.allCases, id: \.self) { band in
                    Toggle(isOn: $config.closeCall.bandsEnabled[band.rawValue]) {
                        Text(band.displayName) + Text("  \(band.rangeDescription)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .navigationTitle("Search & Close Call")
    }

    /// One compact row: the range's frequencies, then its switch at the trailing edge like the
    /// form's other toggles.
    private func customRangeRow(_ index: Int) -> some View {
        let range = config.search.customRanges[index]
        return HStack {
            Text("Range \(index + 1)")
            Spacer()
            FrequencyField(title: "Lower", frequency: range.lower) { frequency in
                if let frequency { config.search.customRanges[index].lower = frequency }
            }
            .labelsHidden()
            .accessibilityLabel("Range \(index + 1) lower frequency in megahertz")
            .frame(width: 90)
            Text("–").foregroundStyle(.secondary)
            FrequencyField(title: "Upper", frequency: range.upper) { frequency in
                if let frequency { config.search.customRanges[index].upper = frequency }
            }
            .labelsHidden()
            .accessibilityLabel("Range \(index + 1) upper frequency in megahertz")
            .frame(width: 90)
            Text("MHz").foregroundStyle(.secondary)
                .padding(.trailing, 8)
            Toggle("Search range \(index + 1)", isOn: $config.search.customRanges[index].enabled)
                .labelsHidden()
        }
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
