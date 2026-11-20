import CanopyCore
import Foundation
import Observation

/// Launch options used by UI tests and simulator runs.
struct LaunchOptions {
    /// Use a simulated camera with this scene signal instead of the real camera.
    var fixtureSignal: Double?
    /// Use the test calibration (clearly fake numbers) instead of calibration.json.
    var testCalibration = false
    /// Start with empty saved data.
    var resetData = false

    static func parse(_ args: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        if let i = args.firstIndex(of: "-fixtureSignal"), i + 1 < args.count {
            options.fixtureSignal = Double(args[i + 1])
        }
        options.testCalibration = args.contains("-testCalibration")
        options.resetData = args.contains("-resetData")
        return options
    }
}

/// Values shown on the measure screen, all derived from one reading.
struct DisplayValues {
    var status: CalibrationConfig.Status
    var signal: Double?
    var lux: Lux?
    /// PPFD before the user's calibration multiplier (for T2.2).
    var uncalibratedPPFD: PPFD?
    var ppfd: PPFD?
    var dli: DLI?
    var kBase: Double?
    var fLight: Double?
    var kUser: Double
    var lightType: LightType?
    var lightTypeIsDefault: Bool
}

@MainActor @Observable
final class AppModel {
    let config: CalibrationConfig
    let modelIdentifier: String
    let measure: MeasureModel
    let usesLiveCamera: Bool
    private let store: VersionedFileStore
    private(set) var saveError: String?

    var data: AppData {
        didSet { persist() }
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let options = LaunchOptions.parse(arguments)
        modelIdentifier = DeviceInfo.modelIdentifier
        if options.testCalibration {
            config = TestFixtures.calibration(phoneModel: DeviceInfo.modelIdentifier)
        } else {
            config = (try? CalibrationConfig.bundled()) ?? TestFixtures.emptyCalibration
        }
        store = VersionedFileStore(url: Self.dataURL())
        if options.resetData { try? FileManager.default.removeItem(at: store.url) }
        let loaded = (try? store.loadAppData()) ?? nil
        var initial = loaded ?? AppData()
        if loaded == nil { initial.settings.camera = config.defaultCamera }
        data = initial
        usesLiveCamera = options.fixtureSignal == nil
        let source: CameraSource =
            options.fixtureSignal.map { FixtureCameraSource(signal: $0) } ?? LiveCameraSource()
        measure = MeasureModel(source: source, method: config.signalMethod ?? .lockedExposure)
        measure.camera = initial.settings.camera
    }

    static func dataURL() -> URL {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("canopy/data.json")
    }

    private func persist() {
        do {
            try store.save(data)
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: settings helpers

    var settings: AppSettings {
        get { data.settings }
        set {
            data.settings = newValue
            measure.camera = newValue.camera
        }
    }

    var availableLightTypes: [LightType] {
        config.lightTypes.filter { $0.reef == data.settings.reefMode }
    }

    var activeLightType: (type: LightType, isDefault: Bool)? {
        if let t = config.lightType(id: data.settings.activeLightTypeID) { return (t, false) }
        if !data.settings.reefMode, let t = config.lightType(id: config.defaultLightTypeID) { return (t, true) }
        return nil
    }

    var setupKey: SetupKey? {
        activeLightType.map {
            SetupKey(camera: data.settings.camera, diffuser: data.settings.diffuserID, lightType: $0.type.id)
        }
    }

    var diffuserName: String {
        config.diffusers.first { $0.id == data.settings.diffuserID }?.name ?? data.settings.diffuserID
    }

    // MARK: pipeline

    func values(signal: Double?) -> DisplayValues {
        let s = data.settings
        let status = config.status(modelIdentifier: modelIdentifier, camera: s.camera, diffuser: s.diffuserID)
        let kBase = status == .calibrated ? config.kBase(camera: s.camera, diffuser: s.diffuserID) : nil
        let light = activeLightType
        let kUser = setupKey.map { data.calibrations.kUser(for: $0) } ?? 1
        var v = DisplayValues(
            status: status, signal: signal, kBase: kBase, fLight: light?.type.fLight, kUser: kUser,
            lightType: light?.type, lightTypeIsDefault: light?.isDefault ?? false)
        guard let signal, let kBase else { return v }
        let lux = Lux(signal * kBase)
        v.lux = lux
        guard let fLight = light?.type.fLight else { return v }
        v.uncalibratedPPFD = Pipeline.ppfd(lux: lux, fLight: fLight)
        let ppfd = Pipeline.ppfd(lux: lux, fLight: fLight, kUser: kUser)
        v.ppfd = ppfd
        if let period = try? Photoperiod(hours: s.photoperiodHours) {
            v.dli = Pipeline.dli(ppfd: ppfd, photoperiod: period)
        }
        return v
    }

    /// T4.1: snapshot the current reading into the log.
    @discardableResult
    func saveToLog(_ v: DisplayValues, label: String?, note: String?) -> Bool {
        guard let lux = v.lux, let ppfd = v.ppfd, let dli = v.dli, let kBase = v.kBase, let fLight = v.fLight,
            let signal = v.signal, let light = v.lightType
        else { return false }
        data.log.add(
            LogEntry(
                timestamp: Date(), lux: lux, ppfd: ppfd, dli: dli, photoperiodHours: data.settings.photoperiodHours,
                lightType: light.name, diffuser: data.settings.diffuserID, camera: data.settings.camera,
                kBase: kBase, fLight: fLight, kUser: v.kUser, rawSignal: signal,
                label: label?.nilIfBlank, note: note?.nilIfBlank))
        return true
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

enum DeviceInfo {
    /// e.g. "iPhone18,3". In the simulator, the simulated model.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }
    }
}

/// Fake calibration for UI tests and simulator runs only. Never shipped as real numbers:
/// it is selected only by the `-testCalibration` launch argument.
enum TestFixtures {
    static let emptyCalibration = CalibrationConfig(
        version: 1, phoneModel: nil, signalMethod: nil, defaultCamera: .back,
        diffusers: [.init(id: "none", name: "No diffuser")], kBase: [], lightTypes: [], defaultLightTypeID: nil)

    static func calibration(phoneModel: String) -> CalibrationConfig {
        let k = { (c: Calibration.CameraPosition) in
            CalibrationConfig.KBase(
                camera: c, diffuser: "none", value: 100, capturedOn: "test", fittedHow: "UI test fixture",
                phoneState: "test")
        }
        return CalibrationConfig(
            version: 1, phoneModel: phoneModel, signalMethod: .lockedExposure, defaultCamera: .back,
            diffusers: [.init(id: "none", name: "No diffuser")], kBase: [k(.back), k(.front)],
            lightTypes: [
                LightType(
                    id: "test-led", name: "Test LED", group: "LED", fLight: 0.02, origin: .measured(captureDate: "test")
                ),
                LightType(
                    id: "test-hps", name: "Test HPS", group: "HID", fLight: 0.0125, origin: .published(citation: "test")
                ),
            ],
            defaultLightTypeID: "test-led")
    }
}
