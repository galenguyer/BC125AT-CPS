@testable import BC125ATKit
import Foundation
import Testing

/// Uniden's `.bc125at_ss` format. The layout and values below copy files written by Uniden's
/// software, with made-up channels.
@Suite struct UnidenFormatTests {
    static let sample = [
        "Misc\tK+S\tOff\tOff\t8\t14\t1\t4\tCanada",
        "Priority\tPlus",
        "WxPri\tOn",
        "Service\t1\tPolice\tOn",
        "Service\t2\tFire/Emergency\tOff",
        "Custom\t1\tSearch Bnak1\t25000000\t27995000\tOff",
        "Custom\t5\tSearch Bnak5\t108000000\t136991600\tOn",
        "CloseCall\tPri\tOn\tOff\tOff",
        "CloseCallBands\tOff\tOn\tOff\tOn\tOff",
        "GeneralSearch\t-5\tOn",
        "Conventional\t1\tBank 1\tOn",
        "C-Freq\t1\tGUARD\t121500000\tAM\tOff\tOff\t5\tOn",
        "C-Freq\t2\tTALKAROUND\t155475000\tNFM\tC110.9\tOff\t-10\tOff",
        "C-Freq\t3\t\t0\tAuto\tOff\tOn\t2\tOff",
        "Conventional\t2\tFire\tOff",
        "C-Freq\t51\tEMS\t155340000\tNFM\tD265\tOn\t0\tOff",
        "C-Freq\t52\tSEARCH\t151625000\tNFM\tSrch\tOff\t2\tOff",
        "C-Freq\t53\tWX\t162550000\tFM\tNoTone\tOff\t2\tOff",
    ].map { $0 + "\r\n" }.joined()

    @Test func readsUnidensLayout() throws {
        let config = try UnidenFormat.decode(Data(Self.sample.utf8))
        #expect(config.settings.backlight == .keypressAndSquelch)
        #expect(config.settings.keyBeep == .off)
        #expect(config.settings.batteryChargeHours == 14)
        #expect(config.settings.priorityMode == .plusOn)
        #expect(config.settings.weatherAlertPriority)
        #expect(config.metadata.bandPlanRegion == .canada)
        // Bank, service group and custom range On/Off are raw mask digits: On means disabled.
        #expect(config.bankScanEnabled[0] == false)
        #expect(config.bankScanEnabled[1] == true)
        #expect(config.search.serviceGroupsEnabled[0] == false)
        #expect(config.search.serviceGroupsEnabled[1] == true)
        #expect(config.search.customRanges[0].enabled)
        #expect(!config.search.customRanges[4].enabled)
        #expect(config.search.customRanges[4].upper == Frequency(hundredHz: 1_369_916))
        // Close Call bands are the right way round.
        #expect(config.closeCall.bandsEnabled == [false, true, false, true, false])
        #expect(config.closeCall.mode == .priority)
        #expect(!config.closeCall.alertLight)
        #expect(config.search.delay == .minus5)
        #expect(config.search.codeSearch)
        // Uniden's default bank names mean "no name".
        #expect(config.bankNames[0] == "")
        #expect(config.bankNames[1] == "Fire")

        #expect(config[channel: 1] == Channel(name: "GUARD", frequency: Frequency(parsing: "121.5"), modulation: .am, delay: .five, priority: true))
        #expect(config[channel: 2].tone == .ctcss(index: ToneCode.ctcssTenthsHz.firstIndex(of: 1109)!))
        #expect(config[channel: 2].delay == .minus10)
        #expect(config[channel: 3] == .empty)
        #expect(config[channel: 51].tone == .dcs(index: ToneCode.dcsCodes.firstIndex(of: 265)!))
        #expect(config[channel: 51].lockedOut)
        #expect(config[channel: 52].tone == .search)
        #expect(config[channel: 53].tone == .noTone)
        #expect(config[channel: 53].modulation == .fm)
        #expect(config.globalLockouts.isEmpty)
    }

    @Test func roundTrips() throws {
        var config = sampleConfig()
        config.bankNames[3] = "Tab\tin name"
        let decoded = try UnidenFormat.decode(UnidenFormat.encode(config))
        var expected = config
        expected.globalLockouts = []
        expected.bankNames[3] = "Tab in name"
        expected.metadata.bandPlanRegion = .usa
        #expect(decoded == expected)
        // Encoding what was decoded gives the same bytes again.
        #expect(UnidenFormat.encode(decoded) == UnidenFormat.encode(config))
    }

    @Test func writesUnidensLayout() throws {
        let text = String(decoding: UnidenFormat.encode(ScannerConfig()), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.count == 1 + 2 + 10 + 10 + 3 + 10 + 500 + 1)
        #expect(lines.last == "")
        #expect(lines[0] == "Misc\tKey\tAuto\tOff\t8\t9\t8\t2\tUSA")
        #expect(lines[13] == "Custom\t1\tSearch Bnak1\t25000000\t27995000\tOff")
        #expect(lines[26] == "Conventional\t1\tBank 1\tOff")
        #expect(lines[29] == "C-Freq\t3\t\t0\tAuto\tOff\tOn\t2\tOff")
        #expect(ToneCode.dcs(index: 0).unidenName == "D023")
        #expect(ToneCode.ctcss(index: 0).unidenName == "C67.0")
    }

    @Test func refusesValuesItDoesNotKnow() {
        let badTone = Self.sample.replacingOccurrences(of: "C110.9", with: "C111.1")
        #expect(throws: UnidenFormat.ImportError.invalid(line: 13, message: "“C111.1” isn't a known tone")) {
            try UnidenFormat.decode(Data(badTone.utf8))
        }
        let unknownRecord = Self.sample + "Trunk\t1\tOn\r\n"
        #expect(throws: UnidenFormat.ImportError.invalid(line: 19, message: "unknown record “Trunk”")) {
            try UnidenFormat.decode(Data(unknownRecord.utf8))
        }
        #expect(throws: UnidenFormat.ImportError.notAUnidenFile) {
            try UnidenFormat.decode(Data("C-Freq\t1\tX\t121500000\tAM\tOff\tOff\t2\tOff\r\n".utf8))
        }
    }

    @Test func warnsAboutTheCanadaBandPlan() {
        var config = ScannerConfig()
        #expect(!config.validate().contains { $0.message.contains("Canada") })
        config.metadata.bandPlanRegion = .canada
        #expect(config.validate().contains { $0.severity == .warning && $0.message.contains("Canada") })
    }
}
