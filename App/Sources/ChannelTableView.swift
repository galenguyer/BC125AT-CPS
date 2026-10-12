import BC125ATKit
import SwiftUI

struct ChannelRow: Identifiable {
    var id: Int { number }
    var number: Int
    var channel: Channel
    var issues: [ValidationIssue]

    var frequencyText: String { channel.frequency?.megahertzString ?? "" }
}

/// Read-only channel list (milestone 2). Editing arrives in milestone 3.
struct ChannelTableView: View {
    var config: ScannerConfig
    var numbers: [Int]
    var issues: [ValidationIssue]
    var title: String

    @AppStorage("showEmptyChannels") private var showEmptyChannels = false
    @State private var searchText = ""
    @State private var selection = Set<Int>()
    @State private var sortOrder = [KeyPathComparator(\ChannelRow.number)]

    var body: some View {
        let rows = makeRows()
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { row in
                if let worst = row.issues.map(\.severity).max() {
                    IssueIcon(severity: worst)
                        .help(row.issues.map(\.message).joined(separator: "\n"))
                }
            }
            .width(18)
            TableColumn("#", value: \.number) { row in
                Text("\(row.number)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 32, ideal: 40, max: 50)
            TableColumn("Name", value: \.channel.name) { row in
                Text(row.channel.name)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Frequency (MHz)", value: \.frequencyText) { row in
                Text(row.frequencyText).monospacedDigit()
            }
            .width(min: 90, ideal: 110)
            TableColumn("Mod") { row in
                Text(row.channel.isEmpty ? "" : row.channel.modulation.displayName)
            }
            .width(min: 40, ideal: 50)
            TableColumn("Tone") { row in
                Text(row.channel.isEmpty || row.channel.tone == .none ? "" : row.channel.tone.displayName)
            }
            .width(min: 70, ideal: 95)
            TableColumn("Delay") { row in
                Text(row.channel.isEmpty ? "" : row.channel.delay.displayName).monospacedDigit()
            }
            .width(min: 40, ideal: 50)
            TableColumn("L/O") { row in
                if !row.channel.isEmpty, row.channel.lockedOut {
                    Image(systemName: "nosign").accessibilityLabel("Locked out")
                }
            }
            .width(min: 28, ideal: 32)
            TableColumn("Pri") { row in
                if !row.channel.isEmpty, row.channel.priority {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Priority")
                }
            }
            .width(min: 28, ideal: 32)
        }
        .overlay {
            if rows.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No Channels", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Use Read from Scanner to load your scanner's channels."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Name or frequency")
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Toggle("Show Empty Channels", systemImage: "eye", isOn: $showEmptyChannels)
                    .help(showEmptyChannels ? "Hide empty channels" : "Show empty channels")
            }
        }
    }

    private func makeRows() -> [ChannelRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = numbers.compactMap { number -> ChannelRow? in
            let channel = config[channel: number]
            if channel.isEmpty, !showEmptyChannels { return nil }
            let row = ChannelRow(number: number, channel: channel, issues: issues.filter { $0.location == .channel(number) })
            if !query.isEmpty, !row.channel.name.lowercased().contains(query), !row.frequencyText.hasPrefix(query) { return nil }
            return row
        }
        return rows.sorted(using: sortOrder)
    }
}
