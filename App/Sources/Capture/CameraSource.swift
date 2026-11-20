import CanopyCore
import Foundation

/// Where frames come from: the real camera, or a fixture for the simulator and UI tests.
@MainActor
protocol CameraSource: AnyObject {
    /// Called on the main actor for every frame.
    var onFrame: ((MeterFrame) -> Void)? { get set }
    /// true when the camera is interrupted (call, other app), false when it comes back.
    var onInterruption: ((Bool) -> Void)? { get set }
    /// Starts the camera and reports the exposure range of the chosen format.
    func start(camera: Calibration.CameraPosition, onReady: @escaping @MainActor @Sendable (ExposureLimits) -> Void)
    func stop()
    func apply(_ command: Meter.Command)
}

/// Simulated camera: a steady light of signal `S`, responding to exposure commands
/// the way a linear sensor would (clipping at full scale).
@MainActor
final class FixtureCameraSource: CameraSource {
    var onFrame: ((MeterFrame) -> Void)?
    var onInterruption: ((Bool) -> Void)?

    static let limits = ExposureLimits(minSeconds: 1.0 / 8000, maxSeconds: 1.0 / 27, minISO: 50, maxISO: 1600)

    /// Scene brightness in units of S.
    var signal: Double
    private var exposure = Exposure(seconds: 1.0 / 100, iso: 100)
    private var autoExposure = false
    private var timer: Timer?
    private var time = 0.0

    init(signal: Double) {
        self.signal = signal
    }

    func start(camera: Calibration.CameraPosition, onReady: @escaping @MainActor @Sendable (ExposureLimits) -> Void) {
        onReady(Self.limits)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Provisional.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func apply(_ command: Meter.Command) {
        switch command {
        case .none: break
        case .setExposure(let e):
            autoExposure = false
            exposure = e
        case .autoExposure:
            autoExposure = true
        }
    }

    private func emit() {
        time += 1 / Provisional.frameRate
        let linear = signal * exposure.normalized
        let clipped = min(1, linear)
        let stats = FrameStats(
            meanEncodedLuma: clipped, meanLinearR: clipped, meanLinearG: clipped, meanLinearB: clipped,
            saturatedFraction: linear >= 0.95 ? 1 : 0, sampleCount: 1000)
        onFrame?(MeterFrame(time: time, stats: stats, reported: exposure, targetOffsetEV: 0))
    }
}
