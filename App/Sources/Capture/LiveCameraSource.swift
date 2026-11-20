@preconcurrency import AVFoundation
import CanopyCore
import Foundation

/// The real camera (T0.1). Session work happens on `queue`; callbacks hop to the main actor.
@MainActor
final class LiveCameraSource: NSObject, CameraSource {
    var onFrame: ((MeterFrame) -> Void)?
    var onInterruption: ((Bool) -> Void)?

    private let worker = CaptureWorker()

    override init() {
        super.init()
        worker.onFrame = { [weak self] frame in
            Task { @MainActor in self?.onFrame?(frame) }
        }
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification,
            object: worker.session)
        center.addObserver(
            self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification,
            object: worker.session)
        center.addObserver(
            self, selector: #selector(interrupted), name: AVCaptureSession.runtimeErrorNotification,
            object: worker.session)
    }

    @objc nonisolated private func interrupted() {
        Task { @MainActor in self.onInterruption?(true) }
    }

    @objc nonisolated private func interruptionEnded() {
        Task { @MainActor in self.onInterruption?(false) }
    }

    func start(camera: Calibration.CameraPosition, onReady: @escaping @MainActor @Sendable (ExposureLimits) -> Void) {
        worker.start(camera: camera) { limits in
            Task { @MainActor in onReady(limits) }
        }
    }

    func stop() { worker.stop() }

    func apply(_ command: Meter.Command) { worker.apply(command) }
}

/// AVFoundation side. All mutable state is confined to `queue`.
private final class CaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    var onFrame: (@Sendable (MeterFrame) -> Void)?

    func start(camera: Calibration.CameraPosition, onReady: @escaping @Sendable (ExposureLimits) -> Void) {
        queue.async { [self] in
            guard let limits = try? configure(camera) else { return }
            if !session.isRunning { session.startRunning() }
            onReady(limits)
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func apply(_ command: Meter.Command) {
        queue.async { [self] in
            guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
            defer { dev.unlockForConfiguration() }
            switch command {
            case .none: break
            case .setExposure(let e):
                dev.setExposureModeCustom(
                    duration: CMTime(seconds: e.seconds, preferredTimescale: 1_000_000_000),
                    iso: Float(e.iso), completionHandler: nil)
            case .autoExposure:
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.setExposureTargetBias(0, completionHandler: nil)
            }
        }
    }

    private func configure(_ camera: Calibration.CameraPosition) throws -> ExposureLimits {
        let position: AVCaptureDevice.Position = camera == .back ? .back : .front
        // Single physical lens, never a virtual multi-lens device.
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw SpikeError.noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        if dev != device {
            if let input { session.removeInput(input) }
            let newInput = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(newInput) else { throw SpikeError.cannotAddInput }
            session.addInput(newInput)
            input = newInput
            device = dev
        }
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw SpikeError.cannotAddOutput }
            session.addOutput(output)
        }
        if let conn = output.connection(with: .video), conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = .off
        }
        let format = try CameraFormat.pick(dev, fps: Provisional.frameRate)
        try dev.lockForConfiguration()
        defer { dev.unlockForConfiguration() }
        CameraFormat.apply(format, to: dev, fps: Provisional.frameRate)
        return ExposureLimits(
            minSeconds: format.minExposureDuration.seconds,
            maxSeconds: min(1 / Provisional.frameRate, format.maxExposureDuration.seconds),
            minISO: Double(format.minISO), maxISO: Double(format.maxISO))
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let dev = device else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stats = FrameAnalyzer.analyzeBGRA(
            base: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), border: Provisional.frameBorderFraction)
        let frame = MeterFrame(
            time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, stats: stats,
            reported: CameraFormat.exif(sampleBuffer).exposure, targetOffsetEV: Double(dev.exposureTargetOffset))
        onFrame?(frame)
    }
}

/// Format choice and the "turn off everything automatic" settings, shared with the spike.
enum CameraFormat {
    static func pick(_ dev: AVCaptureDevice, fps: Double) throws -> AVCaptureDevice.Format {
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
        guard
            let best = candidates.min(by: { a, b in
                if a.isVideoHDRSupported != b.isVideoHDRSupported { return !a.isVideoHDRSupported }
                return a.maxISO / a.minISO > b.maxISO / b.minISO
            })
        else { throw SpikeError.noFormat }
        return best
    }

    /// Call with the device locked for configuration.
    static func apply(_ format: AVCaptureDevice.Format, to dev: AVCaptureDevice, fps: Double) {
        dev.activeFormat = format
        let frameDuration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
        dev.activeVideoMinFrameDuration = frameDuration
        dev.activeVideoMaxFrameDuration = frameDuration
        if format.isVideoHDRSupported {
            dev.automaticallyAdjustsVideoHDREnabled = false
            dev.isVideoHDREnabled = false
        }
        if dev.isLowLightBoostSupported { dev.automaticallyEnablesLowLightBoostWhenAvailable = false }
        if format.isGlobalToneMappingSupported { dev.isGlobalToneMappingEnabled = false }
        if dev.isFocusModeSupported(.locked), dev.isLockingFocusWithCustomLensPositionSupported {
            dev.setFocusModeLocked(lensPosition: 0.5, completionHandler: nil)
        }
        let g = Provisional.whiteBalanceGains
        let maxG = Double(dev.maxWhiteBalanceGain)
        func clamp(_ v: Double) -> Float { Float(min(max(v, 1), maxG)) }
        if dev.isWhiteBalanceModeSupported(.locked) {
            dev.setWhiteBalanceModeLocked(
                with: .init(redGain: clamp(g.red), greenGain: clamp(g.green), blueGain: clamp(g.blue)),
                completionHandler: nil)
        }
    }

    static func exif(_ sb: CMSampleBuffer) -> FrameExif {
        guard
            let att = CMCopyDictionaryOfAttachments(
                allocator: nil, target: sb, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any],
            let exif = att[kCGImagePropertyExifDictionary as String] as? [String: Any]
        else { return FrameExif() }
        return FrameExif(
            seconds: (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue,
            brightness: (exif[kCGImagePropertyExifBrightnessValue as String] as? NSNumber)?.doubleValue)
    }
}
