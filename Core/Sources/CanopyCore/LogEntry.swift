import Foundation

/// T4.1 log entry. A snapshot: every factor used is copied in, so later calibration
/// changes never rewrite saved readings.
public struct LogEntry: Equatable, Sendable, Codable, Identifiable {
    public static let schemaVersion = 1

    public var id: UUID
    public var timestamp: Date
    public var lux: Lux
    public var ppfd: PPFD
    public var dli: DLI
    public var photoperiodHours: Double
    public var lightType: String
    public var diffuser: String
    public var camera: Calibration.CameraPosition
    public var kBase: Double
    public var fLight: Double
    public var kUser: Double
    public var rawSignal: Double
    public var label: String?
    public var note: String?

    public init(
        id: UUID = UUID(), timestamp: Date, lux: Lux, ppfd: PPFD, dli: DLI, photoperiodHours: Double,
        lightType: String, diffuser: String, camera: Calibration.CameraPosition,
        kBase: Double, fLight: Double, kUser: Double, rawSignal: Double,
        label: String? = nil, note: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.lux = lux
        self.ppfd = ppfd
        self.dli = dli
        self.photoperiodHours = photoperiodHours
        self.lightType = lightType
        self.diffuser = diffuser
        self.camera = camera
        self.kBase = kBase
        self.fLight = fLight
        self.kUser = kUser
        self.rawSignal = rawSignal
        self.label = label
        self.note = note
    }
}

/// T4.2 CSV export: RFC 4180, CRLF, `.` decimals, 2 places, ISO 8601 with offset.
public enum CSVExport {
    public static let header =
        "timestamp,lux,ppfd_umol_m2_s,dli_mol_m2_d,photoperiod_h,"
        + "light_type,diffuser,camera,calibration_multiplier,label,note"

    public static func csv(_ entries: [LogEntry], timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = timeZone
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        var lines = [header]
        for e in entries {
            lines.append(
                [
                    df.string(from: e.timestamp),
                    number(e.lux.value), number(e.ppfd.value), number(e.dli.value), number(e.photoperiodHours),
                    field(e.lightType), field(e.diffuser), field(e.camera.rawValue), number(e.kUser),
                    field(e.label ?? ""), field(e.note ?? ""),
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func data(_ entries: [LogEntry], timeZone: TimeZone = .current) -> Data {
        Data(csv(entries, timeZone: timeZone).utf8)
    }

    static func number(_ v: Double) -> String {
        // %f always uses "." and no grouping, independent of locale.
        let s = String(format: "%.2f", v)
        return s == "-0.00" ? "0.00" : s
    }

    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
