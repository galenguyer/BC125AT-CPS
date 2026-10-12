import Foundation

/// The `.bc125at` document format (SPEC.md §5): pretty-printed JSON with a format tag and version.
/// Only non-empty channels are stored, each with its channel number.
public enum NativeFormat {
    public static let formatIdentifier = "net.k9fgt.bc125at.config"
    public static let currentVersion = 1

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notABC125ATFile
        case newerVersion(Int)
        case invalid(String)

        public var description: String {
            switch self {
            case .notABC125ATFile: "This isn't a BC125AT CPS file."
            case .newerVersion(let version): "This file was saved by a newer version of BC125AT CPS (format \(version))."
            case .invalid(let reason): "The file is damaged: \(reason)"
            }
        }
    }

    public static func encode(_ config: ScannerConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(File(config: config))
    }

    public static func decode(_ data: Data) throws(ReadError) -> ScannerConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw .notABC125ATFile
        }
        guard header.format == formatIdentifier else { throw .notABC125ATFile }
        guard header.version <= currentVersion else { throw .newerVersion(header.version) }
        do {
            return try decoder.decode(File.self, from: data).config()
        } catch let error as ReadError {
            throw error
        } catch {
            throw .invalid(describe(error))
        }
    }

    // MARK: File layout

    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    private struct Bank: Codable {
        var bank: Int
        var name: String
        var scanEnabled: Bool
    }

    private struct NumberedChannel: Codable {
        var channel: Int
        var contents: Channel

        enum CodingKeys: String, CodingKey { case channel }

        init(channel: Int, contents: Channel) {
            self.channel = channel
            self.contents = contents
        }

        init(from decoder: any Decoder) throws {
            channel = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .channel)
            contents = try Channel(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(channel, forKey: .channel)
            try contents.encode(to: encoder)
        }
    }

    private struct File: Codable {
        var format = NativeFormat.formatIdentifier
        var version = NativeFormat.currentVersion
        var metadata: ScannerConfig.Metadata
        var settings: SystemSettings
        var search: SearchSettings
        var closeCall: CloseCallSettings
        var banks: [Bank]
        var globalLockouts: [Frequency]
        var channels: [NumberedChannel]

        init(config: ScannerConfig) {
            metadata = config.metadata
            settings = config.settings
            search = config.search
            closeCall = config.closeCall
            banks = (1...ScannerConfig.bankCount).map {
                Bank(bank: $0, name: config.bankNames[$0 - 1], scanEnabled: config.bankScanEnabled[$0 - 1])
            }
            globalLockouts = config.globalLockouts
            channels = config.channels.enumerated().filter { !$0.element.isEmpty }.map {
                NumberedChannel(channel: $0.offset + 1, contents: $0.element)
            }
        }

        func config() throws(ReadError) -> ScannerConfig {
            guard search.serviceGroupsEnabled.count == ServiceSearchGroup.allCases.count,
                  search.customRanges.count == 10,
                  closeCall.bandsEnabled.count == CloseCallBand.allCases.count
            else { throw .invalid("search or Close Call settings have the wrong number of entries") }
            var config = ScannerConfig(settings: settings, search: search, closeCall: closeCall,
                                       globalLockouts: Array(Set(globalLockouts)).sorted(), metadata: metadata)
            for bank in banks {
                guard (1...ScannerConfig.bankCount).contains(bank.bank) else { throw .invalid("bank \(bank.bank) doesn't exist") }
                config.bankNames[bank.bank - 1] = bank.name
                config.bankScanEnabled[bank.bank - 1] = bank.scanEnabled
            }
            for numbered in channels {
                guard (1...ScannerConfig.channelCount).contains(numbered.channel) else {
                    throw .invalid("channel \(numbered.channel) doesn't exist")
                }
                config[channel: numbered.channel] = numbered.contents.isEmpty ? .empty : numbered.contents
            }
            return config
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return "\(context.debugDescription) at \(path.isEmpty ? "top level" : path)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
