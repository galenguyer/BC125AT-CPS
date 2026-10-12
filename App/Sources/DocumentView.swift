import BC125ATKit
import SwiftUI

enum SidebarItem: Hashable {
    case allChannels
    case bank(Int)
    case search
    case globalLockouts
    case settings
}

struct DocumentView: View {
    @Binding var document: ScannerDocument
    @Environment(ScannerMonitor.self) private var monitor
    @State private var selection: SidebarItem? = .allChannels
    @State private var reader = ScannerReader()
    @State private var confirmingReplace = false
    @State private var showingIssues = false

    private var config: ScannerConfig { document.config }

    var body: some View {
        let issues = config.validate()
        NavigationSplitView {
            Sidebar(config: config, issues: issues, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            detail(issues: issues)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionStatus()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Read from Scanner", systemImage: "square.and.arrow.down", action: requestRead)
                    .help("Read the whole configuration from the connected scanner")
                    .disabled(!canRead)
                IssuesButton(issues: issues, isPresented: $showingIssues) { location in
                    selection = sidebarItem(for: location)
                }
            }
        }
        .focusedSceneValue(\.readFromScanner, ReadFromScannerAction(perform: requestRead, isEnabled: canRead))
        .confirmationDialog("Replace this document with the scanner's contents?", isPresented: $confirmingReplace) {
            Button("Read and Replace", action: startRead)
        } message: {
            Text("Everything in this document will be replaced by what's on the scanner. You can undo this.")
        }
        .sheet(isPresented: .constant(reader.state.isPresented)) {
            ReadProgressSheet(reader: reader)
        }
    }

    @ViewBuilder
    private func detail(issues: [ValidationIssue]) -> some View {
        switch selection {
        case .allChannels, nil:
            ChannelTableView(config: config, numbers: Array(1...ScannerConfig.channelCount), issues: issues, title: "All Channels")
        case .bank(let bank):
            ChannelTableView(config: config, numbers: Array(Channel.channels(inBank: bank)), issues: issues, title: bankTitle(bank))
        case .search:
            SearchView(config: config, issues: issues)
        case .globalLockouts:
            GlobalLockoutsView(config: config, issues: issues)
        case .settings:
            SettingsView(config: config, issues: issues)
        }
    }

    private func bankTitle(_ bank: Int) -> String {
        let name = config.bankNames[bank - 1]
        return name.isEmpty ? "Bank \(bank)" : "Bank \(bank): \(name)"
    }

    private func sidebarItem(for location: ValidationIssue.Location) -> SidebarItem {
        switch location {
        case .channel(let number): .bank(Channel.bank(ofChannel: number))
        case .bank(let bank): .bank(bank)
        case .settings: .settings
        case .search, .closeCall: .search
        case .globalLockouts: .globalLockouts
        }
    }

    // MARK: Reading

    private var canRead: Bool { monitor.selectedDevice != nil && !reader.isReading }

    private func requestRead() {
        guard canRead else { return }
        if document.config == ScannerConfig() { startRead() } else { confirmingReplace = true }
    }

    private func startRead() {
        guard let device = monitor.selectedDevice else { return }
        reader.read(from: device) { config in
            replaceConfig(with: config)
        }
    }

    /// Replaces the document's contents, keeping app-only bank names and notes. SwiftUI registers
    /// the undo action itself for changes made through the document binding.
    private func replaceConfig(with newConfig: ScannerConfig) {
        var merged = newConfig
        merged.bankNames = document.config.bankNames
        merged.metadata.notes = document.config.metadata.notes
        document.config = merged
    }
}

extension ScannerReader.State {
    var isPresented: Bool {
        if case .idle = self { false } else { true }
    }
}

// MARK: - Toolbar pieces

struct ConnectionStatus: View {
    @Environment(ScannerMonitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        HStack(spacing: 6) {
            Circle()
                .fill(monitor.selectedDevice == nil ? Color.secondary.opacity(0.5) : Color.green)
                .frame(width: 8, height: 8)
            if monitor.devices.count > 1 {
                Picker("Scanner", selection: $monitor.selectedLocation) {
                    ForEach(monitor.devices, id: \.locationID) { device in
                        Text("\(device.productName) (USB \(String(device.locationID, radix: 16)))").tag(Optional(device.locationID))
                    }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text(monitor.selectedDevice?.productName ?? "No scanner connected")
                    .foregroundStyle(monitor.selectedDevice == nil ? .secondary : .primary)
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .help(monitor.selectedDevice == nil ? "Connect a BC125AT with a USB cable" : "Connected over USB")
    }
}

struct IssuesButton: View {
    var issues: [ValidationIssue]
    @Binding var isPresented: Bool
    var reveal: (ValidationIssue.Location) -> Void

    var body: some View {
        let errors = issues.count { $0.severity == .error }
        Button {
            isPresented.toggle()
        } label: {
            Label(issues.isEmpty ? "No Issues" : "\(issues.count) Issues",
                  systemImage: issues.isEmpty ? "checkmark.circle" : errors > 0 ? "xmark.octagon" : "exclamationmark.triangle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(issues.isEmpty ? Color.secondary : errors > 0 ? Color.red : Color.orange)
        }
        .help(issues.isEmpty ? "Nothing in this document would cause a problem on the scanner" : "Show problems that would affect writing to the scanner")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            IssuesList(issues: issues) { location in
                isPresented = false
                reveal(location)
            }
        }
    }
}

struct IssuesList: View {
    var issues: [ValidationIssue]
    var reveal: (ValidationIssue.Location) -> Void

    var body: some View {
        if issues.isEmpty {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle", description: Text("Everything here can be written to the scanner as is."))
                .frame(width: 320, height: 180)
        } else {
            List(issues) { issue in
                Button {
                    reveal(issue.location)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        IssueIcon(severity: issue.severity)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.location.title).font(.headline)
                            Text(issue.message).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 420, height: 320)
        }
    }
}

struct IssueIcon: View {
    var severity: ValidationIssue.Severity

    var body: some View {
        Image(systemName: severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(severity == .error ? .red : .orange)
            .accessibilityLabel(severity == .error ? "Error" : "Warning")
    }
}

extension ValidationIssue.Location {
    var title: String {
        switch self {
        case .channel(let number): "Channel \(number)"
        case .bank(let bank): "Bank \(bank)"
        case .settings: "Settings"
        case .search: "Search"
        case .closeCall: "Close Call"
        case .globalLockouts: "Global Lockouts"
        }
    }
}

// MARK: - Read progress

struct ReadProgressSheet: View {
    var reader: ScannerReader

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch reader.state {
            case .idle:
                EmptyView()
            case .reading(let progress):
                Text("Reading from Scanner").font(.headline)
                ProgressView(value: progress.fraction)
                Text("The scanner shows “Remote Mode” while it's being read. Don't disconnect it.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { reader.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            case .finished(let config):
                Label("Read \(config.usedChannelCount) channels", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if let firmware = config.metadata.firmware {
                    Text("\(config.metadata.model ?? "BC125AT"), \(firmware)").foregroundStyle(.secondary)
                }
                Text("The scanner is now in Scan Hold. Press Scan on the scanner to start scanning again.")
                HStack {
                    Spacer()
                    Button("Done") { reader.dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label("Couldn't Read the Scanner", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("OK") { reader.dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}
