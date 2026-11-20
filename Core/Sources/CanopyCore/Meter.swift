import Foundation

public enum PauseReason: String, Sendable, Codable {
    /// Camera interrupted: call, another app took the camera, etc.
    case interrupted
    /// App in background or measure screen not visible.
    case background
    /// thermalState reached .serious (T7.2).
    case hot
}

/// What the meter is doing. Only `.live` readings may be recorded.
public enum ReadingState: Equatable, Sendable, Codable {
    case starting, live, adjusting, tooBright, tooDark
    case paused(PauseReason)
}

/// One camera frame reduced to what the meter needs. Produced by the real camera,
/// by fixtures, and by corpus replay.
public struct MeterFrame: Equatable, Sendable, Codable {
    public var time: Double
    public var stats: FrameStats
    /// Exposure the frame's metadata says it was taken with.
    public var reported: Exposure?
    /// AE metering offset from target, EV (method B).
    public var targetOffsetEV: Double

    public init(time: Double, stats: FrameStats, reported: Exposure?, targetOffsetEV: Double = 0) {
        self.time = time
        self.stats = stats
        self.reported = reported
        self.targetOffsetEV = targetOffsetEV
    }
}

/// Exposure range of the active camera format.
public struct ExposureLimits: Equatable, Sendable, Codable {
    public var minSeconds: Double, maxSeconds: Double, minISO: Double, maxISO: Double
    public init(minSeconds: Double, maxSeconds: Double, minISO: Double, maxISO: Double) {
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.minISO = minISO
        self.maxISO = maxISO
    }
}

/// Turns frames into readings: averaging, exposure stepping (method A), states, pauses.
/// Pure: the camera layer applies the exposure commands it returns.
public struct Meter: Sendable {
    public enum Command: Equatable, Sendable {
        case none
        case setExposure(Exposure)
        case autoExposure
    }

    public struct Reading: Equatable, Sendable {
        public var state: ReadingState
        /// Averaged S, only when live and a full window is available.
        public var signal: Double?
        /// Last good S, shown marked "adjusting" while switching steps. Never shown as live.
        public var held: Double?

        public init(state: ReadingState, signal: Double?, held: Double?) {
            self.state = state
            self.signal = signal
            self.held = held
        }
    }

    public let method: SignalMethod
    public let limits: ExposureLimits
    public let ladder: ExposureLadder
    public private(set) var ladderIndex: Int
    public private(set) var state: ReadingState = .starting
    private var rolling = RollingStats(capacity: Provisional.framesPerReading)
    private var lastGood: Double?
    private var history: [Sample] = []

    struct Sample: Sendable {
        var time: Double
        var signal: Double
    }

    public init(method: SignalMethod, limits: ExposureLimits, startIndex: Int = 0) {
        self.method = method
        self.limits = limits
        ladder = ExposureLadder(
            minSeconds: limits.minSeconds, maxSeconds: limits.maxSeconds,
            minISO: limits.minISO, maxISO: limits.maxISO, stepStops: Provisional.exposureStepStops)
        ladderIndex = min(max(0, startIndex), ladder.steps.count - 1)
    }

    /// Command to apply when (re)starting the camera.
    public var initialCommand: Command {
        method == .lockedExposure ? .setExposure(ladder.steps[ladderIndex]) : .autoExposure
    }

    public var reading: Reading {
        Reading(
            state: state,
            signal: state == .live && rolling.isFull ? rolling.mean : nil,
            held: state == .live ? nil : lastGood)
    }

    /// S values from the last `seconds` of live frames (for the calibration stability check).
    public func recentSignals(seconds: Double) -> [Double] {
        guard let last = history.last?.time else { return [] }
        return history.filter { $0.time >= last - seconds }.map(\.signal)
    }

    public mutating func pause(_ reason: PauseReason) {
        state = .paused(reason)
        rolling.reset()
        history.removeAll()
    }

    /// After a pause: start over so a stale value is never shown as live.
    public mutating func resume() -> Command {
        state = .starting
        rolling.reset()
        history.removeAll()
        return initialCommand
    }

    public mutating func ingest(_ frame: MeterFrame) -> Command {
        if case .paused = state { return .none }
        switch method {
        case .lockedExposure: return ingestLocked(frame)
        case .autoExposure: return ingestAuto(frame)
        }
    }

    private mutating func ingestLocked(_ frame: MeterFrame) -> Command {
        let requested = ladder.steps[ladderIndex]
        guard let reported = frame.reported,
            exposureMatches(
                requested: requested, reported: reported, tolerance: Provisional.exposureMetadataTolerance)
        else {
            if state != .tooBright && state != .tooDark { state = .adjusting }
            return .none
        }
        let mean = frame.stats.meanLinearLuma
        let saturated = frame.stats.saturatedFraction > Provisional.saturatedPixelFractionLimit
        switch ladder.decide(
            current: ladderIndex, meanLinear: mean, saturated: saturated,
            downAbove: Provisional.ladderStepDownAbove, upBelow: Provisional.ladderStepUpBelow)
        {
        case .stay:
            accept(Signal.methodA(meanLinear: mean, exposure: reported), at: frame.time)
            return .none
        case .moveTo(let n):
            ladderIndex = n
            state = .adjusting
            rolling.reset()
            return .setExposure(ladder.steps[n])
        case .tooBright:
            state = .tooBright
            rolling.reset()
        case .tooDark:
            state = .tooDark
            rolling.reset()
        }
        return .none
    }

    private mutating func ingestAuto(_ frame: MeterFrame) -> Command {
        guard let reported = frame.reported else {
            state = .adjusting
            return .none
        }
        let saturated = frame.stats.saturatedFraction > Provisional.saturatedPixelFractionLimit
        let atMinimum = reported.normalized <= limits.minSeconds * limits.minISO / 100 * 1.05
        let atMaximum = reported.normalized >= limits.maxSeconds * limits.maxISO / 100 * 0.95
        if saturated && atMinimum {
            state = .tooBright
            rolling.reset()
        } else if atMaximum && frame.targetOffsetEV < Provisional.autoExposureTooDarkOffsetEV {
            state = .tooDark
            rolling.reset()
        } else if abs(frame.targetOffsetEV) > Provisional.autoExposureSettledOffsetEV {
            state = .adjusting
            rolling.reset()
        } else {
            accept(Signal.methodB(exposure: reported, targetOffsetEV: frame.targetOffsetEV), at: frame.time)
        }
        return .none
    }

    private mutating func accept(_ signal: Double, at time: Double) {
        state = .live
        rolling.add(signal)
        if rolling.isFull, let m = rolling.mean { lastGood = m }
        history.append(Sample(time: time, signal: signal))
        let cutoff = time - 10
        if let first = history.first, first.time < cutoff { history.removeAll { $0.time < cutoff } }
    }
}

/// T7.2: pause measuring when the phone gets hot.
public enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var shouldPause: Bool { self >= .serious }
}
