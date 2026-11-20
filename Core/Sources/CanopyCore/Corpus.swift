import Foundation

/// A capture recorded by the app (spike `capture-NNN.json` format), reduced to what
/// replay needs. Signals are recomputed from stats + metadata, never read back, so a
/// changed definition of S replays correctly.
public struct RecordedCapture: Codable, Sendable {
    public struct Frame: Codable, Sendable {
        public var t: Double
        public var exifSeconds: Double?
        public var exifISO: Double?
        public var targetOffsetEV: Double
        public var stats: FrameStats
        public var dropped: Bool
    }

    public var id: Int
    public var method: String
    public var camera: Calibration.CameraPosition
    public var requestedFPS: Double
    public var frames: [Frame]

    public var meterFrames: [MeterFrame] {
        frames.filter { !$0.dropped }.map { f in
            let exposure = f.exifSeconds.flatMap { s in f.exifISO.map { Exposure(seconds: s, iso: $0) } }
            return MeterFrame(time: f.t, stats: f.stats, reported: exposure, targetOffsetEV: f.targetOffsetEV)
        }
    }
}

/// Reference reading taken with Photone (or a real meter) for one capture.
public struct ReferenceReading: Codable, Equatable, Sendable {
    public var captureID: Int
    public var lux: Double
    public var ppfd: Double?
    /// Photone's light-type setting when the reading was taken.
    public var lightType: String?
    public var diffuser: String
    public var note: String?
    /// Second reference (e.g. borrowed PAR meter), optional.
    public var parMeterPPFD: Double?
}

public enum CorpusReplay {
    /// S for one capture: mean of per-frame signals over usable frames.
    /// Method A frames are used as recorded (exposure was locked), so no ladder logic here.
    public static func signal(_ capture: RecordedCapture, method: SignalMethod) -> Double? {
        let values = capture.meterFrames.compactMap { f -> Double? in
            guard let e = f.reported else { return nil }
            switch method {
            case .lockedExposure:
                guard f.stats.saturatedFraction <= Provisional.saturatedPixelFractionLimit else { return nil }
                return Signal.methodA(meanLinear: f.stats.meanLinearLuma, exposure: e)
            case .autoExposure:
                guard abs(f.targetOffsetEV) <= Provisional.autoExposureSettledOffsetEV else { return nil }
                return Signal.methodB(exposure: e, targetOffsetEV: f.targetOffsetEV)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// kBase fitted as the median of reference lux / S (robust to one bad capture).
    public static func fitKBase(pairs: [(signal: Double, referenceLux: Double)]) -> Double? {
        let ratios = pairs.filter { $0.signal > 0 && $0.referenceLux > 0 }.map { $0.referenceLux / $0.signal }
        return median(ratios)
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }
}

/// T7.1 agreement target check.
public struct AgreementReport: Equatable, Sendable {
    public let relativeErrors: [Double]
    public let median: Double?
    public let max: Double?

    public init(predicted: [Double], reference: [Double]) {
        relativeErrors = zip(predicted, reference).filter { $0.1 > 0 }.map { abs($0.0 - $0.1) / $0.1 }
        median = CorpusReplay.median(relativeErrors)
        max = relativeErrors.max()
    }

    public var passes: Bool {
        guard let median, let max else { return false }
        return median <= Provisional.agreementMedianMaxError && max <= Provisional.agreementSingleMaxError
    }
}
