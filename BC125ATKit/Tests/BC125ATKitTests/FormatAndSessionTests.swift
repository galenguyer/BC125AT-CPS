@testable import BC125ATKit
import Foundation
import Testing

/// A configuration with something non-default in every section.
func sampleConfig() -> ScannerConfig {
    var config = ScannerConfig()
    config[channel: 1] = Channel(name: "Air Guard", frequency: Frequency(parsing: "121.5"), modulation: .am)
    config[channel: 2] = Channel(name: "NOAA \"1\", main", frequency: Frequency(parsing: "162.55"), modulation: .fm, tone: .noTone, priority: true)
    config[channel: 75] = Channel(name: "", frequency: Frequency(parsing: "462.5625"), modulation: .nfm, tone: .dcs(index: 5), delay: .minus5, lockedOut: true)
    config[channel: 500] = Channel(name: "Last", frequency: Frequency(parsing: "406.0125"), tone: .ctcss(index: 12), delay: .zero)
    config.bankScanEnabled[2] = false
    config.bankNames[0] = "Aviation"
    config.settings.backlight = .keypressAndSquelch
    config.settings.keyBeep = .off
    config.settings.contrast = 11
    config.settings.priorityMode = .doNotDisturb
    config.settings.volume = 3
    config.search.delay = .minus10
    config.search.codeSearch = true
    config.search.serviceGroupsEnabled[4] = false
    config.search.customRanges[9].enabled = false
    config.search.customRanges[0].upper = Frequency(parsing: "26")!
    config.closeCall.mode = .priority
    config.closeCall.bandsEnabled = [false, true, false, true, false]
    config.globalLockouts = [Frequency(parsing: "155.1")!, Frequency(parsing: "460.025")!]
    return config
}

@Suite struct NativeFormatTests {
    @Test func roundTrips() throws {
        var config = sampleConfig()
        config.metadata = .init(model: "BC125AT", firmware: "Version 1.06.06", readAt: Date(timeIntervalSince1970: 1_791_810_000), notes: "Test")
        let data = try NativeFormat.encode(config)
        #expect(try NativeFormat.decode(data) == config)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""format" : "net.k9fgt.bc125at.config""#))
        #expect(text.contains(#""frequency" : "162.5500""#))
        #expect(text.contains(#""tone" : "D036""#))
        #expect(!text.contains(#""channel" : 3,"#), "empty channels aren't stored")
    }

    /// The app's older backups have no band plan; they were all saved from a scanner on USA.
    @Test func readsFilesWithoutABandPlanAsUSA() throws {
        var config = sampleConfig()
        config.settings.bandPlan = .canada
        let text = String(decoding: try NativeFormat.encode(config), as: UTF8.self)
        #expect(text.contains(#""bandPlan" : 1"#))
        let older = text.replacingOccurrences(of: #""bandPlan" : 1,"#, with: "")
        #expect(try NativeFormat.decode(Data(older.utf8)).settings.bandPlan == .usa)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: NativeFormat.ReadError.notABC125ATFile) { try NativeFormat.decode(Data("{}".utf8)) }
        #expect(throws: NativeFormat.ReadError.notABC125ATFile) { try NativeFormat.decode(Data("not json".utf8)) }
        let newer = #"{"format":"net.k9fgt.bc125at.config","version":99}"#
        #expect(throws: NativeFormat.ReadError.newerVersion(99)) { try NativeFormat.decode(Data(newer.utf8)) }
    }

    @Test func reportsWhereAFileIsDamaged() throws {
        var text = String(decoding: try NativeFormat.encode(sampleConfig()), as: UTF8.self)
        text = text.replacingOccurrences(of: #""162.5500""#, with: #""lots""#)
        #expect {
            try NativeFormat.decode(Data(text.utf8))
        } throws: { error in
            guard case .invalid(let reason) = error as? NativeFormat.ReadError else { return false }
            return reason.contains("lots") && reason.contains("channels")
        }
    }
}

@Suite struct CSVFormatTests {
    @Test func roundTripsChannels() throws {
        let config = sampleConfig()
        let csv = CSVFormat.export(config)
        #expect(csv.hasPrefix("Channel,Bank,Name,Frequency,Modulation,Tone,Delay,Lockout,Priority\r\n1,1,Air Guard,121.5000,AM,CSQ,2,No,No\r\n"))
        #expect(csv.contains(#"2,1,"NOAA ""1"", main",162.5500,FM,No Tone,2,No,Yes"#))
        let imported = try CSVFormat.importChannels(from: csv)
        #expect(imported.problems.isEmpty)
        #expect(imported.channels.map(\.number) == [1, 2, 75, 500])
        for (number, channel) in imported.channels { #expect(channel == config[channel: number]) }
    }

    @Test func importsBc125pyExport() throws {
        let csv = """
            Index,Name,Frequency (MHz),Modulation,CTCSS,Delay (sec),Lockout,Priority
            1,AAR HOTD,452.9375,nfm,none,2,unlocked,off
            2,Pri,162.4000,fm,ctcss_100.0,-5,locked,on
            3,,000.0000,auto,none,2,unlocked,off
            4,Bad,999.0,fm,none,2,unlocked,off
            """
        let imported = try CSVFormat.importChannels(from: csv)
        #expect(imported.channels.count == 4)
        #expect(imported.channels[0].channel == Channel(name: "AAR HOTD", frequency: Frequency(parsing: "452.9375"), modulation: .nfm))
        #expect(imported.channels[1].channel.tone == .ctcss(index: 12))
        #expect(imported.channels[1].channel.lockedOut && imported.channels[1].channel.priority)
        #expect(imported.channels[2].channel == .empty)
        // Out-of-range frequencies import, then fail validation.
        #expect(imported.channels[3].channel.validate().contains { $0.severity == .error })
    }

    @Test func reportsBadRows() throws {
        let csv = "Channel,Frequency,Tone\n1,162.55,banana\n600,162.55,none\n2,162.55,none\n"
        let imported = try CSVFormat.importChannels(from: csv)
        #expect(imported.channels.map(\.number) == [2])
        #expect(imported.problems.map(\.line) == [2, 3])
        #expect(throws: CSVFormat.ImportError.missingColumns(["Frequency"])) { try CSVFormat.importChannels(from: "Channel,Name\n1,A\n") }
    }
}

@Suite struct ScannerSessionTests {
    @Test func readsEverything() async throws {
        let original = sampleConfig()
        let mock = MockScanner(config: original)
        let session = ScannerSession(transport: mock)
        let progress = ProgressLog()
        let read = try await session.readConfiguration { progress.record($0) }

        var expected = original
        expected.bankNames = ScannerConfig().bankNames // app-only; not on the scanner
        expected.metadata = read.metadata
        #expect(read == expected)
        #expect(read.metadata.model == "BC125AT")
        #expect(read.metadata.firmware == "Version 1.06.06")
        #expect(progress.last?.completed == progress.last?.total)
        #expect(mock.received.last == "EPG")
        #expect(!mock.inProgramMode)
    }

    @Test func readsAndWritesTheBandPlan() async throws {
        var canada = ScannerConfig()
        canada.settings.bandPlan = .canada
        let mock = MockScanner(config: canada)
        let session = ScannerSession(transport: mock)
        #expect(try await session.readConfiguration().settings.bandPlan == .canada)

        var document = sampleConfig()
        document.settings.bandPlan = .usa
        let plan = WritePlan(from: canada, to: document)
        // First, since it changes how the scanner stores channel frequencies.
        #expect(plan.steps.first?.command == "BPL,0")
        #expect(plan.steps.first?.detail == "Canada → USA")
        let report = try await session.write(plan)
        #expect(report.succeeded)
        #expect(mock.config.settings.bandPlan == .usa)
    }

    /// A scanner left in Close Call Only mode reports `CLC,3`, which must not stop a read.
    @Test func readsCloseCallOnlyAndScanHits() async throws {
        var config = ScannerConfig()
        config.closeCall.mode = .closeCallOnly
        config.closeCall.scanHits = true
        let read = try await ScannerSession(transport: MockScanner(config: config)).readConfiguration()
        #expect(read.closeCall == config.closeCall)
        let text = String(decoding: try NativeFormat.encode(read), as: UTF8.self)
        #expect(text.contains(#""lockOutHits" : true"#), "saved under its old key")
        #expect(try NativeFormat.decode(Data(text.utf8)).closeCall.scanHits)
    }

    @Test func programModeRefused() async {
        let mock = MockScanner()
        mock.refusesProgramMode = true
        let session = ScannerSession(transport: mock)
        await #expect(throws: SessionError.programModeRefused) { try await session.readConfiguration() }
    }

    @Test func leavesProgramModeAfterTimeout() async {
        let mock = MockScanner()
        mock.unresponsiveCommands = ["CSP"]
        let session = ScannerSession(transport: mock)
        await #expect(throws: ScannerError.transport(.timedOut)) { try await session.readConfiguration() }
        #expect(mock.received.last == "EPG")
        #expect(!mock.inProgramMode)
    }

    @Test func leavesProgramModeWhenCancelled() async {
        let mock = MockScanner()
        let session = ScannerSession(transport: mock)
        let task = Task {
            try await session.readConfiguration { progress in
                if progress.completed == 100 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(mock.received.last == "EPG")
        #expect(!mock.inProgramMode)
    }

    @Test func rejectsOtherModels() async {
        let mock = MockScanner()
        mock.model = "BCD996P2"
        let session = ScannerSession(transport: mock)
        await #expect(throws: SessionError.unsupportedModel("BCD996P2")) { try await session.readConfiguration() }
        #expect(!mock.received.contains("PRG"))
    }
}

@Suite struct MockScannerTests {
    @Test func reproducesMeasuredBehaviour() throws {
        let mock = MockScanner()
        let connection = ScannerConnection(transport: mock)
        #expect(try connection.send("BLT") == "BLT,NG")
        try connection.enterProgramMode()
        try connection.execute("CIN,1,A,1625510,FM,0,2,0,1")
        #expect(try connection.send("CIN,1") == "CIN,1,A,01625475,FM,0,2,0,1")
        try connection.execute("CIN,2,B,1625500,FM,0,2,0,1")
        #expect(mock.config[channel: 1].priority == false)
        try connection.execute("CIN,2,,1624000,,,,,")
        #expect(mock.config[channel: 2].name == "B")
        try connection.execute("CNT,20")
        #expect(try connection.send("CNT") == "CNT,8")
        for n in 0..<101 { try connection.execute("LOF,\(4_500_000 + n * 125)") }
        #expect(mock.config.globalLockouts.count == 100)
        #expect(try connection.send("ZZZ") == "ERR")
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ReadProgress] = []

    func record(_ progress: ReadProgress) { lock.withLock { entries.append(progress) } }
    var last: ReadProgress? { lock.withLock { entries.last } }
}
