import BC125ATKit
import Foundation

/// Hardware experiments that write to the scanner and restore it afterwards (SPEC.md §3.3, §3.5).
enum Probe {
    /// Writes each frequency in `frequencies` to spare empty channels, reads back what the scanner
    /// stored, and prints `sent,stored` CSV (`ERR` if rejected). Writes rotate across `spread` empty
    /// channels to spread wear on the scanner's memory. Every channel used is restored with `DCH`.
    static func frequencies(_ frequencies: [Int], modulation: String, spread: Int, connection: ScannerConnection) throws {
        try connection.inProgramMode {
            let spares = try spareChannels(connection, count: max(1, spread))
            FileHandle.standardError.write(Data("using \(spares.count) empty channels \(spares.last!.index)…\(spares.first!.index)\n".utf8))
            defer {
                for spare in spares {
                    _ = try? connection.send("DCH,\(spare.index)")
                    if (try? connection.send("CIN,\(spare.index)")).flatMap(RawChannel.init) != spare {
                        FileHandle.standardError.write(Data("warning: channel \(spare.index) did not return to empty\n".utf8))
                    }
                }
            }
            print("sent,stored")
            for (offset, frequency) in frequencies.enumerated() {
                try checkInterrupted()
                let index = spares[offset % spares.count].index
                let reply = try connection.send("CIN,\(index),STEPTEST,\(frequency),\(modulation),0,2,1,0")
                guard reply == "CIN,OK" else {
                    print("\(frequency),ERR")
                    continue
                }
                let stored = RawChannel(reply: try connection.send("CIN,\(index)")).flatMap { Int($0.frequency) }
                print("\(frequency),\(stored.map(String.init) ?? "?")")
            }
        }
    }

    /// Adds global lockouts at `start`, `start + step`, … until the scanner refuses one or `limit`
    /// is reached, reports the capacity, then removes every lockout that wasn't there before.
    static func lockoutCapacity(start: Int, step: Int, limit: Int, connection: ScannerConnection) throws {
        try connection.inProgramMode {
            let original = try lockouts(connection)
            FileHandle.standardError.write(Data("existing lockouts: \(original.count)\n".utf8))
            defer { restoreLockouts(to: original, connection: connection) }

            var accepted = 0
            var firstRefusal: (Int, String)?
            for frequency in stride(from: start, to: start + step * limit, by: step) {
                try checkInterrupted()
                let reply = try connection.send("LOF,\(frequency)")
                if reply != "LOF,OK" {
                    firstRefusal = (frequency, reply)
                    break
                }
                accepted += 1
            }
            let listed = try lockouts(connection)
            print("LOF accepted: \(accepted) new (plus \(original.count) existing)")
            print("GLF lists: \(listed.count)")
            if let (frequency, reply) = firstRefusal {
                print("first refusal: LOF,\(frequency) → \(reply)")
            } else {
                print("no refusal within \(limit) adds")
            }
            // Once full, does the scanner drop new entries or evict old ones?
            print("first listed: \(listed.first ?? "-"), last listed: \(listed.last ?? "-")")
        }
    }

    private static func lockouts(_ connection: ScannerConnection) throws -> [String] {
        _ = try connection.send("GLF,0")
        var found: [String] = []
        while found.count < 10_000 {
            let reply = try connection.send("GLF")
            guard reply.hasPrefix("GLF,"), reply != "GLF,-1" else { break }
            found.append(String(reply.dropFirst(4)))
        }
        return found
    }

    private static func restoreLockouts(to original: [String], connection: ScannerConnection) {
        let keep = Set(original)
        guard let current = try? lockouts(connection) else {
            FileHandle.standardError.write(Data("warning: could not read lockouts to restore them\n".utf8))
            return
        }
        for frequency in current where !keep.contains(frequency) {
            _ = try? connection.send("ULF,\(frequency)")
        }
        let after = (try? lockouts(connection)) ?? []
        let restored = Set(after) == keep
        FileHandle.standardError.write(Data((restored
            ? "lockouts restored (\(after.count))\n"
            : "warning: lockouts not restored: \(after.count) listed, expected \(original.count)\n").utf8))
    }

    /// Up to `count` empty channels, highest index first.
    private static func spareChannels(_ connection: ScannerConnection, count: Int) throws -> [RawChannel] {
        var spares: [RawChannel] = []
        for index in stride(from: 500, through: 1, by: -1) where spares.count < count {
            if let channel = RawChannel(reply: try connection.send("CIN,\(index)")), channel.isEmpty {
                spares.append(channel)
            }
        }
        guard !spares.isEmpty else {
            throw ScannerError.unexpectedResponse(command: "CIN", response: "no empty channel to use")
        }
        return spares
    }
}
