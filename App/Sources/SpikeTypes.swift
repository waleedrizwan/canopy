import CanopyCore
import Foundation

enum SpikeMethod: String, CaseIterable, Sendable, Codable {
    case a = "A"  // locked exposure + pixels
    case b = "B"  // auto-exposure as meter
}

enum MeterState: String, Sendable {
    case starting = "starting"
    case live = "live"
    case adjusting = "adjusting"
    case tooBright = "too bright"
    case tooDark = "too dark"
    case stopped = "stopped"
}

struct FrameRecord: Codable, Sendable {
    var t: Double  // presentation time, s
    var requestedSeconds: Double?
    var requestedISO: Double?
    var exifSeconds: Double?
    var exifISO: Double?
    var exifBrightness: Double?
    var targetOffsetEV: Double
    var ladderIndex: Int?
    var stats: FrameStats
    var signalA: Double?  // pixels / exposure (valid in both methods)
    var signalB: Double?  // 2^offset / exposure (meaningful in method B)
    var dropped: Bool
}

/// Per-frame EXIF values the spike cares about.
struct FrameExif: Sendable {
    var seconds: Double?
    var iso: Double?
    var brightness: Double?

    var exposure: Exposure? {
        guard let seconds, let iso else { return nil }
        return Exposure(seconds: seconds, iso: iso)
    }
}

struct Snapshot: Sendable {
    var state: MeterState = .starting
    var method: SpikeMethod = .a
    var camera: Calibration.CameraPosition = .back
    var signal: Double?
    var cv: Double?
    var exposure: Exposure?
    var targetOffsetEV: Double = 0
    var brightnessValue: Double?
    var ladderIndex: Int?
    var ladderCount: Int = 0
    var stats: FrameStats?
    var measuredFPS: Double = 0
    var droppedFrames: Int = 0
    var recordingProgress: Int?
    var formatDescription: String = ""
    var error: String?
}

struct SavedCapture: Codable, Sendable {
    var id: Int
    var createdAt: Date
    var method: SpikeMethod
    var camera: Calibration.CameraPosition
    var requestedFPS: Double
    var format: String
    var lensAperture: Double
    var whiteBalanceGains: [Double]
    var borderFraction: Double
    var meanSignalA: Double?
    var cvSignalA: Double?
    var meanSignalB: Double?
    var cvSignalB: Double?
    var frames: [FrameRecord]
    var rawFrame: RawFrameInfo?

    struct RawFrameInfo: Codable, Sendable {
        var file: String
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var pixelFormat: String
    }
}

/// Settings in force when a capture was recorded.
struct CaptureSettings: Sendable {
    var method: SpikeMethod
    var camera: Calibration.CameraPosition
    var fps: Double
    var format: String
    var lensAperture: Double
}

enum SpikeError: Error {
    case noCamera, cannotAddInput, cannotAddOutput, noFormat
}

/// Writes captures to Documents/spike/ (pulled off the phone with devicectl).
enum SpikeStore {
    static func directory() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("spike", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Photone readings typed in next to each capture, in the format `canopy-tool fit` reads.
    static func loadReferences() -> [ReferenceReading] {
        guard let dir = try? directory(),
            let data = try? Data(contentsOf: dir.appendingPathComponent("references.json"))
        else { return [] }
        return (try? JSONDecoder().decode([ReferenceReading].self, from: data)) ?? []
    }

    /// Sets (or with nil, removes) the reference lux for one capture.
    static func setReference(captureID: Int, lux: Double?, diffuser: String) throws {
        var refs = loadReferences().filter { $0.captureID != captureID }
        if let lux { refs.append(ReferenceReading(captureID: captureID, lux: lux, diffuser: diffuser)) }
        refs.sort { $0.captureID < $1.captureID }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(refs).write(to: directory().appendingPathComponent("references.json"), options: .atomic)
    }

    /// Zips the whole capture folder into a temporary file the share sheet can send.
    static func zipForSharing() throws -> URL {
        let dir = try directory()
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordError: NSError?
        // `.forUploading` hands back a zip of the directory, valid only inside the block.
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { zip in
            let stamp = Date().formatted(.iso8601.year().month().day())
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("canopy-captures-\(stamp).zip")
            result = Result {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zip, to: dest)
                return dest
            }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    static func nextID(in dir: URL) throws -> Int {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let ids = names.compactMap { n -> Int? in
            guard n.hasPrefix("capture-"), n.hasSuffix(".json") else { return nil }
            return Int(n.dropFirst(8).prefix(3))
        }
        return (ids.max() ?? 0) + 1
    }

    static func save(
        frames: [FrameRecord], raw: (Data, SavedCapture.RawFrameInfo)?, settings: CaptureSettings
    ) throws -> SavedCapture {
        func summary(_ values: [Double]) -> (mean: Double?, cv: Double?) {
            var r = RollingStats(capacity: max(1, values.count))
            values.forEach { r.add($0) }
            return (r.mean, r.coefficientOfVariation)
        }
        let good = frames.filter { !$0.dropped }
        let a = summary(good.compactMap(\.signalA))
        let b = summary(good.compactMap(\.signalB))
        let g = Provisional.whiteBalanceGains
        let dir = try directory()
        let id = try nextID(in: dir)
        var cap = SavedCapture(
            id: id, createdAt: Date(), method: settings.method, camera: settings.camera,
            requestedFPS: settings.fps, format: settings.format, lensAperture: settings.lensAperture,
            whiteBalanceGains: [g.red, g.green, g.blue], borderFraction: Provisional.frameBorderFraction,
            meanSignalA: a.mean, cvSignalA: a.cv, meanSignalB: b.mean, cvSignalB: b.cv, frames: frames)
        if let raw {
            let name = String(format: "capture-%03d-frame.bgra", id)
            try raw.0.write(to: dir.appendingPathComponent(name))
            var info = raw.1
            info.file = name
            cap.rawFrame = info
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(cap).write(to: dir.appendingPathComponent(String(format: "capture-%03d.json", id)))
        return cap
    }
}
