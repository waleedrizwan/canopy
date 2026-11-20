@preconcurrency import AVFoundation
import CanopyCore
import Foundation

/// Owns the AVCaptureSession. All mutable state is confined to `queue`.
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?

    private var method: SpikeMethod = .a
    private var camera: Calibration.CameraPosition = .back
    private var fps: Double = Provisional.frameRate
    private var ladder: ExposureLadder?
    private var ladderIndex = 0
    private var rolling = RollingStats(capacity: Provisional.framesPerReading)
    private var state: MeterState = .stopped
    private var dropped = 0
    private var lastPTS: Double?
    private var fpsEstimate = 0.0
    private var frameCounter = 0
    private var formatDescription = ""

    private var recordTarget = 0
    private var recordFrames: [FrameRecord] = []
    private var recordRaw: (Data, SavedCapture.RawFrameInfo)?

    var onUpdate: (@Sendable (Snapshot) -> Void)?
    var onSaved: (@Sendable (Result<SavedCapture, Error>) -> Void)?

    // MARK: control

    func start(method: SpikeMethod, camera: Calibration.CameraPosition, fps: Double) {
        queue.async { [self] in
            self.method = method
            self.camera = camera
            self.fps = fps
            do {
                try configure()
                if !session.isRunning { session.startRunning() }
                state = .starting
            } catch {
                publish(error: "\(error)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            state = .stopped
            recordTarget = 0
            recordFrames = []
            publish()
        }
    }

    func record(frames: Int) {
        queue.async { [self] in
            recordFrames = []
            recordRaw = nil
            recordTarget = frames
        }
    }
}

// MARK: configuration

extension CaptureEngine {
    private func configure() throws {
        let position: AVCaptureDevice.Position = camera == .back ? .back : .front
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw SpikeError.noCamera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try configureSession(dev)

        let format = try pickFormat(dev, fps: fps)
        try dev.lockForConfiguration()
        defer { dev.unlockForConfiguration() }
        configureDevice(dev, format: format)
        configureExposure(dev, format: format)

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        formatDescription =
            "\(dims.width)x\(dims.height) @\(Int(fps))fps ISO \(Int(format.minISO))–\(Int(format.maxISO))"
            + " f/\(dev.lensAperture)"
        rolling.reset()
        dropped = 0
        lastPTS = nil
    }

    private func configureSession(_ dev: AVCaptureDevice) throws {
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
    }

    /// Frame rate, automatic processing off, fixed white balance, fixed focus.
    /// Call with the device locked for configuration.
    private func configureDevice(_ dev: AVCaptureDevice, format: AVCaptureDevice.Format) {
        dev.activeFormat = format
        let frameDuration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
        dev.activeVideoMinFrameDuration = frameDuration
        dev.activeVideoMaxFrameDuration = frameDuration
        if format.isVideoHDRSupported {
            dev.automaticallyAdjustsVideoHDREnabled = false
            dev.isVideoHDREnabled = false
        }
        if dev.isLowLightBoostSupported {
            dev.automaticallyEnablesLowLightBoostWhenAvailable = false
        }
        if format.isGlobalToneMappingSupported {
            dev.isGlobalToneMappingEnabled = false
        }
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

    /// Call with the device locked for configuration.
    private func configureExposure(_ dev: AVCaptureDevice, format: AVCaptureDevice.Format) {
        let maxSeconds = min(1 / fps, format.maxExposureDuration.seconds)
        ladder = ExposureLadder(
            minSeconds: format.minExposureDuration.seconds, maxSeconds: maxSeconds,
            minISO: Double(format.minISO), maxISO: Double(format.maxISO),
            stepStops: Provisional.exposureStepStops)
        switch method {
        case .a:
            ladderIndex = min(ladderIndex, (ladder?.steps.count ?? 1) - 1)
            applyLadderStep(dev)
        case .b:
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }
            dev.setExposureTargetBias(0, completionHandler: nil)
        }
    }

    private func pickFormat(_ dev: AVCaptureDevice, fps: Double) throws -> AVCaptureDevice.Format {
        let candidates = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080
                && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
        // Prefer formats without HDR and with the widest ISO range.
        guard
            let best = candidates.min(by: { a, b in
                if a.isVideoHDRSupported != b.isVideoHDRSupported { return !a.isVideoHDRSupported }
                return a.maxISO / a.minISO > b.maxISO / b.minISO
            })
        else { throw SpikeError.noFormat }
        return best
    }

    /// Call with the device locked for configuration.
    private func applyLadderStep(_ dev: AVCaptureDevice) {
        guard let step = ladder?.steps[ladderIndex] else { return }
        dev.setExposureModeCustom(
            duration: CMTime(seconds: step.seconds, preferredTimescale: 1_000_000_000),
            iso: Float(step.iso), completionHandler: nil)
    }
}

// MARK: frames

extension CaptureEngine {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let dev = device else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if let last = lastPTS, pts > last { fpsEstimate = 0.9 * fpsEstimate + 0.1 * (1 / (pts - last)) }
        lastPTS = pts

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let stats = FrameAnalyzer.analyzeBGRA(
            base: base, width: w, height: h, bytesPerRow: bpr, border: Provisional.frameBorderFraction)

        let exif = Self.exif(sampleBuffer)
        let offset = Double(dev.exposureTargetOffset)
        var record = FrameRecord(
            t: pts, exifSeconds: exif.seconds, exifISO: exif.iso, exifBrightness: exif.brightness,
            targetOffsetEV: offset, stats: stats, dropped: false)

        let signal: Double? =
            switch method {
            case .a: processMethodA(&record, reported: exif.exposure, dev: dev)
            case .b: processMethodB(&record, reported: exif.exposure, dev: dev)
            }
        if let signal, state == .live { rolling.add(signal) }

        if recordTarget > 0 {
            let info = SavedCapture.RawFrameInfo(file: "", width: w, height: h, bytesPerRow: bpr, pixelFormat: "BGRA8")
            appendToRecording(record, base: base, info: info, dev: dev)
        }
        frameCounter += 1
        if frameCounter % 3 == 0 {
            publish(stats: stats, reported: exif.exposure, brightness: exif.brightness, offset: offset)
        }
    }

    /// Locked exposure: drop frames whose metadata doesn't match, then step the ladder if needed.
    private func processMethodA(_ record: inout FrameRecord, reported: Exposure?, dev: AVCaptureDevice) -> Double? {
        guard let ladder else { return nil }
        let requested = ladder.steps[ladderIndex]
        record.requestedSeconds = requested.seconds
        record.requestedISO = requested.iso
        record.ladderIndex = ladderIndex
        guard let reported,
            exposureMatches(requested: requested, reported: reported, tolerance: Provisional.exposureMetadataTolerance)
        else {
            dropped += 1
            record.dropped = true
            if state != .tooBright && state != .tooDark { state = .adjusting }
            return nil
        }
        let mean = record.stats.meanLinearLuma
        let saturated = record.stats.saturatedFraction > Provisional.saturatedPixelFractionLimit
        record.signalA = Signal.methodA(meanLinear: mean, exposure: reported)
        let decision = ladder.decide(
            current: ladderIndex, meanLinear: mean, saturated: saturated,
            downAbove: Provisional.ladderStepDownAbove, upBelow: Provisional.ladderStepUpBelow)
        switch decision {
        case .stay:
            state = .live
            return record.signalA
        case .moveTo(let n):
            ladderIndex = n
            state = .adjusting
            rolling.reset()
            if (try? dev.lockForConfiguration()) != nil {
                applyLadderStep(dev)
                dev.unlockForConfiguration()
            }
        case .tooBright:
            state = .tooBright
        case .tooDark:
            state = .tooDark
        }
        return nil
    }

    /// Auto exposure: the reported settings plus AE's target offset are the reading.
    private func processMethodB(_ record: inout FrameRecord, reported: Exposure?, dev: AVCaptureDevice) -> Double? {
        guard let reported else {
            dropped += 1
            record.dropped = true
            return nil
        }
        record.signalA = Signal.methodA(meanLinear: record.stats.meanLinearLuma, exposure: reported)
        record.signalB = Signal.methodB(exposure: reported, targetOffsetEV: record.targetOffsetEV)
        let saturated = record.stats.saturatedFraction > Provisional.saturatedPixelFractionLimit
        state = saturated && dev.iso <= dev.activeFormat.minISO * 1.01 ? .tooBright : .live
        return record.signalB
    }

    private func appendToRecording(
        _ record: FrameRecord, base: UnsafeMutableRawPointer, info: SavedCapture.RawFrameInfo, dev: AVCaptureDevice
    ) {
        recordFrames.append(record)
        if recordRaw == nil, !record.dropped {
            recordRaw = (Data(bytes: base, count: info.bytesPerRow * info.height), info)
        }
        let good = recordFrames.filter { !$0.dropped }.count
        guard good >= recordTarget || recordFrames.count >= recordTarget * 4 else { return }
        let frames = recordFrames
        let raw = recordRaw
        let settings = CaptureSettings(
            method: method, camera: camera, fps: fps, format: formatDescription,
            lensAperture: Double(dev.lensAperture))
        recordTarget = 0
        recordFrames = []
        recordRaw = nil
        Task.detached { [onSaved] in
            onSaved?(Result { try SpikeStore.save(frames: frames, raw: raw, settings: settings) })
        }
    }

    private static func exif(_ sb: CMSampleBuffer) -> FrameExif {
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

    // MARK: publishing

    private func publish(
        stats: FrameStats? = nil, reported: Exposure? = nil, brightness: Double? = nil,
        offset: Double = 0, error: String? = nil
    ) {
        var s = Snapshot()
        s.state = state
        s.method = method
        s.camera = camera
        s.signal = state == .live && rolling.isFull ? rolling.mean : nil
        s.cv = rolling.coefficientOfVariation
        s.exposure = reported
        s.targetOffsetEV = offset
        s.brightnessValue = brightness
        s.ladderIndex = method == .a ? ladderIndex : nil
        s.ladderCount = ladder?.steps.count ?? 0
        s.stats = stats
        s.measuredFPS = fpsEstimate
        s.droppedFrames = dropped
        s.recordingProgress = recordTarget > 0 ? recordFrames.filter { !$0.dropped }.count : nil
        s.formatDescription = formatDescription
        s.error = error
        onUpdate?(s)
    }
}
