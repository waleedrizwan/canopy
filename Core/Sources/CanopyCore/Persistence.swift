import Foundation

/// User settings (T2.1 persistence, T1.3 photoperiod, T0.1 camera choice).
/// Every field decodes with a default so older files keep loading.
public struct AppSettings: Codable, Equatable, Sendable {
    public var camera: Calibration.CameraPosition
    public var diffuserID: String
    public var plantLightTypeID: String?
    public var reefLightTypeID: String?
    public var reefMode: Bool
    public var photoperiodHours: Double

    public init(
        camera: Calibration.CameraPosition = .back, diffuserID: String = "none",
        plantLightTypeID: String? = nil, reefLightTypeID: String? = nil, reefMode: Bool = false,
        photoperiodHours: Double = 12
    ) {
        self.camera = camera
        self.diffuserID = diffuserID
        self.plantLightTypeID = plantLightTypeID
        self.reefLightTypeID = reefLightTypeID
        self.reefMode = reefMode
        self.photoperiodHours = photoperiodHours
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        camera = try c.decodeIfPresent(Calibration.CameraPosition.self, forKey: .camera) ?? d.camera
        diffuserID = try c.decodeIfPresent(String.self, forKey: .diffuserID) ?? d.diffuserID
        plantLightTypeID = try c.decodeIfPresent(String.self, forKey: .plantLightTypeID)
        reefLightTypeID = try c.decodeIfPresent(String.self, forKey: .reefLightTypeID)
        reefMode = try c.decodeIfPresent(Bool.self, forKey: .reefMode) ?? d.reefMode
        photoperiodHours = try c.decodeIfPresent(Double.self, forKey: .photoperiodHours) ?? d.photoperiodHours
    }

    /// Light type for the current mode (plant and reef selections are kept separately).
    public var activeLightTypeID: String? {
        get { reefMode ? reefLightTypeID : plantLightTypeID }
        set { if reefMode { reefLightTypeID = newValue } else { plantLightTypeID = newValue } }
    }
}

/// Everything the app saves, in one file.
public struct AppData: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var settings: AppSettings
    public var calibrations: UserCalibrations
    public var log: LogBook
    /// In-progress heatmap survives backgrounding and relaunch (T3.1).
    public var heatmapInProgress: Heatmap?

    public init(
        settings: AppSettings = AppSettings(), calibrations: UserCalibrations = UserCalibrations(),
        log: LogBook = LogBook(), heatmapInProgress: Heatmap? = nil
    ) {
        self.settings = settings
        self.calibrations = calibrations
        self.log = log
        self.heatmapInProgress = heatmapInProgress
    }
}

/// JSON file wrapped in a schema version. Writes are atomic.
public struct VersionedFileStore: Sendable {
    public enum StoreError: Error, Equatable {
        case newerSchema(Int)
    }

    struct Envelope<T: Codable>: Codable {
        var schemaVersion: Int
        var data: T
    }

    struct Header: Codable {
        var schemaVersion: Int
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// nil when no file exists yet.
    public func loadAppData() throws -> AppData? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decodeAppData(Data(contentsOf: url))
    }

    public static func decodeAppData(_ data: Data) throws -> AppData {
        let version = try decoder().decode(Header.self, from: data).schemaVersion
        guard version <= AppData.schemaVersion else { throw StoreError.newerSchema(version) }
        // Version 1 is current. Future migrations: decode the old shape here and convert.
        return try decoder().decode(Envelope<AppData>.self, from: data).data
    }

    public func save(_ value: AppData) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder().encode(Envelope(schemaVersion: AppData.schemaVersion, data: value))
        try data.write(to: url, options: .atomic)
    }
}

/// T4.1 log: newest first, delete with undo, filters.
public struct LogBook: Codable, Equatable, Sendable {
    public private(set) var entries: [LogEntry] = []

    public init(entries: [LogEntry] = []) {
        self.entries = entries
    }

    public struct Deletion: Equatable, Sendable {
        public let entry: LogEntry
    }

    public var newestFirst: [LogEntry] { entries.sorted { $0.timestamp > $1.timestamp } }

    public mutating func add(_ entry: LogEntry) { entries.append(entry) }

    public mutating func delete(id: UUID) -> Deletion? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return Deletion(entry: entries.remove(at: i))
    }

    public mutating func undo(_ deletion: Deletion) {
        guard !entries.contains(where: { $0.id == deletion.entry.id }) else { return }
        entries.append(deletion.entry)
    }

    public func filtered(label: String? = nil, lightType: String? = nil) -> [LogEntry] {
        newestFirst.filter { e in
            (label == nil || e.label == label) && (lightType == nil || e.lightType == lightType)
        }
    }

    public var labels: [String] { Array(Set(entries.compactMap(\.label))).sorted() }
    public var lightTypes: [String] { Array(Set(entries.map(\.lightType))).sorted() }
}
