import Foundation

/// One exposure setting.
public struct Exposure: Equatable, Sendable, Codable {
    public var seconds: Double
    public var iso: Double
    public init(seconds: Double, iso: Double) {
        self.seconds = seconds
        self.iso = iso
    }
    /// Exposure "amount" in ISO-100-equivalent seconds.
    public var normalized: Double { seconds * iso / 100 }
}

/// Method A: fixed exposure steps, `stepStops` apart, from brightest (index 0) to darkest.
public struct ExposureLadder: Sendable {
    public let steps: [Exposure]

    public init(minSeconds: Double, maxSeconds: Double, minISO: Double, maxISO: Double, stepStops: Double) {
        precondition(minSeconds > 0 && maxSeconds >= minSeconds && minISO > 0 && maxISO >= minISO && stepStops > 0)
        let eMax = maxSeconds * maxISO
        let eMin = minSeconds * minISO
        let count = Int((log2(eMax / eMin) / stepStops).rounded(.down)) + 1
        steps = (0..<count).map { k in
            let e = eMax / pow(2, Double(k) * stepStops)
            // Prefer lowest ISO (less noise): longest exposure first, then raise ISO.
            if e / minISO <= maxSeconds {
                return Exposure(seconds: max(minSeconds, e / minISO), iso: minISO)
            }
            return Exposure(seconds: maxSeconds, iso: min(maxISO, e / maxSeconds))
        }
    }

    public enum Decision: Equatable, Sendable {
        case stay
        case moveTo(Int)
        case tooBright  // already at darkest step and still above threshold
        case tooDark  // already at brightest step and still below threshold
    }

    /// Hysteresis: step darker above `downAbove`, brighter below `upBelow`.
    /// With 1-stop steps the signal halves/doubles, so `upBelow * 2 < downAbove / 2`
    /// guarantees landing strictly inside the dead band.
    public func decide(
        current: Int, meanLinear: Double, saturated: Bool,
        downAbove: Double, upBelow: Double
    ) -> Decision {
        if saturated || meanLinear > downAbove {
            return current + 1 < steps.count ? .moveTo(current + 1) : .tooBright
        }
        if meanLinear < upBelow {
            return current > 0 ? .moveTo(current - 1) : .tooDark
        }
        return .stay
    }
}

/// True when reported per-frame metadata matches what was requested.
public func exposureMatches(requested: Exposure, reported: Exposure, tolerance: Double) -> Bool {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance * max(abs(a), abs(b)) }
    return close(requested.seconds, reported.seconds) && close(requested.iso, reported.iso)
}

/// Spike signal definitions. T0.0 picks one; the other is deleted.
public enum Signal {
    /// Method A: pixel value normalised by exposure.
    public static func methodA(meanLinear: Double, exposure: Exposure) -> Double {
        meanLinear / exposure.normalized
    }

    /// Method B: auto-exposure as the meter. AE aims for a fixed mid-grey; the scene is
    /// brighter than the settings imply by 2^targetOffset when AE hasn't converged.
    public static func methodB(exposure: Exposure, targetOffsetEV: Double) -> Double {
        pow(2, targetOffsetEV) / exposure.normalized
    }
}

/// Mean and coefficient of variation over a sliding window.
public struct RollingStats: Sendable {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func add(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public mutating func reset() { values.removeAll() }

    public var isFull: Bool { values.count == capacity }

    public var mean: Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation / mean.
    public var coefficientOfVariation: Double? {
        guard values.count > 1, let m = mean, m != 0 else { return nil }
        let ss = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(values.count - 1)).squareRoot() / abs(m)
    }
}
