import Foundation

/// A channel's CTCSS/DCS squelch setting (SPEC.md §3.2).
public enum ToneCode: Hashable, Sendable {
    /// Code 0: no tone squelch (open).
    case none
    /// Code 127: search for a tone.
    case search
    /// Code 240: only open for signals without a tone.
    case noTone
    /// Codes 64–113, as an index into `ctcssTenthsHz`.
    case ctcss(index: Int)
    /// Codes 128–231, as an index into `dcsCodes`.
    case dcs(index: Int)

    /// The 50 CTCSS tones in tenths of a hertz, in code order (code = 64 + index).
    public static let ctcssTenthsHz: [Int] = [
        670, 693, 719, 744, 770, 797, 825, 854, 885, 915, 948, 974, 1000, 1035, 1072, 1109, 1148, 1188, 1230, 1273,
        1318, 1365, 1413, 1462, 1514, 1567, 1598, 1622, 1655, 1679, 1713, 1738, 1773, 1799, 1835, 1862, 1899, 1928,
        1966, 1995, 2035, 2065, 2107, 2181, 2257, 2291, 2336, 2418, 2503, 2541,
    ]

    /// The 104 DCS codes (octal digits written as a decimal number), in code order (code = 128 + index).
    public static let dcsCodes: [Int] = [
        23, 25, 26, 31, 32, 36, 43, 47, 51, 53, 54, 65, 71, 72, 73, 74, 114, 115, 116, 122, 125, 131, 132, 134, 143,
        145, 152, 155, 156, 162, 165, 172, 174, 205, 212, 223, 225, 226, 243, 244, 245, 246, 251, 252, 255, 261, 263,
        265, 266, 271, 274, 306, 311, 315, 325, 331, 332, 343, 346, 351, 356, 364, 365, 371, 411, 412, 413, 423, 431,
        432, 445, 446, 452, 454, 455, 462, 464, 465, 466, 503, 506, 516, 523, 526, 532, 546, 565, 606, 612, 624, 627,
        631, 632, 654, 662, 664, 703, 712, 723, 731, 732, 734, 743, 754,
    ]

    public static let allCases: [ToneCode] = [.none, .search, .noTone]
        + ctcssTenthsHz.indices.map { .ctcss(index: $0) }
        + dcsCodes.indices.map { .dcs(index: $0) }

    public init?(code: Int) {
        switch code {
        case 0: self = .none
        case 127: self = .search
        case 240: self = .noTone
        case 64...113: self = .ctcss(index: code - 64)
        case 128...231: self = .dcs(index: code - 128)
        default: return nil
        }
    }

    public var code: Int {
        switch self {
        case .none: 0
        case .search: 127
        case .noTone: 240
        case .ctcss(let index): 64 + index
        case .dcs(let index): 128 + index
        }
    }

    /// `CSQ` (carrier squelch: no tone, opens for any signal), `Search`, `No Tone`, `CTCSS 100.0`,
    /// `DCS 023`.
    public var displayName: String {
        switch self {
        case .none: return "CSQ"
        case .search: return "Search"
        case .noTone: return "No Tone"
        case .ctcss(let index):
            let tenths = Self.ctcssTenthsHz[index]
            return "CTCSS \(tenths / 10).\(tenths % 10)"
        case .dcs(let index):
            let code = String(Self.dcsCodes[index])
            return "DCS " + String(repeating: "0", count: 3 - code.count) + code
        }
    }

    /// Accepts `displayName` forms plus common shorthand: `100.0`, `100`, `D023`, `023N`,
    /// `no tone`, `notone`, and bc125py's `ctcss_100.0` / `dcs_23`.
    public init?(parsing text: String) {
        let compact = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." }
        switch compact {
        case "", "csq", "none", "off", "all": self = .none; return
        case "search", "srch": self = .search; return
        case "notone": self = .noTone; return
        default: break
        }
        var body = Substring(compact)
        var isDCS = false
        if body.hasPrefix("ctcss") { body = body.dropFirst(5) }
        else if body.hasPrefix("dcs") { body = body.dropFirst(3); isDCS = true }
        else if body.hasPrefix("d") { body = body.dropFirst(); isDCS = true }
        // `023N` / `023I`: DCS with a normal or inverted suffix.
        if let last = body.last, last == "n" || last == "i", body.dropLast().allSatisfy(\.isASCIIDigit) { isDCS = true }
        if isDCS {
            if body.hasSuffix("n") || body.hasSuffix("i") { body = body.dropLast() }
            guard let value = Int(body), let index = Self.dcsCodes.firstIndex(of: value) else { return nil }
            self = .dcs(index: index)
        } else {
            let parts = body.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let whole = Int(parts[0]) else { return nil }
            let tenths = whole * 10 + (parts.count == 2 ? Int(parts[1].prefix(1)) ?? 0 : 0)
            guard let index = Self.ctcssTenthsHz.firstIndex(of: tenths) else { return nil }
            self = .ctcss(index: index)
        }
    }
}

extension ToneCode {
    /// How Uniden's software writes a tone: `Off`, `Srch`, `NoTone`, `C110.9`, `D023`.
    public var unidenName: String {
        switch self {
        case .none: return "Off"
        case .search: return "Srch"
        case .noTone: return "NoTone"
        case .ctcss(let index):
            let tenths = Self.ctcssTenthsHz[index]
            return "C\(tenths / 10).\(tenths % 10)"
        case .dcs(let index):
            let code = String(Self.dcsCodes[index])
            return "D" + String(repeating: "0", count: max(0, 3 - code.count)) + code
        }
    }

    /// Reads exactly the forms `unidenName` writes.
    public init?(unidenName text: String) {
        switch text {
        case "Off": self = .none
        case "Srch": self = .search
        case "NoTone": self = .noTone
        default:
            if text.hasPrefix("C"), let hertz = Double(text.dropFirst()),
               let index = Self.ctcssTenthsHz.firstIndex(of: Int((hertz * 10).rounded())) {
                self = .ctcss(index: index)
            } else if text.hasPrefix("D"), let code = Int(text.dropFirst()), let index = Self.dcsCodes.firstIndex(of: code) {
                self = .dcs(index: index)
            } else {
                return nil
            }
        }
    }
}

extension ToneCode: CustomStringConvertible {
    public var description: String { displayName }
}

/// Encoded the way Uniden's software writes tones (`Off`, `Srch`, `NoTone`, `C110.9`, `D023`),
/// so saved files match Uniden's `.bc125at_ss` files.
extension ToneCode: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let tone = ToneCode(unidenName: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tone \(text.debugDescription)"))
        }
        self = tone
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(unidenName)
    }
}
