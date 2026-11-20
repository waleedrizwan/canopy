import Testing

@testable import CanopyCore

@Suite struct FrameAnalyzerTests {
    @Test func cropRectDropsTenPercentBorder() {
        let r = FrameAnalyzer.cropRect(width: 100, height: 50, border: 0.10)
        #expect(r.x0 == 10 && r.x1 == 90 && r.y0 == 5 && r.y1 == 45)
    }

    private func analyze(_ buf: [UInt8], width w: Int, height h: Int) throws -> FrameStats {
        let stats = buf.withUnsafeBytes { raw in
            raw.baseAddress.map {
                FrameAnalyzer.analyzeBGRA(base: $0, width: w, height: h, bytesPerRow: w * 4, border: 0.1, step: 1)
            }
        }
        return try #require(stats)
    }

    @Test func uniformFrameMeans() throws {
        let w = 40, h = 20
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: buf.count, by: 4) {
            buf[i] = 50; buf[i + 1] = 100; buf[i + 2] = 200; buf[i + 3] = 255
        }
        let s = try analyze(buf, width: w, height: h)
        #expect(s.sampleCount == 32 * 16)
        #expect(abs(s.meanLinearR - FrameAnalyzer.linearLUT[200]) < 1e-12)
        #expect(abs(s.meanLinearB - FrameAnalyzer.linearLUT[50]) < 1e-12)
        #expect(s.saturatedFraction == 0)
    }

    @Test func borderPixelsIgnored() throws {
        let w = 10, h = 10
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        // Bright 1-pixel border only.
        for y in 0..<h {
            for x in 0..<w where x == 0 || y == 0 || x == w - 1 || y == h - 1 {
                for c in 0..<3 { buf[(y * w + x) * 4 + c] = 255 }
            }
        }
        let s = try analyze(buf, width: w, height: h)
        #expect(s.meanLinearLuma == 0 && s.saturatedFraction == 0)
    }

    @Test func linearLUTEndpoints() {
        #expect(FrameAnalyzer.linearLUT[0] == 0)
        #expect(abs(FrameAnalyzer.linearLUT[255] - 1) < 1e-12)
    }
}

@Suite struct ExposureTests {
    let ladder = ExposureLadder(minSeconds: 1.0 / 8000, maxSeconds: 1.0 / 30, minISO: 50, maxISO: 1600, stepStops: 1)

    @Test func ladderIsOneStopApart() {
        for (a, b) in zip(ladder.steps, ladder.steps.dropFirst()) {
            #expect(abs(a.normalized / b.normalized - 2) < 1e-9)
        }
        #expect(ladder.steps.first == Exposure(seconds: 1.0 / 30, iso: 1600))
    }

    @Test func hysteresisDoesNotOscillateOnBoundary() {
        // Sit exactly on the step-down boundary: moves once, then lands in dead band and stays.
        var idx = 5
        var mean = 0.61
        for _ in 0..<10 {
            switch ladder.decide(current: idx, meanLinear: mean, saturated: false, downAbove: 0.6, upBelow: 0.1) {
            case .moveTo(let n):
                mean *= n > idx ? 0.5 : 2
                idx = n
            default: break
            }
        }
        #expect(idx == 6)
    }

    @Test func endsReportTooBrightTooDark() {
        let last = ladder.steps.count - 1
        #expect(
            ladder.decide(current: last, meanLinear: 0.9, saturated: false, downAbove: 0.6, upBelow: 0.1) == .tooBright)
        #expect(ladder.decide(current: 0, meanLinear: 0.01, saturated: false, downAbove: 0.6, upBelow: 0.1) == .tooDark)
    }

    @Test func mismatchedMetadataRejected() {
        let req = Exposure(seconds: 0.01, iso: 100)
        #expect(exposureMatches(requested: req, reported: Exposure(seconds: 0.0102, iso: 100), tolerance: 0.1))
        #expect(!exposureMatches(requested: req, reported: Exposure(seconds: 0.02, iso: 100), tolerance: 0.1))
        #expect(!exposureMatches(requested: req, reported: Exposure(seconds: 0.01, iso: 200), tolerance: 0.1))
    }

    @Test func methodANormalisation() {
        // 0.2 linear at 1/100 s, ISO 200 → 0.2 / (0.01 * 2) = 10
        #expect(abs(Signal.methodA(meanLinear: 0.2, exposure: Exposure(seconds: 0.01, iso: 200)) - 10) < 1e-9)
    }

    @Test func methodBOffset() {
        let e = Exposure(seconds: 0.01, iso: 100)
        #expect(
            abs(Signal.methodB(exposure: e, targetOffsetEV: 1) / Signal.methodB(exposure: e, targetOffsetEV: 0) - 2)
                < 1e-9)
    }

    @Test func constantInputHasTinyVariance() {
        var r = RollingStats(capacity: 10)
        for _ in 0..<20 { r.add(42) }
        #expect(r.isFull && r.mean == 42 && r.coefficientOfVariation == 0)
    }
}

@Suite struct CalibrationTests {
    @Test func noCalibrationMeansNotCalibrated() throws {
        let config = try CalibrationConfig.bundled()
        #expect(lux(signal: 5, kBase: config.kBase(camera: .back, diffuser: "none")) == .notCalibrated)
        #expect(lux(signal: 5, kBase: 2) == .lux(10))
        #expect(config.status(modelIdentifier: "iPhone18,3", camera: .back, diffuser: "none") == .notCalibrated)
    }

    /// T0.2: every (camera, diffuser) pair the UI can offer has a kBase, once anything is calibrated.
    @Test func bundledConfigLoadsAndIsConsistent() throws {
        let config = try CalibrationConfig.bundled()
        #expect(config.version == 1)
        #expect(config.diffusers.contains { $0.id == "none" })
        if config.phoneModel != nil {
            for camera in Calibration.CameraPosition.allCases {
                for d in config.diffusers {
                    #expect(config.kBase(camera: camera, diffuser: d.id) != nil, "\(camera) + \(d.id) has no kBase")
                }
            }
        }
        for k in config.kBase {
            #expect(k.value > 0 && !k.capturedOn.isEmpty && !k.fittedHow.isEmpty)
        }
    }

    @Test func otherPhoneDetected() {
        let config = CalibrationConfig(
            version: 1, phoneModel: "iPhone18,3", signalMethod: .lockedExposure, defaultCamera: .back,
            diffusers: [.init(id: "none", name: "No diffuser")],
            kBase: [.init(camera: .back, diffuser: "none", value: 2, capturedOn: "x", fittedHow: "x", phoneState: "x")],
            lightTypes: [], defaultLightTypeID: nil)
        #expect(config.status(modelIdentifier: "iPhone18,3", camera: .back, diffuser: "none") == .calibrated)
        #expect(config.status(modelIdentifier: "iPhone18,3", camera: .front, diffuser: "none") == .notCalibrated)
        #expect(
            config.status(modelIdentifier: "iPhone15,2", camera: .back, diffuser: "none")
                == .otherPhone(fittedOn: "iPhone18,3"))
    }
}
