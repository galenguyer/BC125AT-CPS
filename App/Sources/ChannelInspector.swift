import BC125ATKit
import SwiftUI

/// Details for the selected channel or channels (SPEC.md §8.1, ⌥⌘I).
struct ChannelInspector: View {
    @Binding var config: ScannerConfig
    var selection: Set<Int>
    var issues: [ValidationIssue]

    var body: some View {
        switch selection.count {
        case 0:
            ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                   description: Text("Select a channel to see and edit its details."))
        case 1:
            single(selection.first!)
        default:
            multiple(selection.sorted())
        }
    }

    // MARK: One channel

    private func single(_ number: Int) -> some View {
        let channel = config[channel: number]
        let bank = Channel.bank(ofChannel: number)
        let bankName = config.bankNames[bank - 1]
        return Form {
            Section {
                FrequencyField(title: "Frequency (MHz)", frequency: channel.frequency, allowsEmpty: true) { frequency in
                    config.setFrequency(frequency, ofChannel: number)
                }
                .accessibilityLabel("Frequency in megahertz")
                if let frequency = channel.frequency, let stored = BandPlan.bc125at.storedValue(for: frequency), stored != frequency {
                    LabeledContent("Stored As", value: "\(stored.megahertzString) MHz")
                        .foregroundStyle(.orange)
                }
                if !channel.isEmpty {
                    CommitTextField(title: "Name", value: channel.name) { text in
                        edit(number) { $0.name = text }
                        return true
                    }
                    .accessibilityLabel("Name")
                    LabeledContent("Characters", value: "\(channel.name.count) of \(Channel.maxNameLength)")
                        .foregroundStyle(channel.name.count > Channel.maxNameLength ? .red : .secondary)
                }
            } header: {
                Text("Channel \(number) · Bank \(bank)\(bankName.isEmpty ? "" : " (\(bankName))")")
            } footer: {
                if channel.isEmpty {
                    Text("This channel is empty. Type a frequency to add one.").foregroundStyle(.secondary)
                }
            }
            if !channel.isEmpty {
                Section("Reception") {
                    Picker("Modulation", selection: binding(number, \.modulation)) {
                        ForEach(Modulation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("Tone") {
                        Menu(channel.tone.displayName) {
                            ToneMenuItems { tone in edit(number) { $0.tone = tone } }
                        }
                        .fixedSize()
                        .accessibilityLabel("Tone")
                        .accessibilityValue(channel.tone.displayName)
                    }
                    Picker("Delay", selection: binding(number, \.delay)) {
                        ForEach(Delay.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    Toggle("Locked Out", isOn: binding(number, \.lockedOut))
                    Toggle("Priority", isOn: binding(number, \.priority))
                } header: {
                    Text("Scanning")
                } footer: {
                    Text("Each bank has one priority channel; turning this on turns off the bank's other one.")
                        .foregroundStyle(.secondary)
                }
            }
            let channelIssues = issues.filter { $0.location == .channel(number) }
            if !channelIssues.isEmpty {
                Section("Issues") {
                    ForEach(channelIssues) { issue in
                        Label { Text(issue.message) } icon: { IssueIcon(severity: issue.severity) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Several channels

    private func multiple(_ numbers: [Int]) -> some View {
        let used = numbers.filter { !config[channel: $0].isEmpty }
        return Form {
            Section("\(numbers.count) Channels Selected") {
                LabeledContent("In Use", value: "\(used.count)")
                LabeledContent("Locked Out", value: "\(used.count { config[channel: $0].lockedOut })")
            }
            if !used.isEmpty {
                Section("Change All") {
                    LabeledContent("Modulation") {
                        Menu(common(used, \.modulation)?.displayName ?? "Mixed") {
                            ForEach(Modulation.allCases, id: \.self) { modulation in
                                Button(modulation.displayName) { config.editChannels(used) { $0.modulation = modulation } }
                            }
                        }
                        .fixedSize()
                    }
                    LabeledContent("Tone") {
                        Menu(common(used, \.tone)?.displayName ?? "Mixed") {
                            ToneMenuItems { tone in config.editChannels(used) { $0.tone = tone } }
                        }
                        .fixedSize()
                    }
                    LabeledContent("Delay") {
                        Menu(common(used, \.delay)?.displayName ?? "Mixed") {
                            ForEach(Delay.allCases, id: \.self) { delay in
                                Button(delay.displayName) { config.editChannels(used) { $0.delay = delay } }
                            }
                        }
                        .fixedSize()
                    }
                    HStack {
                        Button("Lock Out All") { config.editChannels(used) { $0.lockedOut = true } }
                        Button("Unlock All") { config.editChannels(used) { $0.lockedOut = false } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Helpers

    private func edit(_ number: Int, _ change: (inout Channel) -> Void) {
        config.editChannels([number], change)
    }

    private func binding<Value>(_ number: Int, _ keyPath: WritableKeyPath<Channel, Value>) -> Binding<Value> {
        Binding(get: { config[channel: number][keyPath: keyPath] },
                set: { value in edit(number) { $0[keyPath: keyPath] = value } })
    }

    private func common<Value: Equatable>(_ numbers: [Int], _ keyPath: KeyPath<Channel, Value>) -> Value? {
        let values = numbers.map { config[channel: $0][keyPath: keyPath] }
        return values.dropFirst().allSatisfy { $0 == values.first } ? values.first : nil
    }
}
