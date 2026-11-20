import Foundation

/// Key for per-setup calibration: camera + diffuser + light type.
public struct SetupKey: Hashable, Sendable, Codable {
    public var camera: Calibration.CameraPosition
    public var diffuser: String
    public var lightType: String
    public init(camera: Calibration.CameraPosition, diffuser: String, lightType: String) {
        self.camera = camera
        self.diffuser = diffuser
        self.lightType = lightType
    }
}

/// T2.2 user calibration maths and store.
public struct UserCalibrations: Equatable, Sendable, Codable {
    public static let warnRange = 0.5...2.0
    public static let allowedRange = 0.1...10.0

    public enum Outcome: Equatable, Sendable {
        case accept(Double)
        /// Outside 0.5–2.0: save only if the user confirms.
        case needsConfirmation(Double)
    }

    public enum Refusal: Error, Equatable, Sendable {
        case zeroReading
        case invalidReference
        case outOfRange(Double)
        case unstable
    }

    public private(set) var multipliers: [SetupKey: Double] = [:]

    public init() {}

    /// kUser = reference / uncalibrated PPFD.
    public static func evaluate(reference: PPFD, uncalibrated: PPFD) throws(Refusal) -> Outcome {
        guard uncalibrated.value.isFinite, uncalibrated.value > 0 else { throw .zeroReading }
        guard reference.value.isFinite, reference.value > 0 else { throw .invalidReference }
        let k = reference.value / uncalibrated.value
        guard allowedRange.contains(k) else { throw .outOfRange(k) }
        return warnRange.contains(k) ? .accept(k) : .needsConfirmation(k)
    }

    /// Stable = (max − min) / mean below the limit over the window, and non-zero.
    public static func isStable(
        _ window: [Double],
        maxVariation: Double = Provisional.calibrationStabilityMaxVariation
    ) -> Bool {
        guard let lo = window.min(), let hi = window.max(), window.count > 1 else { return false }
        let mean = window.reduce(0, +) / Double(window.count)
        guard mean > 0 else { return false }
        return (hi - lo) / mean < maxVariation
    }

    public func kUser(for key: SetupKey) -> Double { multipliers[key] ?? 1 }

    /// Stores an accepted (or confirmed) multiplier. Re-checks the hard limits.
    public mutating func set(_ k: Double, for key: SetupKey) throws(Refusal) {
        guard k.isFinite, Self.allowedRange.contains(k) else { throw .outOfRange(k) }
        multipliers[key] = k
    }

    public mutating func reset(_ key: SetupKey) { multipliers[key] = nil }
    public mutating func deleteAll() { multipliers.removeAll() }
}

/// T1.4 custom diffuser: measure the same steady light with a known diffuser, then the new one.
/// Same light → same lux, so kBase_new × S_new = kBase_known × S_known.
public func customDiffuserKBase(
    knownKBase: Double, signalWithKnown: Double,
    signalWithNew: Double
) throws(ValidationError) -> Double {
    for v in [knownKBase, signalWithKnown, signalWithNew] {
        guard v.isFinite else { throw .notANumber }
        guard v > 0 else { throw .zero }
    }
    let k = knownKBase * signalWithKnown / signalWithNew
    guard k.isFinite, k > 0 else { throw .notANumber }
    return k
}

public struct Vector3: Equatable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// T1.1 level indicator. Angle between measured gravity and the gravity expected
/// in the measuring orientation, in degrees.
public func tiltDegrees(gravity g: Vector3, reference r: Vector3) -> Double {
    let dot = g.x * r.x + g.y * r.y + g.z * r.z
    let n = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot() * (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
    guard n > 0 else { return 0 }
    return acos(min(1, max(-1, dot / n))) * 180 / .pi
}

public func isTiltWarning(degrees: Double, limit: Double = Provisional.tiltWarningDegrees) -> Bool {
    degrees > limit
}
