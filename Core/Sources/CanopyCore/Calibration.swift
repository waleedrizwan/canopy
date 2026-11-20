import Foundation

/// Namespace kept for the camera type used everywhere.
public enum Calibration {
    public enum CameraPosition: String, Sendable, Codable, CaseIterable {
        case back, front
    }
}

/// How S is computed. Fixed by the T0.0 spike, then never changed without recalibrating.
public enum SignalMethod: String, Sendable, Codable {
    /// A: fixed exposure steps, signal from pixels / exposure.
    case lockedExposure
    /// B: auto-exposure; signal from reported exposure and AE target offset.
    case autoExposure
}

/// Fitted calibration constants (T0.2), loaded from `calibration.json`.
/// Real values only: an empty file means the app shows "not calibrated".
public struct CalibrationConfig: Codable, Equatable, Sendable {
    public struct Diffuser: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct KBase: Codable, Equatable, Sendable {
        public var camera: Calibration.CameraPosition
        public var diffuser: String
        public var value: Double
        /// ISO date of the reference session.
        public var capturedOn: String
        /// How it was fitted, e.g. "median ref lux / S over corpus captures 1–12".
        public var fittedHow: String
        /// Phone case / screen protector state during capture (T0.2).
        public var phoneState: String

        public init(
            camera: Calibration.CameraPosition, diffuser: String, value: Double, capturedOn: String,
            fittedHow: String, phoneState: String
        ) {
            self.camera = camera
            self.diffuser = diffuser
            self.value = value
            self.capturedOn = capturedOn
            self.fittedHow = fittedHow
            self.phoneState = phoneState
        }
    }

    public var version: Int
    /// `hw.machine` of the phone the constants were fitted on (e.g. "iPhone18,3"). nil = none yet.
    public var phoneModel: String?
    /// Chosen by T0.0. nil until the spike is decided.
    public var signalMethod: SignalMethod?
    /// Camera Dad uses; the measure screen's default.
    public var defaultCamera: Calibration.CameraPosition
    public var diffusers: [Diffuser]
    public var kBase: [KBase]
    public var lightTypes: [LightType]
    /// Photone's default light type (T1.2), by id.
    public var defaultLightTypeID: String?

    public init(
        version: Int, phoneModel: String?, signalMethod: SignalMethod?, defaultCamera: Calibration.CameraPosition,
        diffusers: [Diffuser], kBase: [KBase], lightTypes: [LightType], defaultLightTypeID: String?
    ) {
        self.version = version
        self.phoneModel = phoneModel
        self.signalMethod = signalMethod
        self.defaultCamera = defaultCamera
        self.diffusers = diffusers
        self.kBase = kBase
        self.lightTypes = lightTypes
        self.defaultLightTypeID = defaultLightTypeID
    }

    public func kBase(camera: Calibration.CameraPosition, diffuser: String) -> Double? {
        kBase.first { $0.camera == camera && $0.diffuser == diffuser }?.value
    }

    public func lightType(id: String?) -> LightType? {
        guard let id else { return nil }
        return lightTypes.first { $0.id == id }
    }

    public enum Status: Equatable, Sendable {
        case calibrated
        /// No constants fitted yet, or none for this camera + diffuser.
        case notCalibrated
        /// Constants exist but were fitted on a different phone model.
        case otherPhone(fittedOn: String)
    }

    public func status(modelIdentifier: String, camera: Calibration.CameraPosition, diffuser: String) -> Status {
        guard let phoneModel, signalMethod != nil else { return .notCalibrated }
        guard phoneModel == modelIdentifier else { return .otherPhone(fittedOn: phoneModel) }
        return kBase(camera: camera, diffuser: diffuser) == nil ? .notCalibrated : .calibrated
    }

    public static func bundled() throws -> CalibrationConfig {
        guard let url = Bundle.module.url(forResource: "calibration", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(CalibrationConfig.self, from: Data(contentsOf: url))
    }
}

public enum LuxResult: Equatable, Sendable {
    case notCalibrated
    case lux(Double)
}

/// Pipeline step 2: lux = S × kBase.
public func lux(signal: Double, kBase: Double?) -> LuxResult {
    guard let kBase else { return .notCalibrated }
    return .lux(signal * kBase)
}
