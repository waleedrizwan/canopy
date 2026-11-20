import CanopyCore
import CoreMotion
import Foundation
import Observation

/// Owns the camera source and the meter. Runs only while a measuring screen is visible.
@MainActor @Observable
final class MeasureModel {
    private(set) var reading = Meter.Reading(state: .starting, signal: nil, held: nil)
    private(set) var tiltDegrees: Double?
    private(set) var firstReadingSeconds: Double?
    /// Frozen value (hold button), nil when live.
    var frozenSignal: Double?

    var camera: Calibration.CameraPosition = .back {
        didSet { if oldValue != camera, isRunning { restart() } }
    }

    var tiltWarning: Bool { tiltDegrees.map { isTiltWarning(degrees: $0) } ?? false }

    /// What the heatmap and calibration may record from: live, level, not frozen.
    var canRecord: Bool { reading.state == .live && reading.signal != nil && !tiltWarning }

    private let source: CameraSource
    private let method: SignalMethod
    private var meter: Meter?
    private var visibleScreens: Set<String> = []
    private var appActive = true
    private var interrupted = false
    private var thermal: ThermalLevel = .nominal
    private var startedAt: Date?
    private let motion = CMMotionManager()

    init(source: CameraSource, method: SignalMethod) {
        self.source = source
        self.method = method
        source.onFrame = { [weak self] frame in self?.ingest(frame) }
        source.onInterruption = { [weak self] isInterrupted in self?.setInterrupted(isInterrupted) }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThermal() }
        }
        updateThermal()
    }

    private var isRunning: Bool { !visibleScreens.isEmpty && appActive }

    // MARK: lifecycle

    func setVisible(_ screen: String, _ visible: Bool) {
        let was = isRunning
        if visible { visibleScreens.insert(screen) } else { visibleScreens.remove(screen) }
        if isRunning != was { applyRunning() }
    }

    func setAppActive(_ active: Bool) {
        let was = isRunning
        appActive = active
        if isRunning != was { applyRunning() }
    }

    private func applyRunning() {
        if isRunning {
            restart()
        } else {
            halt(.background)
        }
    }

    private func restart() {
        meter = nil
        reading = Meter.Reading(state: .starting, signal: nil, held: nil)
        startedAt = Date()
        firstReadingSeconds = nil
        startMotion()
        source.start(camera: camera) { [weak self] limits in
            guard let self, self.isRunning else { return }
            var m = Meter(method: self.method, limits: limits, startIndex: 0)
            if self.thermal.shouldPause { m.pause(.hot) }
            if self.interrupted { m.pause(.interrupted) }
            self.meter = m
            self.reading = m.reading
            self.source.apply(m.initialCommand)
        }
    }

    private func halt(_ reason: PauseReason) {
        source.stop()
        motion.stopDeviceMotionUpdates()
        meter?.pause(reason)
        reading = Meter.Reading(state: .paused(reason), signal: nil, held: nil)
    }

    private func setInterrupted(_ isOn: Bool) {
        interrupted = isOn
        guard var m = meter else { return }
        if isOn {
            m.pause(.interrupted)
        } else if !thermal.shouldPause {
            source.apply(m.resume())
        }
        meter = m
        reading = m.reading
    }

    private func updateThermal() {
        thermal =
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .serious
            }
        guard var m = meter else { return }
        if thermal.shouldPause {
            m.pause(.hot)
        } else if case .paused(.hot) = m.state, !interrupted {
            source.apply(m.resume())
        }
        meter = m
        reading = m.reading
    }

    // MARK: frames

    private func ingest(_ frame: MeterFrame) {
        guard var m = meter else { return }
        let command = m.ingest(frame)
        meter = m
        if command != .none { source.apply(command) }
        let r = m.reading
        if r != reading { reading = r }
        if firstReadingSeconds == nil, r.signal != nil, let t = startedAt {
            firstReadingSeconds = Date().timeIntervalSince(t)
        }
    }

    /// S values over the stability window, for user calibration (T2.2).
    func recentSignals() -> [Double] {
        meter?.recentSignals(seconds: Provisional.calibrationStabilityWindowSeconds) ?? []
    }

    // MARK: tilt (T1.1)

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                // Measuring orientation: the chosen camera pointing straight up at the light.
                let reference = self.camera == .back ? Vector3(0, 0, 1) : Vector3(0, 0, -1)
                self.tiltDegrees = CanopyCore.tiltDegrees(gravity: Vector3(g.x, g.y, g.z), reference: reference)
            }
        }
    }
}
