import Foundation

/// A radio frequency in the scanner's native unit of 100 Hz (SPEC.md §3.1).
///
/// Integer storage keeps arithmetic and comparisons exact; nothing here uses floating point.
public struct Frequency: Hashable, Comparable, Sendable {
    public var hundredHz: UInt32

    public init(hundredHz: UInt32) {
        self.hundredHz = hundredHz
    }

    /// Truncates to 100 Hz, as the scanner does (406.00625 MHz → 406.0062).
    public init(hertz: Int) {
        self.hundredHz = UInt32(max(0, hertz) / 100)
    }

    public var hertz: Int { Int(hundredHz) * 100 }

    public static func < (lhs: Frequency, rhs: Frequency) -> Bool {
        lhs.hundredHz < rhs.hundredHz
    }

    // MARK: Wire format

    /// Parses a wire value such as `01625500`. Returns `nil` for malformed text; `0` is a valid
    /// value that callers treat as "no frequency".
    public init?(wire: some StringProtocol) {
        guard !wire.isEmpty, wire.allSatisfy(\.isASCIIDigit), let value = UInt32(wire) else { return nil }
        self.hundredHz = value
    }

    /// The 8-digit, zero-padded form the scanner uses in replies (and accepts in commands).
    public var wireValue: String {
        let digits = String(hundredHz)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    // MARK: Display

    /// `162.5500`: MHz with four decimal places, the scanner's own resolution.
    public var megahertzString: String {
        let whole = hundredHz / 10_000
        let fraction = String(hundredHz % 10_000)
        return "\(whole).\(String(repeating: "0", count: 4 - fraction.count))\(fraction)"
    }

    /// Parses what a person types: `162.55`, `162.55 MHz`, `162550k`, `162550 kHz`, `162550000 Hz`.
    ///
    /// Without a unit, values below 1,000 are MHz, below 1,000,000 kHz, otherwise Hz.
    /// Precision beyond 100 Hz is truncated (`154.00625` → 154.0062), matching the scanner.
    public init?(parsing text: String) {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        var unitHz: Int?
        for (suffix, hz) in [("mhz", 1_000_000), ("khz", 1_000), ("hz", 1), ("m", 1_000_000), ("k", 1_000)]
        where text.hasSuffix(suffix) {
            unitHz = hz
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              !(parts[0].isEmpty && (parts.count == 1 || parts[1].isEmpty)),
              parts[0].count <= 12
        else { return nil }
        let whole = Int(parts[0]) ?? 0
        let fraction = parts.count == 2 ? String(parts[1].prefix(9)) : ""
        let unit = unitHz ?? (whole < 1_000 ? 1_000_000 : whole < 1_000_000 ? 1_000 : 1)
        // Hertz = (whole + fraction) × unit, computed in integers.
        var hertz = whole * unit
        if !fraction.isEmpty {
            let scale = Int(pow(10, Double(fraction.count)))
            hertz += (Int(fraction) ?? 0) * unit / scale
        }
        guard hertz > 0, hertz <= 10_000_000_000 else { return nil }
        self.init(hertz: hertz)
    }
}

extension Frequency: CustomStringConvertible {
    public var description: String { megahertzString }
}

/// Encoded as a MHz string (`"162.5500"`) so saved files are readable.
extension Frequency: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let frequency = Frequency(parsing: text.hasSuffix("MHz") ? text : text + " MHz") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid frequency \(text.debugDescription)"))
        }
        self = frequency
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(megahertzString)
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
