import Foundation

/// Which frequencies the scanner accepts, and where it moves the ones that are off its channel plan.
///
/// Measured on a BC125AT running firmware 1.06.06 (SPEC.md §3.5, `phase0/band-plan.json`):
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

    /// The BC125AT's measured plan (SPEC.md §3.5).
    public static let bc125at = BandPlan(
        ranges: [250_000...540_000, 1_080_000...1_740_000, 2_250_000...3_800_000, 4_000_000...5_120_000],
        segments: [
            .init(start: 25_000_000, end: 54_000_000, step: 5_000),
            .init(start: 108_000_000, end: 137_000_000, stepNumerator: 25_000, stepDenominator: 3),
            .init(start: 137_000_000, end: 150_775_000, step: 5_000),
            .init(start: 150_775_000, end: 150_812_500, step: 7_500),
            .init(start: 150_815_000, end: 154_452_500, step: 7_500),
            .init(start: 154_456_250, end: 154_478_750, step: 7_500),
            .init(start: 154_482_500, end: 154_512_500, step: 7_500),
            .init(start: 154_515_000, end: 154_525_000, step: 5_000),
            .init(start: 154_527_500, end: 154_535_000, step: 7_500),
            .init(start: 154_540_000, end: 154_607_500, step: 7_500),
            .init(start: 154_610_000, end: 154_647_500, step: 7_500),
            .init(start: 154_650_000, end: 157_447_500, step: 7_500),
            .init(start: 157_450_000, end: 157_470_000, step: 5_000),
            .init(start: 157_470_000, end: 163_245_000, step: 7_500),
            .init(start: 163_250_000, end: 173_200_000, step: 12_500),
            .init(start: 173_203_750, end: 173_203_750, step: 0),
            .init(start: 173_210_000, end: 173_225_000, step: 5_000),
            .init(start: 173_225_000, end: 173_387_500, step: 12_500),
            .init(start: 173_390_000, end: 173_390_000, step: 0),
            .init(start: 173_396_250, end: 173_396_250, step: 0),
            .init(start: 173_400_000, end: 174_000_000, step: 5_000),
            .init(start: 225_000_000, end: 380_000_000, step: 12_500),
            .init(start: 400_000_000, end: 512_000_000, step: 6_250),
        ],
        keepsExact5kHz: [1_370_000...1_740_000]
    )
}
