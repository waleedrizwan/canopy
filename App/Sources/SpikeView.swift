import AVFoundation
import CanopyCore
import SwiftUI
import UIKit

@MainActor @Observable
final class SpikeModel {
    var snapshot = Snapshot()
    var method: SpikeMethod = .a { didSet { restart() } }
    var camera: Calibration.CameraPosition = .back { didSet { restart() } }
    var fps: Double = Provisional.frameRate { didSet { restart() } }
    var saved: [SavedCapture] = []
    var lastMessage: String?
    var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    /// Frames per spike capture: 3 readings' worth, for repeatability.
    let framesPerCapture = Provisional.framesPerReading * 3
    private let engine = CaptureEngine()
    private var running = false

    init() {
        engine.onUpdate = { [weak self] s in Task { @MainActor in self?.snapshot = s } }
        engine.onSaved = { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let cap):
                    self?.saved.insert(cap, at: 0)
                    self?.lastMessage = "Saved #\(cap.id)"
                case .failure(let e):
                    self?.lastMessage = "Save failed: \(e)"
                }
            }
        }
    }

    func appear() async {
        if permission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            permission = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard permission == .authorized else { return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        engine.start(method: method, camera: camera, fps: fps)
    }

    func disappear() {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        engine.stop()
    }

    var isCountingDown = false

    /// Waits so the hand that tapped the button is off the phone before frames are recorded.
    func record() {
        guard !isCountingDown else { return }
        isCountingDown = true
        Task {
            for n in stride(from: 3, through: 1, by: -1) {
                lastMessage = "Hands off… \(n)"
                try? await Task.sleep(for: .seconds(1))
            }
            isCountingDown = false
            lastMessage = "Recording…"
            engine.record(frames: framesPerCapture)
        }
    }

    private func restart() {
        guard running else { return }
        engine.start(method: method, camera: camera, fps: fps)
    }
}

struct SpikeView: View {
    @State private var model = SpikeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.permission == .denied || model.permission == .restricted {
                PermissionDeniedView()
            } else {
                content
            }
        }
        .navigationTitle("T0.0 Spike")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.appear() } } else { model.disappear() }
        }
    }

    private var content: some View {
        let s = model.snapshot
        return List {
            Section {
                Picker("Camera", selection: $model.camera) {
                    Text("Back").tag(Calibration.CameraPosition.back)
                    Text("Front").tag(Calibration.CameraPosition.front)
                }
                Picker("Method", selection: $model.method) {
                    Text("A: locked exposure").tag(SpikeMethod.a)
                    Text("B: auto exposure").tag(SpikeMethod.b)
                }
                Picker("Frame rate", selection: $model.fps) {
                    Text("\(Int(Provisional.frameRate)) fps").tag(Provisional.frameRate)
                    Text("\(Int(Provisional.alternateFrameRate)) fps").tag(Provisional.alternateFrameRate)
                }
            }
            .pickerStyle(.segmented)

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signal S (method \(s.method.rawValue))").font(.caption).foregroundStyle(.secondary)
                    Text(s.signal.map { $0.formatted(.number.precision(.significantDigits(5))) } ?? "—")
                        .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5)
                    Text("State: \(s.state.rawValue)").font(.headline)
                    Text("Lux: not calibrated").foregroundStyle(.secondary)
                }
                row("Variation (CV, last \(Provisional.framesPerReading))", s.cv.map { pct($0) } ?? "—")
            }

            Section {
                Button {
                    model.record()
                } label: {
                    if let p = s.recordingProgress {
                        Text("Recording \(p)/\(model.framesPerCapture)…")
                    } else {
                        Text("Record capture").bold()
                    }
                }
                .disabled(model.isCountingDown || s.recordingProgress != nil || s.state != .live)
                if let m = model.lastMessage {
                    Text(m).font(.title2.bold())
                }
            }

            Section("Recent captures") {
                ForEach(model.saved.prefix(8), id: \.id) { c in
                    VStack(alignment: .leading) {
                        Text("#\(c.id) — \(c.camera.rawValue), method \(c.method.rawValue), \(Int(c.requestedFPS)) fps")
                            .bold()
                        Text("S_A \(num(c.meanSignalA)) (CV \(c.cvSignalA.map(pct) ?? "—"))")
                            .font(.caption).monospacedDigit()
                        Text("S_B \(num(c.meanSignalB)) (CV \(c.cvSignalB.map(pct) ?? "—"))")
                            .font(.caption).monospacedDigit()
                    }
                }
            }

            Section("Details") {
                row("Exposure", s.exposure.map { "1/\(Int((1 / $0.seconds).rounded())) s, ISO \(Int($0.iso))" } ?? "—")
                row("Ladder step", s.ladderIndex.map { "\($0 + 1) of \(s.ladderCount)" } ?? "auto")
                row("Target offset", String(format: "%+.2f EV", s.targetOffsetEV))
                row("EXIF brightness", s.brightnessValue.map { String(format: "%.2f", $0) } ?? "—")
                row("Mean linear luma", s.stats.map { String(format: "%.4f", $0.meanLinearLuma) } ?? "—")
                row("Mean encoded luma", s.stats.map { String(format: "%.4f", $0.meanEncodedLuma) } ?? "—")
                row("Saturated pixels", s.stats.map { pct($0.saturatedFraction) } ?? "—")
                row("Measured fps", String(format: "%.1f", s.measuredFPS))
                row("Dropped frames", "\(s.droppedFrames)")
                row("Format", s.formatDescription)
                if let e = s.error { Text(e).foregroundStyle(.red) }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        LabeledContent(k) { Text(v).monospacedDigit() }
    }

    private func pct(_ v: Double) -> String { String(format: "%.2f%%", v * 100) }
    private func num(_ v: Double?) -> String { v.map { $0.formatted(.number.precision(.significantDigits(5))) } ?? "—" }
}

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Camera access is off").font(.title2.bold())
            Text("This app measures light with the camera. Turn on camera access in Settings to take readings.")
                .multilineTextAlignment(.center)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url).buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
