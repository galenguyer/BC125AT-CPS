import Foundation

/// Which frequencies the scanner accepts, and where it moves the ones that are off its channel plan.
///
/// The tables are the owner's manual's; the rules were measured on a BC125AT running firmware 1.06.06
/// (SPEC.md §3.5):
/// 1. Valid points are `start + n × step` within a segment, truncated to 100 Hz.
/// 2. Any other in-range frequency is stored as the nearest valid point (compared after
///    truncation), with exact ties rounding up.
/// 3. In 137–174 MHz, exact multiples of 5 kHz are kept as sent.
public struct BandPlan: Sendable {
    public struct Segment: Sendable {
        /// Hertz.
        public var start: Int
        /// Hertz, inclusive.
        public var end: Int
        /// Step in hertz as a fraction, so 8.33 kHz (25000/3) stays exact. `0` for a single channel.
        public var stepNumerator: Int
        public var stepDenominator: Int

        public init(start: Int, end: Int, step: Int) {
            self.init(start: start, end: end, stepNumerator: step, stepDenominator: 1)
        }

        public init(start: Int, end: Int, stepNumerator: Int, stepDenominator: Int) {
            self.start = start
            self.end = end
            self.stepNumerator = stepNumerator
            self.stepDenominator = stepDenominator
        }

        /// The valid points nearest to `hundredHz` from below and above, within this segment.
        func neighbours(of hundredHz: Int) -> (below: Int?, above: Int?) {
            let first = start / 100
            guard stepNumerator > 0 else { return (first <= hundredHz ? first : nil, first >= hundredHz ? first : nil) }
            let count = ((end - start) * stepDenominator) / stepNumerator
            func point(_ n: Int) -> Int { (start * stepDenominator + n * stepNumerator) / (stepDenominator * 100) }
            // Largest n whose truncated point is ≤ hundredHz.
            var n = max(0, min(count, ((hundredHz * 100 - start) * stepDenominator) / stepNumerator))
            while n > 0, point(n) > hundredHz { n -= 1 }
            while n < count, point(n + 1) <= hundredHz { n += 1 }
            let below = point(n) <= hundredHz ? point(n) : nil
            let above = point(n) >= hundredHz ? point(n) : (n < count ? point(n + 1) : nil)
            return (below, above)
        }
    }

    /// Frequency ranges the scanner accepts at all, in 100 Hz units (inclusive).
    public var ranges: [ClosedRange<UInt32>]
    public var segments: [Segment]
    /// Ranges where an exact multiple of 5 kHz is stored as sent, in 100 Hz units.
    public var keepsExact5kHz: [ClosedRange<UInt32>]

    public func contains(_ frequency: Frequency) -> Bool {
        ranges.contains { $0.contains(frequency.hundredHz) }
    }

    /// What the scanner will store if sent `frequency`, or `nil` if it would reject it (`CIN,ERR`).
    public func storedValue(for frequency: Frequency) -> Frequency? {
        guard let range = ranges.first(where: { $0.contains(frequency.hundredHz) }) else { return nil }
        if segments.isEmpty { return frequency }
        if frequency.hundredHz % 50 == 0, keepsExact5kHz.contains(where: { $0.contains(frequency.hundredHz) }) {
            return frequency
        }
        let target = Int(frequency.hundredHz)
        var best: Int?
        for segment in segments where segment.end / 100 >= Int(range.lowerBound) && segment.start / 100 <= Int(range.upperBound) {
            let (below, above) = segment.neighbours(of: target)
            for candidate in [below, above].compactMap({ $0 }) {
                guard let current = best else { best = candidate; continue }
                let distance = abs(candidate - target), bestDistance = abs(current - target)
                if distance < bestDistance || (distance == bestDistance && candidate > current) { best = candidate }
            }
        }
        return best.map { Frequency(hundredHz: UInt32($0)) }
    }

    /// Only the scanner's frequency ranges, with every in-range frequency predicted to be stored
    /// as sent. For comparing against values that are already as stored.
    public static let rangesOnly = BandPlan(ranges: usa.ranges, segments: [], keepsExact5kHz: [])

    private static let ranges: [ClosedRange<UInt32>] = [250_000...540_000, 1_080_000...1_740_000, 2_250_000...3_800_000, 4_000_000...5_120_000]

    /// One row of a band plan table in the owner's manual, in hertz. The manual prints frequencies
    /// to 100 Hz, so a few are written out here in full: 136.99167 (printed 136.9916), 154.45625
    /// (154.4562), 173.20375 (173.2037) and 173.39625 (173.3962).
    private static func row(_ lower: Int, _ upper: Int, _ step: Int) -> Segment {
        step == 8_333 ? Segment(start: lower, end: upper, stepNumerator: 25_000, stepDenominator: 3) : Segment(start: lower, end: upper, step: step)
    }

    /// The USA band plan, from the table in the owner's manual ("USA Band Plan", p. 14).
    ///
    /// Checked against Phase 0's measurements (SPEC.md §3.5, `phase0/band-plan.json`): both give the
    /// same 44,967 points. The manual doesn't give the snapping rules or the 137–174 MHz
    /// exact-5 kHz exception; those were measured.
    public static let usa = BandPlan(
        ranges: ranges,
        segments: [
            row(25_000_000, 27_995_000, 5_000),
            row(28_000_000, 54_000_000, 5_000),
            row(108_000_000, 136_991_667, 8_333),
            row(137_000_000, 150_770_000, 5_000),
            row(150_775_000, 150_812_500, 7_500),
            row(150_815_000, 154_452_500, 7_500),
            row(154_456_250, 154_478_750, 7_500),
            row(154_482_500, 154_512_500, 7_500),
            row(154_515_000, 154_525_000, 5_000),
            row(154_527_500, 154_535_000, 7_500),
            row(154_540_000, 154_607_500, 7_500),
            row(154_610_000, 154_647_500, 7_500),
            row(154_650_000, 157_447_500, 7_500),
            row(157_450_000, 157_465_000, 5_000),
            row(157_470_000, 163_245_000, 7_500),
            row(163_250_000, 173_200_000, 12_500),
            row(173_203_750, 173_210_000, 6_250),
            row(173_215_000, 173_220_000, 5_000),
            row(173_225_000, 173_387_500, 12_500),
            row(173_390_000, 173_396_250, 6_250),
            row(173_400_000, 174_000_000, 5_000),
            row(225_000_000, 380_000_000, 12_500),
            row(400_000_000, 512_000_000, 6_250),
        ],
        keepsExact5kHz: [1_370_000...1_740_000]
    )

    /// The Canada band plan, from the table in the owner's manual ("Canada Band Plan", p. 15): the
    /// USA plan with a plain 5 kHz grid in 137–174 MHz. Spot-checked on hardware at four points in
    /// 150–174 MHz, and in 25–54, 137–150.775 and 225–380 MHz (SPEC.md §3.5).
    public static let canada = BandPlan(
        ranges: ranges,
        segments: [
            row(25_000_000, 27_995_000, 5_000),
            row(28_000_000, 54_000_000, 5_000),
            row(108_000_000, 136_991_667, 8_333),
            row(137_000_000, 174_000_000, 5_000),
            row(225_000_000, 380_000_000, 12_500),
            row(400_000_000, 512_000_000, 6_250),
        ],
        keepsExact5kHz: []
    )
}
