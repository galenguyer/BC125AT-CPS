import BC125ATKit
import SwiftUI

/// The channel editor (SPEC.md §8.2): the AppKit `ChannelTable`, plus search, the Show Empty
/// Channels toggle, and the inspector.
struct ChannelTableView: View {
    @Binding var config: ScannerConfig
    var numbers: [Int]
    var issues: [ValidationIssue]
    var title: String
    /// Identifies this document window, so drags can tell a move from a copy between documents.
    var window: UUID
    /// Selected channel numbers. Kept by the document, so an import can start at the selection.
    @Binding var selection: Set<Int>

    @Environment(ScannerMonitor.self) private var monitor
    @AppStorage("showEmptyChannels") private var showEmptyChannels = false
    @AppStorage("showInspector") private var showInspector = false
    @State private var searchText = ""
    @State private var sort = ChannelSort()

    var body: some View {
        let rows = makeRows()
        ChannelTable(config: $config, rows: rows, selection: $selection, sort: $sort,
                     window: window, pasteStart: numbers.first ?? 1, scope: numbers.first ?? 0,
                     listen: monitor.live.canControl ? { monitor.live.hold(on: $0) } : nil)
            // Switching to another bank starts fresh, as a new table would.
            .onChange(of: numbers) {
                selection = []
                searchText = ""
            }
            .overlay {
                if rows.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView("No Channels", systemImage: "dot.radiowaves.left.and.right",
                                               description: Text("Read from the scanner, paste channels, or show empty channels and type a frequency."))
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
            .inspector(isPresented: $showInspector) {
                ChannelInspector(config: $config, selection: selection, issues: issues)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .toolbar {
                ToolbarItem {
                    Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
                }
            }
    }

    /// The channels to show, filtered by the search text and sorted.
    private func makeRows() -> [ChannelRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var issuesByChannel: [Int: [ValidationIssue]] = [:]
        for issue in issues {
            if case .channel(let number) = issue.location { issuesByChannel[number, default: []].append(issue) }
        }
        var rows = numbers.compactMap { number -> ChannelRow? in
            let channel = config[channel: number]
            if channel.isEmpty, !showEmptyChannels { return nil }
            if !query.isEmpty, !channel.name.lowercased().contains(query),
               !(channel.frequency?.megahertzString.hasPrefix(query) ?? false) { return nil }
            return ChannelRow(number: number, channel: channel, issues: issuesByChannel[number] ?? [])
        }
        switch sort.key {
        case .number:
            break
        case .name:
            rows.sort { a, b in
                let order = a.channel.name.localizedStandardCompare(b.channel.name)
                return order == .orderedSame ? a.number < b.number : order == .orderedAscending
            }
        case .frequency:
            // Empty channels sort after every frequency.
            rows.sort { a, b in
                switch (a.channel.frequency, b.channel.frequency) {
                case let (x?, y?): x == y ? a.number < b.number : x < y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.number < b.number
                }
            }
        }
        return sort.ascending ? rows : rows.reversed()
    }
}
