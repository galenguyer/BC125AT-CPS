@testable import BC125ATKit
import Foundation
import Testing

@Suite struct FrequencyTests {
    @Test(arguments: [
        ("162.55", 1_625_500), ("162.5500", 1_625_500), ("162.55 MHz", 1_625_500), ("162.55mhz", 1_625_500),
        ("162550k", 1_625_500), ("162550 kHz", 1_625_500), ("162550000 Hz", 1_625_500), ("162550", 1_625_500),
        ("154.00625", 1_540_062), ("406.00625", 4_060_062), (" 25 ", 250_000), (".5", 5_000), ("118.0083", 1_180_083),
    ])
    func parsesWhatPeopleType(text: String, hundredHz: UInt32) {
        #expect(Frequency(parsing: text)?.hundredHz == hundredHz)
    }

    @Test(arguments: ["", "abc", "1.2.3", "-5", ".", "162,55", "0"])
    func rejectsNonsense(text: String) {
        #expect(Frequency(parsing: text) == nil)
    }

    @Test func wireAndDisplay() {
        let f = Frequency(hundredHz: 1_625_500)
        #expect(f.wireValue == "01625500")
        #expect(f.megahertzString == "162.5500")
        #expect(Frequency(hundredHz: 250_050).megahertzString == "25.0050")
        #expect(Frequency(wire: "01625500") == f)
        #expect(Frequency(wire: "1625500") == f)
        #expect(Frequency(wire: "016255OO") == nil)
    }

    @Test func codableAsMegahertzString() throws {
        let data = try JSONEncoder().encode([Frequency(hundredHz: 4_060_062)])
        #expect(String(decoding: data, as: UTF8.self) == #"["406.0062"]"#)
        #expect(try JSONDecoder().decode([Frequency].self, from: data) == [Frequency(hundredHz: 4_060_062)])
    }
}

@Suite struct ToneCodeTests {
    @Test func everyCodeRoundTrips() {
        #expect(ToneCode.allCases.count == 3 + 50 + 104)
        for tone in ToneCode.allCases {
            #expect(ToneCode(code: tone.code) == tone)
            #expect(ToneCode(parsing: tone.displayName) == tone, "\(tone.displayName)")
        }
    }

    @Test func codeTableMatchesSpec() {
        #expect(ToneCode(code: 64)?.displayName == "CTCSS 67.0")
        #expect(ToneCode(code: 76)?.displayName == "CTCSS 100.0")
        #expect(ToneCode(code: 113)?.displayName == "CTCSS 254.1")
        #expect(ToneCode(code: 128)?.displayName == "DCS 023")
        #expect(ToneCode(code: 231)?.displayName == "DCS 754")
        for invalid in [1, 63, 114, 126, 232, 239, 241] { #expect(ToneCode(code: invalid) == nil) }
    }

    @Test(arguments: [
        ("100.0", 76), ("100", 76), ("ctcss_100.0", 76), ("CTCSS 100.0 Hz", 76), ("D023", 128), ("dcs_23", 128),
        ("023N", 128), ("none", 0), ("CSQ", 0), ("No Tone", 240), ("search", 127),
    ])
    func parsesShorthand(text: String, code: Int) {
        #expect(ToneCode(parsing: text)?.code == code)
    }
}

@Suite struct BandPlanTests {
    /// Every value measured on a real scanner in Phase 0 (SPEC.md §3.5).
    @Test func predictsEveryMeasuredValue() throws {
        let url = try #require(Bundle.module.url(forResource: "step-measurements", withExtension: "csv", subdirectory: "Fixtures"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }.dropFirst()
        var failures: [String] = []
        for line in lines {
            let parts = line.split(separator: ",")
            let sent = Frequency(hundredHz: UInt32(parts[0])!)
            let expected = parts[1] == "ERR" ? nil : Frequency(hundredHz: UInt32(parts[1])!)
            let predicted = BandPlan.bc125at.storedValue(for: sent)
            if predicted != expected { failures.append("\(sent) → expected \(expected?.description ?? "ERR"), predicted \(predicted?.description ?? "ERR")") }
        }
        #expect(lines.count > 19_000)
        #expect(failures.isEmpty, "\(failures.count) mismatches: \(failures.prefix(10))")
    }

    @Test func rangesAndExamples() {
        let plan = BandPlan.bc125at
        func stored(_ mhz: String) -> String? { plan.storedValue(for: Frequency(parsing: mhz)!)?.megahertzString }
        #expect(stored("162.5510") == "162.5475")
        #expect(stored("162.5050") == "162.5050") // exact 5 kHz kept in 137–174 MHz
        #expect(stored("118.0050") == "118.0083")
        #expect(stored("406.0050") == "406.0062")
        #expect(stored("173.2037") == "173.2037")
        #expect(stored("512") == "512.0000")
        #expect(stored("512.01") == nil)
        #expect(stored("60") == nil)
        #expect(stored("24.9995") == nil)
    }
}

@Suite struct WireTests {
    @Test func parsesChannel() throws {
        let (number, channel) = try Wire.channel(fromCIN: ["12", "NOAA 1", "01625500", "FM", "0", "2", "0", "1"])
        #expect(number == 12)
        #expect(channel == Channel(name: "NOAA 1", frequency: Frequency(hundredHz: 1_625_500), modulation: .fm, priority: true))
    }

    @Test func emptyChannelMatchesScanner() throws {
        let (_, channel) = try Wire.channel(fromCIN: ["27", "", "00000000", "AUTO", "0", "2", "1", "0"])
        #expect(channel == .empty)
        #expect(channel.isEmpty)
    }

    @Test func commaInNameDoesNotShiftFields() throws {
        let (_, channel) = try Wire.channel(fromCIN: ["1", "A", "B", "01625500", "NFM", "76", "-5", "0", "0"])
        #expect(channel.name == "A,B")
        #expect(channel.tone == .ctcss(index: 12))
        #expect(channel.delay == .minus5)
    }

    @Test func rejectsBadFields() {
        #expect(throws: Wire.FormatError.self) { try Wire.channel(fromCIN: ["1", "X", "01625500", "XM", "0", "2", "0", "0"]) }
        #expect(throws: Wire.FormatError.self) { try Wire.channel(fromCIN: ["1", "X", "01625500", "FM", "120", "2", "0", "0"]) }
    }

    @Test func writeCommands() {
        let channel = Channel(name: "", frequency: Frequency(hundredHz: 1_625_500), modulation: .nfm, tone: .dcs(index: 0), delay: .minus10)
        #expect(Wire.command(writing: channel, to: 7) == "CIN,7, ,01625500,NFM,128,-10,0,0")
        #expect(Wire.command(writing: .empty, to: 7) == "DCH,7")
    }

    @Test func masks() throws {
        #expect(try Wire.enabledFlags(fromInvertedMask: "1010000001", count: 10, command: "SCG")
            == [false, true, false, true, true, true, true, true, true, false])
        #expect(Wire.invertedMask([false, true]) == "10")
        #expect(throws: Wire.FormatError.self) { try Wire.enabledFlags(fromInvertedMask: "10", count: 10, command: "SCG") }
    }
}

@Suite struct ValidationTests {
    func config(_ edit: (inout ScannerConfig) -> Void) -> ScannerConfig {
        var config = ScannerConfig()
        edit(&config)
        return config
    }

    @Test func freshDocumentIsClean() {
        #expect(ScannerConfig().validate().isEmpty)
    }

    @Test func channelProblems() {
        let issues = config {
            $0[channel: 1] = Channel(name: "TWELVE34567890123", frequency: Frequency(parsing: "162.55"))
            $0[channel: 2] = Channel(name: "A,B", frequency: Frequency(parsing: "60"))
            $0[channel: 3] = Channel(name: "Café ", frequency: Frequency(parsing: "162.551"))
        }.validate()
        #expect(issues.contains { $0.location == .channel(1) && $0.severity == .error && $0.message.contains("17 characters") })
        #expect(issues.contains { $0.location == .channel(2) && $0.message.contains("commas") })
        #expect(issues.contains { $0.location == .channel(2) && $0.message.contains("outside") })
        #expect(issues.contains { $0.location == .channel(3) && $0.message.contains("ASCII") })
        #expect(issues.contains { $0.location == .channel(3) && $0.severity == .warning && $0.message.contains("162.5475") })
        #expect(issues.contains { $0.location == .channel(3) && $0.message.contains("Trailing") })
    }

    @Test func onePriorityChannelPerBank() {
        let issues = config {
            $0[channel: 51] = Channel(frequency: Frequency(parsing: "150"), priority: true)
            $0[channel: 60] = Channel(frequency: Frequency(parsing: "151"), priority: true)
            $0[channel: 1] = Channel(frequency: Frequency(parsing: "152"), priority: true)
        }.validate()
        #expect(issues.filter { $0.severity == .error }.map(\.location) == [.channel(51), .channel(60)])
    }

    @Test func settingsAndLimits() {
        let issues = config {
            $0.settings.contrast = 20
            $0.settings.batteryChargeHours = 0
            $0.bankScanEnabled = Array(repeating: false, count: 10)
            $0.search.customRanges[0].lower = Frequency(parsing: "60")!
            $0.globalLockouts = (0..<101).map { Frequency(hundredHz: 4_500_000 + UInt32($0) * 125) }
        }.validate()
        #expect(issues.contains { $0.location == .settings && $0.message.contains("Contrast") })
        #expect(issues.contains { $0.location == .settings && $0.message.contains("Battery") })
        #expect(issues.contains { $0.location == .bank(1) && $0.severity == .warning })
        #expect(issues.contains { $0.location == .search && $0.message.contains("range 1") })
        #expect(issues.contains { $0.location == .globalLockouts && $0.message.contains("101") })
    }
}

@Suite struct DuplicateFrequencyTests {
    @Test func warnsOnEveryCopyNamingTheOthers() {
        var config = ScannerConfig()
        config[channel: 1] = Channel(name: "GUARD", frequency: Frequency(parsing: "121.5"), modulation: .am)
        config[channel: 51] = Channel(name: "GUARD", frequency: Frequency(parsing: "121.5"), modulation: .am)
        config[channel: 101] = Channel(frequency: Frequency(parsing: "121.5"), modulation: .am)
        config[channel: 2] = Channel(name: "Other", frequency: Frequency(parsing: "118.3"), modulation: .am)
        let issues = config.validate()
        func messages(_ number: Int) -> [String] { issues.filter { $0.location == .channel(number) }.map(\.message) }
        #expect(messages(1) == ["121.5000 MHz is also on channel 51 “GUARD” and channel 101"])
        #expect(messages(51) == ["121.5000 MHz is also on channel 1 “GUARD” and channel 101"])
        #expect(messages(101) == ["121.5000 MHz is also on channel 1 “GUARD” and channel 51 “GUARD”"])
        #expect(messages(2).isEmpty)
        // Only warnings: writing is still allowed.
        #expect(!issues.contains { $0.severity == .error })
        // And they can be turned off.
        #expect(!config.validate(duplicateFrequencies: false).contains { $0.message.contains("is also on") })
    }

    @Test func comparesAsStoredOnTheScanner() {
        var config = ScannerConfig()
        config[channel: 1] = Channel(frequency: Frequency(parsing: "154.0062"))
        config[channel: 2] = Channel(frequency: Frequency(parsing: "154.0025"))
        #expect(config.validate().contains { $0.location == .channel(1) && $0.message == "154.0025 MHz is also on channel 2" })
    }

    @Test func listsAtMostFourOthers() {
        var config = ScannerConfig()
        for number in 1...7 { config[channel: number] = Channel(frequency: Frequency(parsing: "162.55")) }
        #expect(config.validate().contains { $0.location == .channel(1)
            && $0.message == "162.5500 MHz is also on channel 2, channel 3, channel 4, channel 5 and 2 more" })
    }
}
