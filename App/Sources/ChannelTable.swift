import AppKit
import BC125ATKit
import SwiftUI
import UniformTypeIdentifiers

/// The channel table, drawn with AppKit (SPEC.md §8.2).
///
/// SwiftUI's `Table` re-lays out every visible row on each frame of a resize, so the sidebar
/// animation dropped most of its frames. This `NSTableView` uses plain AppKit cells that are
/// reused as rows scroll, updates only the rows whose channel changed, and lets only the Name
/// column grow and shrink with the window.
///
/// Every change goes through `config`, so each is a single undo step; bulk edits, drops and
/// pastes change many channels in one step.
struct ChannelTable: NSViewRepresentable {
    @Binding var config: ScannerConfig
    var rows: [ChannelRow]
    @Binding var selection: Set<Int>
    @Binding var sort: ChannelSort
    /// Identifies this document window, so drags can tell a move from a copy between documents.
    var window: UUID
    /// Where a paste goes when nothing is selected.
    var pasteStart: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ChannelNSTableView()
        table.coordinator = context.coordinator
        for column in ChannelColumn.allCases { table.addTableColumn(column.makeTableColumn()) }
        table.style = .inset
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        // Only the Name column has the autoresizing mask, so it alone takes up width changes.
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autosaveName = "ChannelTable"
        table.autosaveTableColumns = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.channelDrag])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.setAccessibilityLabel("Channels")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.table = table
        context.coordinator.update(from: self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }
}

/// How the table is sorted. Kept by the SwiftUI view, which filters and sorts the rows.
struct ChannelSort: Equatable {
    enum Key: String {
        case number, name, frequency
    }

    var key = Key.number
    var ascending = true
}

struct ChannelRow: Equatable {
    var number: Int
    var channel: Channel
    var issues: [ValidationIssue]
}

extension NSPasteboard.PasteboardType {
    static let channelDrag = NSPasteboard.PasteboardType(UTType.bc125atChannelDrag.identifier)
}

// MARK: - Columns

enum ChannelColumn: String, CaseIterable {
    case issue, number, name, frequency, modulation, tone, delay, lockout, priority

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    /// Headers are spelled out, as VoiceOver reads them for each cell.
    var title: String {
        switch self {
        case .issue: ""
        case .number: "#"
        case .name: "Name"
        case .frequency: "Frequency (MHz)"
        case .modulation: "Modulation"
        case .tone: "Tone"
        case .delay: "Delay"
        case .lockout: "Lockout"
        case .priority: "Priority"
        }
    }

    @MainActor
    func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        let (min, ideal, max): (CGFloat, CGFloat, CGFloat) = switch self {
        case .issue: (18, 18, 18)
        case .number: (32, 40, 60)
        case .name: (100, 170, 10_000)
        case .frequency: (90, 115, 200)
        case .modulation: (75, 90, 150)
        case .tone: (80, 115, 200)
        case .delay: (60, 70, 120)
        case .lockout, .priority: (50, 60, 120)
        }
        column.minWidth = min
        column.width = ideal
        column.maxWidth = max
        column.resizingMask = self == .name ? [.autoresizingMask, .userResizingMask]
            : self == .issue ? [] : .userResizingMask
        switch self {
        case .number: column.sortDescriptorPrototype = NSSortDescriptor(key: ChannelSort.Key.number.rawValue, ascending: true)
        case .name: column.sortDescriptorPrototype = NSSortDescriptor(key: ChannelSort.Key.name.rawValue, ascending: true)
        case .frequency: column.sortDescriptorPrototype = NSSortDescriptor(key: ChannelSort.Key.frequency.rawValue, ascending: true)
        default: break
        }
        return column
    }
}

// MARK: - Table view

/// Adds Copy, Cut, Paste and Delete, which reach the table through the responder chain when it
/// has focus (a cell being edited handles them itself).
final class ChannelNSTableView: NSTableView {
    weak var coordinator: ChannelTable.Coordinator?

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }

    @objc func cut(_ sender: Any?) {
        coordinator?.copySelection()
        coordinator?.clearSelection()
    }

    @objc func paste(_ sender: Any?) { coordinator?.paste() }

    @objc func delete(_ sender: Any?) { coordinator?.clearSelection() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .delete || event.specialKey == .deleteForward, !selectedRowIndexes.isEmpty {
            coordinator?.clearSelection()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Cells

/// One cell: a single AppKit control, laid out by frame (no constraints) and centered vertically.
final class ChannelCell: NSTableCellView, NSMenuDelegate {
    var number = 0
    var control: NSView?
    /// Text fields fill the cell; buttons and pop-ups keep their natural width.
    var fillsWidth = false
    weak var coordinator: ChannelTable.Coordinator?

    override func layout() {
        super.layout()
        guard let control else { return }
        let size = control.intrinsicContentSize
        let height = min(bounds.height, size.height > 0 ? size.height : bounds.height)
        let width = fillsWidth || size.width <= 0 ? bounds.width - 4 : min(bounds.width - 4, size.width)
        control.frame = NSRect(x: 2, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
    }

    // The Tone pull-down builds its 150-odd items only when opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.count == 1 else { return }
        for item in ToneMenu.items(target: self, action: #selector(toneChosen(_:))) { menu.addItem(item) }
    }

    @objc func toneChosen(_ sender: NSMenuItem) {
        guard let tone = ToneMenu.tone(from: sender) else { return }
        coordinator?.edit([number]) { $0.tone = tone }
    }
}

/// None / Search / No Tone, then CTCSS and DCS submenus, as AppKit menu items. Each item's
/// `representedObject` is the tone's code.
enum ToneMenu {
    @MainActor
    static func items(target: AnyObject, action: Selector) -> [NSMenuItem] {
        func item(_ tone: ToneCode) -> NSMenuItem {
            let item = NSMenuItem(title: tone.displayName, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = tone.code
            return item
        }
        func submenu(_ title: String, _ tones: [ToneCode]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            menu.items = tones.map(item)
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = menu
            return parent
        }
        return [
            item(.none), item(.search), item(.noTone),
            submenu("CTCSS", ToneCode.ctcssTenthsHz.indices.map { .ctcss(index: $0) }),
            submenu("DCS", ToneCode.dcsCodes.indices.map { .dcs(index: $0) }),
        ]
    }

    @MainActor
    static func tone(from sender: NSMenuItem) -> ToneCode? {
        (sender.representedObject as? Int).flatMap(ToneCode.init(code:))
    }
}

// MARK: - Coordinator

extension ChannelTable {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: ChannelTable
        weak var table: ChannelNSTableView?
        private var rows: [ChannelRow] = []
        /// Set while pushing SwiftUI state into the table, so the table's callbacks don't echo it back.
        private var updating = false
        /// The channels the context menu acts on.
        private var menuNumbers: [Int] = []

        init(_ parent: ChannelTable) {
            self.parent = parent
        }

        private var config: ScannerConfig { parent.config }

        // MARK: Updates from SwiftUI

        func update(from parent: ChannelTable) {
            self.parent = parent
            guard let table else { return }
            updating = true
            defer { updating = false }

            let old = rows
            rows = parent.rows
            if old.map(\.number) != rows.map(\.number) {
                table.reloadData()
            } else {
                // Same rows in the same order: refresh the visible cells of changed rows in place.
                for index in rows.indices where rows[index] != old[index] {
                    for (columnIndex, column) in table.tableColumns.enumerated() {
                        guard let cell = table.view(atColumn: columnIndex, row: index, makeIfNecessary: false) as? ChannelCell,
                              let kind = ChannelColumn(rawValue: column.identifier.rawValue) else { continue }
                        configure(cell, kind, rows[index])
                    }
                }
            }

            let descriptor = NSSortDescriptor(key: parent.sort.key.rawValue, ascending: parent.sort.ascending)
            if table.sortDescriptors.first != descriptor { table.sortDescriptors = [descriptor] }

            let selected = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].number) })
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let kind = ChannelColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: kind.identifier, owner: nil) as? ChannelCell ?? makeCell(kind)
            configure(cell, kind, rows[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].number : nil })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let first = tableView.sortDescriptors.first,
                  let key = first.key.flatMap(ChannelSort.Key.init(rawValue:)) else { return }
            parent.sort = ChannelSort(key: key, ascending: first.ascending)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
            let column = table.tableColumns[table.clickedColumn].identifier.rawValue
            let target = column == ChannelColumn.frequency.rawValue || rows[table.clickedRow].channel.isEmpty
                ? ChannelColumn.frequency : .name
            guard let index = table.tableColumns.firstIndex(where: { $0.identifier == target.identifier }) else { return }
            table.editColumn(index, row: table.clickedRow, with: nil, select: true)
        }

        // MARK: Cells

        private func makeCell(_ kind: ChannelColumn) -> ChannelCell {
            let cell = ChannelCell()
            cell.identifier = kind.identifier
            cell.coordinator = self
            let control: NSView
            switch kind {
            case .issue:
                let image = NSImageView()
                cell.imageView = image
                control = image
            case .number:
                let label = NSTextField(labelWithString: "")
                label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                label.textColor = .secondaryLabelColor
                cell.textField = label
                cell.fillsWidth = true
                control = label
            case .name, .frequency:
                let field = NSTextField(string: "")
                field.isBordered = false
                field.drawsBackground = false
                field.isEditable = true
                field.lineBreakMode = .byTruncatingTail
                field.cell?.usesSingleLineMode = true
                field.delegate = self
                if kind == .frequency { field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
                cell.textField = field
                cell.fillsWidth = true
                control = field
            case .modulation, .delay:
                let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
                popUp.isBordered = false
                popUp.addItems(withTitles: kind == .modulation ? Modulation.allCases.map(\.displayName) : Delay.allCases.map(\.displayName))
                popUp.target = self
                popUp.action = kind == .modulation ? #selector(modulationChosen(_:)) : #selector(delayChosen(_:))
                control = popUp
            case .tone:
                let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
                popUp.isBordered = false
                popUp.addItem(withTitle: "")
                popUp.menu?.delegate = cell
                control = popUp
            case .lockout, .priority:
                let box = NSButton(checkboxWithTitle: "", target: self, action: kind == .lockout ? #selector(lockoutClicked(_:)) : #selector(priorityClicked(_:)))
                box.toolTip = kind == .lockout ? "Skip this channel when scanning" : "Priority channel (one per bank)"
                control = box
            }
            cell.control = control
            cell.addSubview(control)
            return cell
        }

        private func configure(_ cell: ChannelCell, _ kind: ChannelColumn, _ row: ChannelRow) {
            let channel = row.channel
            let number = row.number
            cell.number = number
            let unused = channel.isEmpty
            switch kind {
            case .issue:
                let worst = row.issues.map(\.severity).max()
                cell.imageView?.image = worst.map { NSImage(systemSymbolName: $0 == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                                                            accessibilityDescription: $0 == .error ? "Error" : "Warning") } ?? nil
                cell.imageView?.contentTintColor = worst == .error ? .systemRed : .systemOrange
                cell.toolTip = worst == nil ? nil : row.issues.map(\.message).joined(separator: "\n")
            case .number:
                cell.textField?.stringValue = "\(number)"
            case .name:
                guard let field = cell.textField else { return }
                if field.currentEditor() == nil { field.stringValue = channel.name }
                field.placeholderString = unused ? "" : "No name"
                field.isEnabled = !unused
                field.setAccessibilityLabel("Channel \(number) name")
            case .frequency:
                guard let field = cell.textField else { return }
                if field.currentEditor() == nil { field.stringValue = channel.frequency?.megahertzString ?? "" }
                field.placeholderString = unused ? "Add…" : "MHz"
                field.setAccessibilityLabel("Channel \(number) frequency in megahertz")
            case .modulation:
                guard let popUp = cell.control as? NSPopUpButton else { return }
                popUp.isHidden = unused
                popUp.selectItem(at: Modulation.allCases.firstIndex(of: channel.modulation) ?? 0)
                popUp.setAccessibilityLabel("Channel \(number) modulation")
            case .tone:
                guard let popUp = cell.control as? NSPopUpButton else { return }
                popUp.isHidden = unused
                popUp.item(at: 0)?.title = channel.tone.displayName
                popUp.setAccessibilityLabel("Channel \(number) tone")
            case .delay:
                guard let popUp = cell.control as? NSPopUpButton else { return }
                popUp.isHidden = unused
                popUp.selectItem(at: Delay.allCases.firstIndex(of: channel.delay) ?? 0)
                popUp.setAccessibilityLabel("Channel \(number) delay")
            case .lockout:
                guard let box = cell.control as? NSButton else { return }
                box.isHidden = unused
                box.state = channel.lockedOut ? .on : .off
                box.setAccessibilityLabel("Channel \(number) locked out")
            case .priority:
                guard let box = cell.control as? NSButton else { return }
                box.isHidden = unused
                box.state = channel.priority ? .on : .off
                box.setAccessibilityLabel("Channel \(number) priority")
            }
            cell.needsLayout = true
        }

        // MARK: Editing

        /// Applies `change` to `numbers` as one undo step. Does nothing if nothing changed, so
        /// re-choosing the current value doesn't add an undo step.
        func edit(_ numbers: some Sequence<Int>, _ change: (inout Channel) -> Void) {
            var updated = config
            updated.editChannels(numbers, change)
            if updated != config { parent.config = updated }
        }

        private func number(of sender: Any?) -> Int? {
            ((sender as? NSView)?.superview as? ChannelCell)?.number
        }

        @objc private func modulationChosen(_ sender: NSPopUpButton) {
            guard let number = number(of: sender), Modulation.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
            let modulation = Modulation.allCases[sender.indexOfSelectedItem]
            edit([number]) { $0.modulation = modulation }
        }

        @objc private func delayChosen(_ sender: NSPopUpButton) {
            guard let number = number(of: sender), Delay.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
            let delay = Delay.allCases[sender.indexOfSelectedItem]
            edit([number]) { $0.delay = delay }
        }

        @objc private func lockoutClicked(_ sender: NSButton) {
            guard let number = number(of: sender) else { return }
            let on = sender.state == .on
            edit([number]) { $0.lockedOut = on }
        }

        @objc private func priorityClicked(_ sender: NSButton) {
            guard let number = number(of: sender) else { return }
            let on = sender.state == .on
            edit([number]) { $0.priority = on }
        }

        /// Commits a name or frequency when editing ends (Return, Tab, or clicking elsewhere), so
        /// typing is one undo step. A frequency that doesn't parse beeps and is put back.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let cell = field.superview as? ChannelCell,
                  let kind = cell.identifier.flatMap({ ChannelColumn(rawValue: $0.rawValue) }) else { return }
            let number = cell.number
            let channel = config[channel: number]
            let text = field.stringValue
            switch kind {
            case .name:
                if text != channel.name { edit([number]) { $0.name = text } }
            case .frequency:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if !channel.isEmpty { parent.config.setFrequency(nil, ofChannel: number) }
                } else if let frequency = Frequency(parsing: trimmed) {
                    if frequency != channel.frequency { parent.config.setFrequency(frequency, ofChannel: number) }
                    else { field.stringValue = frequency.megahertzString }
                } else {
                    NSSound.beep()
                    field.stringValue = channel.frequency?.megahertzString ?? ""
                }
            default:
                break
            }
        }

        /// Escape puts the field back as it was.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let cell = control.superview as? ChannelCell,
                  let kind = cell.identifier.flatMap({ ChannelColumn(rawValue: $0.rawValue) }) else { return false }
            let channel = config[channel: cell.number]
            textView.string = kind == .name ? channel.name : channel.frequency?.megahertzString ?? ""
            control.window?.makeFirstResponder(table)
            return true
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let numbers = table.selectedRowIndexes.contains(table.clickedRow)
                ? table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].number : nil }
                : [rows[table.clickedRow].number]
            menuNumbers = numbers.sorted()
            let used = menuNumbers.filter { !config[channel: $0].isEmpty }

            menu.addItem(item("Copy", #selector(menuCopy(_:))))
            menu.addItem(item(numbers.count == 1 ? "Clear Channel" : "Clear \(numbers.count) Channels", #selector(menuClear(_:))))
            guard !used.isEmpty else { return }
            menu.addItem(.separator())
            menu.addItem(submenu("Modulation", Modulation.allCases.enumerated().map { index, modulation in
                item(modulation.displayName, #selector(menuModulation(_:)), tag: index)
            }))
            menu.addItem(submenu("Tone", ToneMenu.items(target: self, action: #selector(menuTone(_:)))))
            menu.addItem(submenu("Delay", Delay.allCases.enumerated().map { index, delay in
                item(delay.displayName, #selector(menuDelay(_:)), tag: index)
            }))
            menu.addItem(.separator())
            menu.addItem(item("Lock Out", #selector(menuLockOut(_:))))
            menu.addItem(item("Unlock", #selector(menuUnlock(_:))))
            if used.count == 1 {
                menu.addItem(item(config[channel: used[0]].priority ? "Remove Priority" : "Make Priority Channel", #selector(menuPriority(_:))))
            }
        }

        private func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            return item
        }

        private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            menu.items = items
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = menu
            return parent
        }

        /// Bulk edits skip empty channels.
        private var menuUsed: [Int] { menuNumbers.filter { !config[channel: $0].isEmpty } }

        @objc private func menuCopy(_ sender: NSMenuItem) { copy(menuNumbers) }
        @objc private func menuClear(_ sender: NSMenuItem) { clear(menuNumbers) }
        @objc private func menuModulation(_ sender: NSMenuItem) {
            let modulation = Modulation.allCases[sender.tag]
            edit(menuUsed) { $0.modulation = modulation }
        }
        @objc private func menuTone(_ sender: NSMenuItem) {
            guard let tone = ToneMenu.tone(from: sender) else { return }
            edit(menuUsed) { $0.tone = tone }
        }
        @objc private func menuDelay(_ sender: NSMenuItem) {
            let delay = Delay.allCases[sender.tag]
            edit(menuUsed) { $0.delay = delay }
        }
        @objc private func menuLockOut(_ sender: NSMenuItem) { edit(menuUsed) { $0.lockedOut = true } }
        @objc private func menuUnlock(_ sender: NSMenuItem) { edit(menuUsed) { $0.lockedOut = false } }
        @objc private func menuPriority(_ sender: NSMenuItem) { edit(menuUsed) { $0.priority.toggle() } }

        // MARK: Pasteboard

        private var selectedNumbers: [Int] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].number : nil }.sorted()
        }

        func copySelection() { copy(selectedNumbers) }

        func clearSelection() { clear(selectedNumbers) }

        private func copy(_ numbers: [Int]) {
            guard !numbers.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ChannelClipboard.text(for: numbers.map { config[channel: $0] }), forType: .string)
        }

        private func clear(_ numbers: [Int]) {
            guard !numbers.isEmpty else { return }
            edit(numbers) { $0 = .empty }
        }

        /// Pastes into consecutive channels starting at the first selected one (or the first
        /// channel in view), stopping at channel 500.
        func paste() {
            guard let text = NSPasteboard.general.string(forType: .string),
                  let channels = ChannelClipboard.channels(from: text) else {
                NSSound.beep()
                return
            }
            let start = selectedNumbers.first ?? parent.pasteStart
            let targets = Array(start..<min(start + channels.count, ScannerConfig.channelCount + 1))
            var updated = config
            for (number, channel) in zip(targets, channels) { updated[channel: number] = channel }
            parent.config = updated
            parent.selection = Set(targets)
            if targets.count < channels.count { NSSound.beep() }
        }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let drag = ChannelDrag(number: rows[row].number, channel: rows[row].channel, source: parent.window)
            guard let data = try? JSONEncoder().encode(drag) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: .channelDrag)
            return item
        }

        private func drags(from info: any NSDraggingInfo) -> [ChannelDrag] {
            let decoder = JSONDecoder()
            return (info.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
                item.data(forType: .channelDrag).flatMap { try? decoder.decode(ChannelDrag.self, from: $0) }
            }
        }

        /// Drops land on a row (dropping between rows targets the row below).
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard row < rows.count else { return [] }
            let items = drags(from: info)
            guard !items.isEmpty else { return [] }
            if dropOperation == .above { tableView.setDropRow(row, dropOperation: .on) }
            return items.allSatisfy { $0.source == parent.window } ? .move : .copy
        }

        /// See `ScannerConfig.drop`. One undo step.
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard row < rows.count else { return false }
            let items = drags(from: info)
            guard !items.isEmpty else { return false }
            var updated = config
            let placed = updated.drop(items, at: rows[row].number, window: parent.window)
            parent.config = updated
            parent.selection = Set(placed)
            if placed.count < items.count { NSSound.beep() }
            return true
        }
    }
}
