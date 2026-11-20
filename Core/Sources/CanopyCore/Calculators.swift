import Foundation

/// T5.1 planning calculators. Never return NaN or infinity: bad input throws.
public enum Calculators {
    public enum HoursResult: Equatable, Sendable {
        case hours(Double)
        /// More than 24 h of this light would be needed.
        case notReachable(Double)
    }

    /// Required hours = dli / (ppfd × 0.0036).
    public static func requiredHours(dli: DLI, ppfd: PPFD) throws(ValidationError) -> HoursResult {
        try checkPositive(dli.value)
        try checkPositive(ppfd.value)
        let h = dli.value / (ppfd.value * Pipeline.dliFactor)
        return h > 24 ? .notReachable(h) : .hours(h)
    }

    /// Required PPFD = dli / (hours × 0.0036).
    public static func requiredPPFD(dli: DLI, hours: Double) throws(ValidationError) -> PPFD {
        try checkPositive(dli.value)
        try checkPositive(hours)
        guard hours <= 24 else { throw .outOfRange(0...24) }
        return PPFD(dli.value / (hours * Pipeline.dliFactor))
    }

    /// Lux → PPFD for a light type, using fLight × kUser (same as the measure screen).
    public static func ppfd(fromLux lux: Lux, fLight: Double, kUser: Double) throws(ValidationError) -> PPFD {
        try checkNonNegative(lux.value)
        try checkPositive(fLight)
        try checkPositive(kUser)
        return Pipeline.ppfd(lux: lux, fLight: fLight, kUser: kUser)
    }

    /// PPFD → lux for a light type.
    public static func lux(fromPPFD ppfd: PPFD, fLight: Double, kUser: Double) throws(ValidationError) -> Lux {
        try checkNonNegative(ppfd.value)
        try checkPositive(fLight)
        try checkPositive(kUser)
        return Pipeline.lux(ppfd: ppfd, fLight: fLight, kUser: kUser)
    }

    static func checkNonNegative(_ v: Double) throws(ValidationError) {
        guard v.isFinite else { throw .notANumber }
        guard v >= 0 else { throw .negative }
    }

    static func checkPositive(_ v: Double) throws(ValidationError) {
        try checkNonNegative(v)
        guard v > 0 else { throw .zero }
    }
}
