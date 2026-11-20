import Foundation

/// Measurement pipeline steps 3 and 4 (spec "Measurement pipeline").
/// Step 1 (S) is in Exposure.swift/FrameStats.swift; step 2 (lux) in Calibration.swift.
public enum Pipeline {
    /// mol per µmol × seconds per hour = 1e-6 × 3600.
    public static let dliFactor = 0.0036

    public static func ppfd(lux: Lux, fLight: Double, kUser: Double = 1) -> PPFD {
        PPFD(lux.value * fLight * kUser)
    }

    public static func lux(ppfd: PPFD, fLight: Double, kUser: Double = 1) -> Lux {
        Lux(ppfd.value / (fLight * kUser))
    }

    public static func dli(ppfd: PPFD, photoperiod: Photoperiod) -> DLI {
        DLI(ppfd.value * photoperiod.hours * dliFactor)
    }
}

/// Display formatting. Locale is a parameter so tests can pin it.
public enum Format {
    /// Integer lux with grouping: 12345.6 → "12,346 lx".
    public static func lux(_ v: Lux, locale: Locale = .current) -> String {
        "\(Int(v.value.rounded()).formatted(.number.locale(locale).grouping(.automatic))) lx"
    }

    /// Integer, or one decimal below 10.
    public static func ppfd(_ v: PPFD, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.number.locale(locale)
        return v.value < 10
            ? v.value.formatted(style.precision(.fractionLength(1)).rounded(rule: .toNearestOrAwayFromZero))
            : v.value.formatted(style.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero))
    }

    /// One decimal.
    public static func dli(_ v: DLI, locale: Locale = .current) -> String {
        v.value.formatted(.number.locale(locale).precision(.fractionLength(1)).rounded(rule: .toNearestOrAwayFromZero))
    }

    /// One decimal hours.
    public static func hours(_ h: Double, locale: Locale = .current) -> String {
        "\(h.formatted(.number.locale(locale).precision(.fractionLength(1)).rounded(rule: .toNearestOrAwayFromZero))) h"
    }
}
