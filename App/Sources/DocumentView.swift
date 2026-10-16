import BC125ATKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var writer = ScannerWriter()
    @State private var confirmingReplace = false
    @State private var showingIssues = false
    @State private var blockingErrors: [ValidationIssue] = []
    /// One `fileImporter` and one `fileExporter` serve both formats, since SwiftUI honours only
    /// one of each per view. The kind and the file are kept apart from the `is presented` flags
    /// because SwiftUI clears those before calling the completion handler.
    @State private var importing = false
    @State private var importKind = ImportKind.csv
    @State private var exporting = false
    /// Built only when Export is chosen.
    @State private var exportFile: ExportFile?
    @State private var importSummary: (title: String, message: String)?
    @State private var radioReferenceFile: RadioReferenceFile?
    /// Channels selected in the channel table.
    @State private var channelSelection = Set<Int>()
    /// Identifies this window for drag and drop.
    @State private var window = UUID()
    @AppStorage(AppSettingsView.duplicateWarningsKey) private var duplicateWarnings = true

    private var config: ScannerConfig { document.config }

    var body: some View {
        let issues = config.validate(duplicateFrequencies: duplicateWarnings)
        NavigationSplitView {
            Sidebar(config: $document.config, issues: issues, selection: $selection, window: window)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
                .safeAreaInset(edge: .bottom, spacing: 0) { UpdateNotice() }
        } detail: {
            VStack(spacing: 0) {
                detail(issues: issues)
                LiveBar(live: monitor.live)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionStatus()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Read from Scanner", systemImage: "square.and.arrow.down", action: requestRead)
                    .help("Read the whole configuration from the connected scanner")
                    .disabled(!canUseScanner)
                Button("Write to Scanner", systemImage: "square.and.arrow.up", action: requestWrite)
                    .help("Write this document to the connected scanner")
                    .disabled(!canUseScanner)
                IssuesButton(issues: issues, isPresented: $showingIssues) { location in
                    selection = sidebarItem(for: location)
                }
            }
        }
        .focusedSceneValue(\.documentActions, DocumentActions(
            read: requestRead, write: requestWrite, canUseScanner: canUseScanner,
            importCSV: { startImport(.csv) }, exportCSV: { startExport(.csv(config)) },
            importRadioReference: { startImport(.radioReference) },
            importUniden: { startImport(.uniden) }, exportUniden: { startExport(.uniden(config)) },
            compare: requestCompare
        ))
        .confirmationDialog("Replace this document with the scanner's contents?", isPresented: $confirmingReplace) {
            Button("Read and Replace", action: startRead)
        } message: {
            Text("Everything in this document will be replaced by what's on the scanner. You can undo this.")
        }
        .alert("Fix \(blockingErrors.count) \(blockingErrors.count == 1 ? "Problem" : "Problems") Before Writing",
               isPresented: Binding(get: { !blockingErrors.isEmpty }, set: { if !$0 { blockingErrors = [] } })) {
            Button("Show Problems") { showingIssues = true }
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockingErrors.prefix(5).map { "\($0.location.title): \($0.message)" }.joined(separator: "\n")
                 + (blockingErrors.count > 5 ? "\n…and \(blockingErrors.count - 5) more" : ""))
        }
        .alert(importSummary?.title ?? "", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("OK") {}
        } message: {
            Text(importSummary?.message ?? "")
        }
        .sheet(isPresented: .constant(reader.state.isPresented)) {
            ReadProgressSheet(reader: reader)
        }
        .sheet(isPresented: .constant(writer.state.isPresented)) {
            WriteSheet(writer: writer, write: startWrite)
        }
        .sheet(item: $radioReferenceFile) { file in
            RadioReferenceImportSheet(file: file, config: config, selection: showsChannels ? channelSelection : []) { channels, start in
                insertChannels(channels, at: start)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: importKind.contentTypes) { result in
            guard case .success(let url) = result else { return }
            switch importKind {
            case .csv: importCSV(from: url)
            case .uniden: importUniden(from: url)
            case .radioReference: openRadioReference(url)
            }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportFile?.contentType ?? .commaSeparatedText,
                      defaultFilename: exportFile?.defaultName) { _ in exportFile = nil }
    }

    @ViewBuilder
    private func detail(issues: [ValidationIssue]) -> some View {
        switch selection {
        case .allChannels, .bank, nil:
            // One table for All Channels and every bank, so switching only reloads its rows
            // instead of building a new table with all its controls.
            ChannelTableView(config: $document.config, numbers: channelNumbers, issues: issues, title: channelTitle, window: window,
                             selection: $channelSelection)
        case .search:
            SearchView(config: $document.config, issues: issues)
        case .globalLockouts:
            GlobalLockoutsView(config: $document.config, issues: issues)
        case .settings:
            SettingsView(config: $document.config, issues: issues)
        }
    }

    private var showsChannels: Bool {
        switch selection {
        case .allChannels, .bank, nil: true
        default: false
        }
    }

    private var channelNumbers: [Int] {
        if case .bank(let bank) = selection { Array(Channel.channels(inBank: bank)) } else { Array(1...ScannerConfig.channelCount) }
    }

    private var channelTitle: String {
        if case .bank(let bank) = selection { bankTitle(bank) } else { "All Channels" }
    }

    private func bankTitle(_ bank: Int) -> String {
        let name = config.bankNames[bank - 1]
        return name.isEmpty ? "Bank \(bank)" : "Bank \(bank): \(name)"
    }

    private func sidebarItem(for location: ValidationIssue.Location) -> SidebarItem {
        switch location {
        case .channel(let number): .bank(Channel.bank(ofChannel: number))
        case .bank: .settings
        case .settings: .settings
        case .search, .closeCall: .search
        case .globalLockouts: .globalLockouts
        }
    }

    private var canUseScanner: Bool { monitor.selectedDevice != nil && !reader.isReading && !writer.isBusy }

    // MARK: Reading

    private func requestRead() {
        guard canUseScanner else { return }
        if document.config == ScannerConfig() { startRead() } else { confirmingReplace = true }
    }

    private func startRead() {
        guard let device = monitor.selectedDevice else { return }
        reader.read(from: device, live: monitor.live) { config in
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

    // MARK: Writing

    /// Errors block writing (SPEC.md §7); warnings don't.
    private func requestWrite() {
        guard canUseScanner, let device = monitor.selectedDevice else { return }
        let errors = config.validate().filter { $0.severity == .error }
        guard errors.isEmpty else {
            blockingErrors = errors
            return
        }
        writer.prepare(document: config, device: device, live: monitor.live)
    }

    /// Like Write to Scanner, but only lists the differences. Works even if the document has
    /// errors, since nothing is written.
    private func requestCompare() {
        guard canUseScanner, let device = monitor.selectedDevice else { return }
        writer.prepare(document: config, device: device, live: monitor.live, compareOnly: true)
    }

    private func startWrite() {
        guard let device = monitor.selectedDevice else { return }
        writer.write(device: device, live: monitor.live) { report, plan in
            // When everything verified, update the document to exactly what the scanner stored
            // (snapped frequencies, trimmed names). On failure, keep the document as the user left it.
            guard report.succeeded, !plan.adjustments.isEmpty || !report.storedDifferently.isEmpty else { return }
            var updated = report.acceptedConfig
            updated.metadata = document.config.metadata
            // Channels with only a name aren't written; keep them so the name isn't lost.
            for number in 1...ScannerConfig.channelCount where document.config[channel: number].isEmpty {
                updated[channel: number] = document.config[channel: number]
            }
            document.config = updated
        }
    }

    // MARK: Import and export

    private func startImport(_ kind: ImportKind) {
        importKind = kind
        importing = true
    }

    private func startExport(_ file: ExportFile) {
        exportFile = file
        exporting = true
    }

    // MARK: CSV

    private func importCSV(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let imported = try CSVFormat.importChannels(from: text)
            var updated = document.config
            for (number, channel) in imported.channels { updated[channel: number] = channel }
            document.config = updated
            var summary = "\(imported.channels.count) \(imported.channels.count == 1 ? "channel" : "channels") imported from \(url.lastPathComponent)."
            if !imported.problems.isEmpty {
                summary += "\n\n\(imported.problems.count) \(imported.problems.count == 1 ? "row was" : "rows were") skipped:\n"
                summary += imported.problems.prefix(8).map { "Line \($0.line): \($0.message)" }.joined(separator: "\n")
            }
            importSummary = ("Channels Imported", summary)
        } catch let error as CSVFormat.ImportError {
            importSummary = ("Couldn't Import Channels", error.description)
        } catch {
            importSummary = ("Couldn't Import Channels", error.localizedDescription)
        }
    }

    // MARK: RadioReference

    private func openRadioReference(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let entries = try RadioReferenceFormat.entries(from: text, bandPlan: config.channelPlan)
            guard entries.contains(where: \.isUsable) else {
                importSummary = ("No Frequencies to Import",
                                 "None of the \(entries.count) frequencies in \(url.lastPathComponent) can be used on the BC125AT. It receives analog AM, FM and FMN in 25–54, 108–174, 225–380 and 400–512 MHz.")
                return
            }
            radioReferenceFile = RadioReferenceFile(name: url.lastPathComponent, entries: entries)
        } catch let error as RadioReferenceFormat.ImportError {
            importSummary = ("Couldn't Read the RadioReference File", error.description)
        } catch {
            importSummary = ("Couldn't Read the RadioReference File", error.localizedDescription)
        }
    }

    /// Adds channels to empty slots as one undo step, then shows where they went.
    private func insertChannels(_ channels: [Channel], at start: Int) {
        var updated = document.config
        guard updated.insert(channels, at: start) else { return }
        document.config = updated
        let firstBank = Channel.bank(ofChannel: start)
        selection = firstBank == Channel.bank(ofChannel: start + channels.count - 1) ? .bank(firstBank) : .allChannels
    }

    /// Replaces the document with a file from Uniden's software, as one undo step. The file has
    /// no global lockouts, so the document's are kept, as are its notes and any bank names the
    /// file leaves at Uniden's defaults.
    private func importUniden(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            var imported = try UnidenFormat.decode(Data(contentsOf: url))
            let current = document.config
            imported.globalLockouts = current.globalLockouts
            for bank in imported.bankNames.indices where imported.bankNames[bank].isEmpty {
                imported.bankNames[bank] = current.bankNames[bank]
            }
            imported.metadata = current.metadata
            document.config = imported

            var message = "Read \(imported.usedChannelCount) channels and every setting from \(url.lastPathComponent)."
            if !current.globalLockouts.isEmpty {
                message += "\n\nUniden's files have no global lockouts, so this document's \(current.globalLockouts.count) were kept."
            }
            if imported.settings.bandPlan == .canada {
                message += "\n\nThe file sets the band plan to Canada, so writing it will switch the scanner to Canada."
            }
            importSummary = ("Uniden File Imported", message)
        } catch let error as UnidenFormat.ImportError {
            importSummary = ("Couldn't Import the Uniden File", error.description)
        } catch {
            importSummary = ("Couldn't Import the Uniden File", error.localizedDescription)
        }
    }
}

enum ImportKind {
    case csv, uniden, radioReference

    var contentTypes: [UTType] {
        switch self {
        case .csv, .radioReference: [.commaSeparatedText, .plainText]
        case .uniden: [.unidenBC125AT]
        }
    }
}

extension UTType {
    /// Files from Uniden's BC125AT software. Declared as imported in Info.plist.
    static let unidenBC125AT = UTType(importedAs: "net.k9fgt.bc125at.uniden-ss", conformingTo: .plainText)
}

/// A file to export: CSV channels, or a whole configuration for Uniden's software.
struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .unidenBC125AT]
    var data: Data
    var contentType: UTType
    var defaultName: String

    static func csv(_ config: ScannerConfig) -> ExportFile {
        ExportFile(data: Data(CSVFormat.export(config).utf8), contentType: .commaSeparatedText, defaultName: "Channels")
    }

    static func uniden(_ config: ScannerConfig) -> ExportFile {
        ExportFile(data: UnidenFormat.encode(config), contentType: .unidenBC125AT, defaultName: "Scanner")
    }

    init(data: Data, contentType: UTType, defaultName: String) {
        self.data = data
        self.contentType = contentType
        self.defaultName = defaultName
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
        defaultName = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension ScannerWriter.State {
    var isPresented: Bool {
        if case .idle = self { false } else { true }
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
            Label(issues.isEmpty ? "No Issues" : issues.count == 1 ? "1 Issue" : "\(issues.count) Issues",
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
    @Environment(ScannerMonitor.self) private var monitor

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
                Text(monitor.live.modeAfterUse)
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
