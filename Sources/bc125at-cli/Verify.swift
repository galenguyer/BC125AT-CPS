import BC125ATKit
import Foundation

enum Dump {
    static let settingsCommands = ["BLT", "BSV", "KBP", "PRI", "SCG", "SCO", "CLC", "SSG", "CSG", "WXS", "CNT", "VOL", "SQL"]
    static let commands = ["MDL", "VER"] + settingsCommands
        + (1...10).map { "CSP,\($0)" } + (1...500).map { "CIN,\($0)" }
}

/// A `CIN` reply split per SPEC.md §3.1: index from the left, the six fixed fields from the
/// right, and whatever is left in between is the name (so a comma in a name can't shift fields).
struct RawChannel: Equatable {
    var index: Int
    var name: String
    var frequency: String
    var modulation: String
    var tone: String
    var delay: String
    var lockout: String
    var priority: String

    init?(reply: String) {
        let fields = reply.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 9, fields[0] == "CIN", let index = Int(fields[1]) else { return nil }
        let tail = Array(fields.suffix(6))
        self.index = index
        name = fields[2..<(fields.count - 6)].joined(separator: ",")
        (frequency, modulation, tone, delay, lockout, priority) = (tail[0], tail[1], tail[2], tail[3], tail[4], tail[5])
    }

    var isEmpty: Bool { Int(frequency) == 0 }
}

/// Runs the Phase 0 checks from SPEC.md §10 and renders a Markdown report.
final class Verifier {
    enum Verdict: String {
        case confirmed = "✅ matches spec"
        case differs = "⚠️ differs"
        case observed = "ℹ️ observed"
        case inconclusive = "❔ inconclusive"
        case failed = "❌ failed"
    }

    struct Finding {
        var section: String
        var item: String
        var verdict: Verdict
        var detail: String
    }

    private let connection: ScannerConnection
    private let allowWrite: Bool
    private var findings: [Finding] = []
    private var restoreProblems: [String] = []

    init(connection: ScannerConnection, allowWrite: Bool) {
        self.connection = connection
        self.allowWrite = allowWrite
    }

    func run() throws -> String {
        try checkOutsideProgramMode()
        try connection.inProgramMode {
            try checkInsideProgramMode()
            if allowWrite { try runWriteTests() }
        }
        try check("§3", "VOL/SQL after EPG") {
            let vol = try raw("VOL"), sql = try raw("SQL")
            let ok = vol.hasPrefix("VOL,") && sql.hasPrefix("SQL,")
            return (ok ? .confirmed : .differs, "`\(vol)`, `\(sql)`")
        }
        return report()
    }

    // MARK: Read-only checks

    private var channels: [RawChannel] = []
    private var lockouts: [String] = []

    private func checkOutsideProgramMode() throws {
        try check("§3", "MDL / VER") {
            let mdl = try raw("MDL"), ver = try raw("VER")
            return (mdl == "MDL,BC125AT" ? .confirmed : .differs, "`\(mdl)`, `\(ver)`")
        }
        try check("§3", "Program-mode command outside program mode") {
            let reply = try raw("BLT")
            return (reply.hasSuffix("NG") ? .confirmed : .differs, "`BLT` → `\(reply)` (spec: NG)")
        }
        try check("§3", "Unknown command") {
            let reply = try raw("ZZZ")
            return (reply.hasSuffix("ERR") ? .confirmed : .differs, "`ZZZ` → `\(reply)` (spec: ERR)")
        }
        try check("§3", "VOL/SQL outside program mode") {
            let vol = try raw("VOL"), sql = try raw("SQL")
            let ok = vol.hasPrefix("VOL,") && sql.hasPrefix("SQL,")
            return (ok ? .confirmed : .differs, "`\(vol)`, `\(sql)`")
        }
    }

    private func checkInsideProgramMode() throws {
        try check("§3", "PRG while already in program mode") {
            (.observed, "`\(try raw("PRG"))`")
        }
        try check("§3", "Out-of-range channel index") {
            let reply = try raw("CIN,501")
            return (reply.hasSuffix("ERR") ? .confirmed : .differs, "`CIN,501` → `\(reply)`")
        }

        var settings: [String: String] = [:]
        for command in Dump.settingsCommands { settings[command] = try raw(command) }
        try check("§3", "Get replies for all settings") {
            let malformed = settings.filter { !$0.value.hasPrefix($0.key + ",") }
            let lines = Dump.settingsCommands.map { "`\(settings[$0]!)`" }.joined(separator: ", ")
            return (malformed.isEmpty ? .confirmed : .differs, lines)
        }
        try check("§3", "Trailing comma on BLT") {
            let reply = settings["BLT"]!
            return (reply.hasSuffix(",") ? .confirmed : .differs, "`\(reply)`")
        }

        var ranges: [String] = []
        for index in 1...10 { ranges.append(try raw("CSP,\(index)")) }
        try check("§3", "Trailing comma on CSP") {
            (ranges.allSatisfy { $0.hasSuffix(",") } ? .confirmed : .differs, "`\(ranges[0])`")
        }
        try check("§3.6", "Custom search ranges vs bc125py defaults") {
            let defaults = [(250000, 279950), (280000, 296950), (297000, 499950), (500000, 540000), (1080000, 1369916),
                            (1370000, 1439950), (1440000, 1479950), (2250000, 3800000), (4000000, 4499937), (4500000, 4699937)]
            let actual = ranges.map { reply -> (Int, Int) in
                let f = reply.split(separator: ",", omittingEmptySubsequences: false)
                return f.count >= 4 ? (Int(f[2]) ?? -1, Int(f[3]) ?? -1) : (-1, -1)
            }
            let same = zip(defaults, actual).allSatisfy { $0 == $1 }
            return (same ? .confirmed : .observed,
                    same ? "all 10 equal bc125py's defaults" : ranges.map { "`\($0)`" }.joined(separator: ", "))
        }

        let start = ContinuousClock.now
        for index in 1...500 {
            let reply = try raw("CIN,\(index)")
            guard let channel = RawChannel(reply: reply) else {
                record("§3.1", "CIN,\(index) parse", .failed, "`\(reply)`")
                continue
            }
            channels.append(channel)
        }
        let elapsed = ContinuousClock.now - start
        let used = channels.filter { !$0.isEmpty }
        try check("§7", "Reading 500 channels") {
            (.observed, "\(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))); \(used.count) channels in use")
        }
        try check("§3.1", "Frequency padding in replies") {
            let samples = (used.prefix(3) + channels.filter(\.isEmpty).prefix(1)).map { "`CIN,\($0.index),…,\($0.frequency),…`" }
            let widths = Set(used.map(\.frequency.count))
            let padded = used.contains { $0.frequency.hasPrefix("0") }
            return (.observed, "\(padded ? "zero-padded" : "not padded"); widths \(widths.sorted()); \(samples.joined(separator: ", "))")
        }
        try check("§3.1", "Empty channel reply") {
            guard let empty = channels.first(where: \.isEmpty) else { return (.inconclusive, "no empty channels") }
            let reply = "CIN,\(empty.index),\(empty.name),\(empty.frequency),\(empty.modulation),\(empty.tone),\(empty.delay),\(empty.lockout),\(empty.priority)"
            return (.observed, "`\(reply)` (name \(empty.name.debugDescription))")
        }
        try check("§3.1", "Names with commas / characters in use") {
            let withCommas = used.filter { $0.name.contains(",") }
            let characters = String(Set(used.flatMap(\.name)).sorted())
            return (withCommas.isEmpty ? .observed : .differs,
                    "\(withCommas.count) names contain commas; characters used: `\(characters)`")
        }
        try check("§3.1", "Banks with more than one priority channel") {
            let banks = Dictionary(grouping: used.filter { $0.priority == "1" }) { ($0.index - 1) / 50 + 1 }
            let multiple = banks.filter { $0.value.count > 1 }.keys.sorted()
            return (.observed, multiple.isEmpty ? "none in current data" : "banks \(multiple)")
        }
        try check("§3.2", "Tone codes in use are in the spec table") {
            let valid = Set([0, 127, 240] + Array(64...113) + Array(128...231))
            let bad = used.filter { !valid.contains(Int($0.tone) ?? -1) }
            return (bad.isEmpty ? .confirmed : .differs, bad.isEmpty ? "all valid" : bad.map { "CIN \($0.index): \($0.tone)" }.joined(separator: ", "))
        }

        try checkLockoutCursor()
    }

    private func walkLockouts() throws -> [String] {
        var found: [String] = []
        while found.count < 2000 {
            let reply = try raw("GLF")
            guard reply.hasPrefix("GLF,"), reply != "GLF,-1" else { break }
            found.append(String(reply.dropFirst(4)))
        }
        return found
    }

    private func checkLockoutCursor() throws {
        lockouts = try walkLockouts()
        let afterEnd = try raw("GLF")
        try check("§3.3", "GLF walk") {
            (.observed, "\(lockouts.count) lockouts \(lockouts.prefix(5).map { "`\($0)`" }.joined(separator: ", ")); GLF after -1 → `\(afterEnd)`")
        }
        guard !lockouts.isEmpty else {
            record("§3.3", "GLF,0 resets the cursor", .inconclusive, "lockout list is empty; run with --allow-write to test with a temporary lockout")
            return
        }
        try checkCursorReset(expectedFirst: lockouts[0])
    }

    private func checkCursorReset(expectedFirst: String) throws {
        try check("§3.3", "GLF,0 resets the cursor") {
            let reset = try raw("GLF,0")
            let next = try raw("GLF")
            let worked = next == "GLF,\(expectedFirst)"
            _ = try walkLockouts()
            return (worked ? .confirmed : .differs, "`GLF,0` → `\(reset)`, then `GLF` → `\(next)` (first is `\(expectedFirst)`)")
        }
        try check("§3.3", "EPG+PRG resets the cursor (bc125py)") {
            _ = try raw("EPG"); _ = try raw("PRG")
            let next = try raw("GLF")
            _ = try walkLockouts()
            return (next == "GLF,\(expectedFirst)" ? .confirmed : .differs, "then `GLF` → `\(next)`")
        }
    }

    // MARK: Write tests (each restores what it changed)

    private func runWriteTests() throws {
        let empties = channels.filter(\.isEmpty)
        let byBank = Dictionary(grouping: empties) { ($0.index - 1) / 50 + 1 }
        guard let bank = byBank.keys.sorted(by: >).first(where: { byBank[$0]!.count >= 2 }) else {
            record("Writes", "Spare channels", .inconclusive, "no bank has two empty channels; write tests skipped")
            return
        }
        let spares = byBank[bank]!.sorted { $0.index > $1.index }
        let a = spares[0], b = spares[1]
        record("Writes", "Spare channels", .observed, "using empty channels \(a.index) and \(b.index) in bank \(bank)")
        defer { restoreEmpty(a); restoreEmpty(b) }

        try checkNames(on: a.index)
        try checkEmptyFieldsUnchanged(on: a.index)
        try checkFrequencies(on: a.index)
        try check("§3.1", "Two priority channels in one bank") {
            _ = try raw("CIN,\(a.index),PRI A,1625500,FM,0,2,0,1")
            _ = try raw("CIN,\(b.index),PRI B,1624000,FM,0,2,0,1")
            let pa = RawChannel(reply: try raw("CIN,\(a.index)"))?.priority
            let pb = RawChannel(reply: try raw("CIN,\(b.index)"))?.priority
            return (.observed, "after setting both: \(a.index) pri=\(pa ?? "?"), \(b.index) pri=\(pb ?? "?")")
        }
        try checkDeleteChannel(a)

        try checkMask("SCG", "§3.4", expectRejected: true)
        try checkMask("SSG", "§3.4", expectRejected: nil)
        try checkMask("CSG", "§3.4", expectRejected: nil)
        try checkContrastOutOfRange()
        if lockouts.isEmpty { try checkLockoutsWithTemporaryEntry() }
    }

    private func readName(_ index: Int) throws -> String {
        RawChannel(reply: try raw("CIN,\(index)"))?.name ?? "?"
    }

    private func checkNames(on index: Int) throws {
        let cases = ["PHASE0 TEST", "abcdefghijklmnop", "!@#$%^&*()-_=+/?", ".:;'\"<>[]{}|\\~`", "12345678901234567", "TRAIL  "]
        var results: [String] = []
        for name in cases {
            let reply = try raw("CIN,\(index),\(name),1625500,FM,0,2,0,0")
            results.append("\(name.debugDescription) → `\(reply)`, stored \(try readName(index).debugDescription)")
        }
        record("§3.1", "Name characters and length", .observed, results.joined(separator: "<br>"))

        try check("§3.1", "Clearing a name") {
            _ = try raw("CIN,\(index),CLEARME,1625500,FM,0,2,0,0")
            let emptyReply = try raw("CIN,\(index),,1625500,FM,0,2,0,0")
            let afterEmpty = try readName(index)
            let spaceReply = try raw("CIN,\(index), ,1625500,FM,0,2,0,0")
            let afterSpace = try readName(index)
            let ok = afterEmpty == "CLEARME" && afterSpace != "CLEARME"
            return (ok ? .confirmed : .differs,
                    "empty field → `\(emptyReply)`, name \(afterEmpty.debugDescription); single space → `\(spaceReply)`, name \(afterSpace.debugDescription)")
        }
    }

    private func checkEmptyFieldsUnchanged(on index: Int) throws {
        try check("§3", "Empty fields leave values unchanged") {
            _ = try raw("CIN,\(index),KEEPNAME,1625500,NFM,76,3,0,0")
            let reply = try raw("CIN,\(index),,1624000,,,,,")
            let after = RawChannel(reply: try raw("CIN,\(index)"))
            let ok = after?.name == "KEEPNAME" && Int(after?.frequency ?? "") == 1624000
                && after?.modulation == "NFM" && after?.tone == "76" && after?.delay == "3"
            return (ok ? .confirmed : .differs, "`CIN,\(index),,1624000,,,,,` → `\(reply)`; now \(after.map { "`\($0.name),\($0.frequency),\($0.modulation),\($0.tone),\($0.delay)`" } ?? "?")")
        }
    }

    private func checkFrequencies(on index: Int) throws {
        let cases: [(Int, String)] = [
            (250050, "25.0050 (5 kHz)"), (1625510, "162.5510 (off-step)"), (1625525, "162.5525 (2.5 kHz)"),
            (1540062, "154.0062 (≈6.25 kHz, rounded down)"), (1540063, "154.0063 (≈6.25 kHz, rounded up)"),
            (1180083, "118.0083 (8.33 kHz)"), (1180050, "118.0050 (5 kHz in air band)"),
            (4060125, "406.0125 (12.5 kHz)"), (4060050, "406.0050 (5 kHz in UHF)"),
            (5120000, "512.0000 (top edge)"), (5120100, "512.0100 (above range)"), (600000, "60.0000 (gap)"),
        ]
        var results: [String] = []
        for (value, label) in cases {
            let reply = try raw("CIN,\(index),FREQTEST,\(value),FM,0,2,0,0")
            let stored = RawChannel(reply: try raw("CIN,\(index)"))?.frequency ?? "?"
            results.append("\(label): `\(value)` → `\(reply)`, stored `\(stored)`")
            _ = try raw("CIN,\(index),FREQTEST,1625500,FM,0,2,0,0")
        }
        record("§3.5", "Frequency acceptance and rounding", .observed, results.joined(separator: "<br>"))
    }

    private func checkDeleteChannel(_ original: RawChannel) throws {
        try check("§3", "DCH clears a channel to the empty state") {
            _ = try raw("CIN,\(original.index),DELETEME,1625500,FM,0,2,0,0")
            let reply = try raw("DCH,\(original.index)")
            let after = RawChannel(reply: try raw("CIN,\(original.index)"))
            return (after == original ? .confirmed : .differs, "`DCH` → `\(reply)`; reads back identical to the original empty channel: \(after == original)")
        }
    }

    private func checkMask(_ command: String, _ section: String, expectRejected: Bool?) throws {
        let original = try raw(command)
        guard original.hasPrefix(command + ",") else {
            record(section, "\(command) all disabled", .failed, "could not read `\(command)`: `\(original)`")
            return
        }
        let mask = String(original.dropFirst(command.count + 1))
        defer { restoreSetting(command, to: mask) }
        let reply = try raw("\(command),1111111111")
        let after = try raw(command)
        let rejected = !reply.hasSuffix("OK")
        let verdict: Verdict = expectRejected.map { $0 == rejected ? .confirmed : .differs } ?? .observed
        record(section, "\(command) all disabled", verdict, "`\(command),1111111111` → `\(reply)`; reads back `\(after)`")
    }

    private func checkContrastOutOfRange() throws {
        let original = try raw("CNT")
        guard original.hasPrefix("CNT,") else { return }
        let value = String(original.dropFirst(4))
        defer { restoreSetting("CNT", to: value) }
        let reply = try raw("CNT,20")
        let after = try raw("CNT")
        let silentDefault = reply.hasSuffix("OK") && after != "CNT,20"
        record("§3", "CNT out of range", silentDefault ? .confirmed : .differs, "`CNT,20` → `\(reply)`; reads back `\(after)` (was `\(original)`)")
    }

    private func checkLockoutsWithTemporaryEntry() throws {
        let frequency = 4069875
        let reply = try raw("LOF,\(frequency)")
        defer {
            _ = try? raw("ULF,\(frequency)")
            if (try? walkLockouts()).map({ !$0.isEmpty }) ?? true {
                restoreProblems.append("temporary lockout \(frequency) may still be set")
            }
        }
        _ = try raw("GLF,0")
        let listed = try walkLockouts()
        record("§3.3", "Temporary lockout", .observed, "`LOF,\(frequency)` → `\(reply)`; list now \(listed.map { "`\($0)`" })")
        if let first = listed.first { try checkCursorReset(expectedFirst: first) }
    }

    private func restoreEmpty(_ original: RawChannel) {
        _ = try? raw("DCH,\(original.index)")
        if (try? raw("CIN,\(original.index)")).flatMap(RawChannel.init) != original {
            restoreProblems.append("channel \(original.index) did not return to its original empty state")
        }
    }

    private func restoreSetting(_ command: String, to value: String) {
        _ = try? raw("\(command),\(value)")
        if (try? raw(command)) != "\(command),\(value)" {
            restoreProblems.append("\(command) may not be restored to `\(value)`")
        }
    }

    // MARK: Plumbing

    private func raw(_ line: String) throws -> String {
        try checkInterrupted()
        do {
            return try connection.send(line)
        } catch .transport(.timedOut) {
            return "(no reply)"
        }
    }

    private func check(_ section: String, _ item: String, _ body: () throws -> (Verdict, String)) throws {
        do {
            let (verdict, detail) = try body()
            record(section, item, verdict, detail)
        } catch let error as ScannerError {
            record(section, item, .failed, error.description)
        }
    }

    private func record(_ section: String, _ item: String, _ verdict: Verdict, _ detail: String) {
        findings.append(Finding(section: section, item: item, verdict: verdict, detail: detail))
        FileHandle.standardError.write(Data("\(verdict.rawValue)  \(item)\n".utf8))
    }

    private func report() -> String {
        var lines = [
            "# Phase 0 protocol verification",
            "",
            "Run \(Date.now.formatted(.iso8601)) · write tests: \(allowWrite ? "yes" : "no")",
            "",
        ]
        if allowWrite {
            lines.append(restoreProblems.isEmpty
                ? "**Restore:** everything changed was restored and read back."
                : "**Restore problems:** " + restoreProblems.joined(separator: "; "))
            lines.append("")
        }
        lines += ["| Spec | Item | Result | Detail |", "|---|---|---|---|"]
        for finding in findings {
            let detail = finding.detail.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(finding.section) | \(finding.item) | \(finding.verdict.rawValue) | \(detail) |")
        }
        return lines.joined(separator: "\n")
    }
}
