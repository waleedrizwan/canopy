import Foundation

/// T3.1 heatmap grid. Pure state; the UI drives it cell by cell.
public struct Heatmap: Equatable, Sendable, Codable {
    public enum Cell: Equatable, Sendable, Codable {
        case pending
        case measured(PPFD)
        case skipped
    }

    public enum RecordError: Error, Equatable, Sendable {
        case blocked(ReadingState)
        case tilted
        case outOfBounds
    }

    public static let sizeRange = 2...10

    public let rows: Int
    public let columns: Int
    public private(set) var cells: [Cell]

    public init(rows: Int, columns: Int) throws(ValidationError) {
        let r = Double(Self.sizeRange.lowerBound)...Double(Self.sizeRange.upperBound)
        guard Self.sizeRange.contains(rows), Self.sizeRange.contains(columns) else { throw .outOfRange(r) }
        self.rows = rows
        self.columns = columns
        cells = Array(repeating: .pending, count: rows * columns)
    }

    public func index(row: Int, column: Int) -> Int? {
        guard (0..<rows).contains(row), (0..<columns).contains(column) else { return nil }
        return row * columns + column
    }

    /// First cell not yet measured or skipped, in reading order.
    public var nextPending: (row: Int, column: Int)? {
        cells.firstIndex(of: .pending).map { ($0 / columns, $0 % columns) }
    }

    /// Records (or re-records) a cell. Refused unless the reading is live and level.
    public mutating func record(
        _ value: PPFD, row: Int, column: Int,
        state: ReadingState, tiltWarning: Bool
    ) throws(RecordError) {
        guard state == .live else { throw .blocked(state) }
        guard !tiltWarning else { throw .tilted }
        guard let i = index(row: row, column: column) else { throw .outOfBounds }
        cells[i] = .measured(value)
    }

    public mutating func skip(row: Int, column: Int) throws(RecordError) {
        guard let i = index(row: row, column: column) else { throw .outOfBounds }
        cells[i] = .skipped
    }

    public var stats: HeatmapStats {
        HeatmapStats(values: cells.compactMap { if case .measured(let v) = $0 { v.value } else { nil } })
    }
}

/// Min / max / average / uniformity over measured cells; skipped cells excluded.
/// Any field is nil when it can't be computed; the UI shows "—".
public struct HeatmapStats: Equatable, Sendable {
    public let min: Double?
    public let max: Double?
    public let average: Double?
    /// min ÷ average, 0…1.
    public let uniformity: Double?

    public init(values: [Double]) {
        guard let lo = values.min(), let hi = values.max() else {
            min = nil; max = nil; average = nil; uniformity = nil
            return
        }
        let avg = values.reduce(0, +) / Double(values.count)
        min = lo
        max = hi
        average = avg
        uniformity = avg > 0 ? lo / avg : nil
    }

    /// Position of `value` on the colour scale, 0…1. All-equal → 0.5 (single colour).
    public func normalized(_ value: Double) -> Double {
        guard let lo = min, let hi = max, hi > lo else { return 0.5 }
        return Swift.min(1, Swift.max(0, (value - lo) / (hi - lo)))
    }
}

/// Viridis, perceptually uniform. Anchors from matplotlib's viridis at 0, 0.125 … 1.
public enum Viridis {
    public struct RGB: Equatable, Sendable {
        public var red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    static let anchors: [RGB] = [
        RGB(0.267, 0.005, 0.329), RGB(0.283, 0.141, 0.458), RGB(0.254, 0.265, 0.530),
        RGB(0.207, 0.372, 0.553), RGB(0.164, 0.471, 0.558), RGB(0.128, 0.567, 0.551),
        RGB(0.135, 0.659, 0.518), RGB(0.267, 0.749, 0.441), RGB(0.478, 0.821, 0.318),
        RGB(0.741, 0.873, 0.150), RGB(0.993, 0.906, 0.144),
    ]

    /// RGB 0…1 for t in 0…1.
    public static func color(_ t: Double) -> RGB {
        let x = Swift.min(1, Swift.max(0, t)) * Double(anchors.count - 1)
        let i = Swift.min(Int(x), anchors.count - 2)
        let f = x - Double(i)
        let a = anchors[i], b = anchors[i + 1]
        return RGB(a.red + (b.red - a.red) * f, a.green + (b.green - a.green) * f, a.blue + (b.blue - a.blue) * f)
    }
}
