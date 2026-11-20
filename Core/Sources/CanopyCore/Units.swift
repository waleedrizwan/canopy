import Foundation

/// Illuminance, lux.
public struct Lux: Hashable, Comparable, Sendable, Codable {
    public var value: Double
    public init(_ value: Double) { self.value = value }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// Photosynthetic photon flux density, µmol·m⁻²·s⁻¹.
public struct PPFD: Hashable, Comparable, Sendable, Codable {
    public var value: Double
    public init(_ value: Double) { self.value = value }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// Daily light integral, mol·m⁻²·d⁻¹.
public struct DLI: Hashable, Comparable, Sendable, Codable {
    public var value: Double
    public init(_ value: Double) { self.value = value }
    public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// Hours of light per day, 0–24 in 0.5 h steps.
public struct Photoperiod: Hashable, Sendable, Codable {
    public let hours: Double
    public static let range = 0.0...24.0
    public static let step = 0.5

    public init(hours: Double) throws(ValidationError) {
        guard hours.isFinite else { throw .notANumber }
        guard Self.range.contains(hours) else { throw .outOfRange(Self.range) }
        guard (hours / Self.step).rounded() * Self.step == hours else { throw .notAStep(Self.step) }
        self.hours = hours
    }

    public static let twelveHours = Photoperiod(uncheckedHours: 12)
    private init(uncheckedHours: Double) { hours = uncheckedHours }
}

public enum ValidationError: Error, Equatable, Sendable {
    case empty
    case notANumber
    case negative
    case zero
    case outOfRange(ClosedRange<Double>)
    case notAStep(Double)
}

/// Parses a user-typed number. Locale decides the decimal separator.
public func parseNumber(_ text: String, locale: Locale = .current) throws(ValidationError) -> Double {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw .empty }
    let f = NumberFormatter()
    f.locale = locale
    f.numberStyle = .decimal
    guard let n = f.number(from: trimmed)?.doubleValue, n.isFinite else { throw .notANumber }
    return n
}
