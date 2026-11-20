import CanopyCore
import SwiftUI

/// T3.1: guided grid of PPFD readings.
struct HeatmapView: View {
    @Environment(AppModel.self) private var app
    @State private var rows = 3
    @State private var columns = 3
    @State private var selected: Int?
    @State private var message: String?

    var body: some View {
        List {
            if let map = app.data.heatmapInProgress {
                Section { HeatmapGrid(map: map, selected: currentIndex(map)) { selected = $0 } }
                Section { controls(map) }
                Section("Summary") { StatsView(stats: map.stats) }
                Section {
                    if let image = render(map) {
                        ShareLink(item: image, preview: SharePreview("Light map", image: image)) {
                            Label("Share as image", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("Start a new map", role: .destructive) { app.data.heatmapInProgress = nil }
                }
            } else {
                setup
            }
        }
        .navigationTitle("Light map")
        .onAppear { app.measure.setVisible("heatmap", true) }
        .onDisappear { app.measure.setVisible("heatmap", false) }
    }

    private var setup: some View {
        Section("New map") {
            Stepper("Rows: \(rows)", value: $rows, in: Heatmap.sizeRange).accessibilityIdentifier("rowsStepper")
            Stepper("Columns: \(columns)", value: $columns, in: Heatmap.sizeRange)
                .accessibilityIdentifier("columnsStepper")
            Button("Start") {
                app.data.heatmapInProgress = try? Heatmap(rows: rows, columns: columns)
                selected = nil
            }
            .accessibilityIdentifier("startHeatmap")
        }
    }

    private func currentIndex(_ map: Heatmap) -> Int? {
        selected ?? map.nextPending.flatMap { map.index(row: $0.row, column: $0.column) }
    }

    @ViewBuilder private func controls(_ map: Heatmap) -> some View {
        let m = app.measure
        if let i = currentIndex(map) {
            let (r, c) = (i / map.columns, i % map.columns)
            Text("Cell row \(r + 1), column \(c + 1)").font(.headline)
            Text(m.tiltWarning ? "Phone is tilted — lay it flat" : m.reading.state.words)
                .accessibilityIdentifier("heatmapState")
            Button("Record this cell") { record(map, row: r, column: c) }
                .disabled(!m.canRecord)
                .accessibilityIdentifier("recordCell")
            Button("Skip this cell") {
                try? app.data.heatmapInProgress?.skip(row: r, column: c)
                selected = nil
            }
            .accessibilityIdentifier("skipCell")
        } else {
            Text("All cells done. Tap a cell to re-measure it.")
        }
        if let message { Text(message).foregroundStyle(.secondary) }
    }

    private func record(_ map: Heatmap, row: Int, column: Int) {
        let m = app.measure
        guard let ppfd = app.values(signal: m.reading.signal).ppfd else {
            message = "No PPFD reading (check calibration and light type)."
            return
        }
        do {
            try app.data.heatmapInProgress?.record(
                ppfd, row: row, column: column, state: m.reading.state, tiltWarning: m.tiltWarning)
            message = nil
            selected = nil
        } catch {
            message = "Can't record right now: \(m.tiltWarning ? "phone is tilted" : m.reading.state.words)."
        }
    }

    private func render(_ map: Heatmap) -> Image? {
        let renderer = ImageRenderer(
            content: VStack(alignment: .leading) {
                HeatmapGrid(map: map, selected: nil) { _ in }
                StatsView(stats: map.stats)
            }
            .padding().frame(width: 600).background(.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}

struct HeatmapGrid: View {
    let map: Heatmap
    let selected: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        let stats = map.stats
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<map.rows, id: \.self) { r in
                GridRow {
                    ForEach(0..<map.columns, id: \.self) { c in
                        let i = r * map.columns + c
                        cell(map.cells[i], stats: stats, isSelected: i == selected)
                            .onTapGesture { onSelect(i) }
                            .accessibilityIdentifier("cell-\(r)-\(c)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ cell: Heatmap.Cell, stats: HeatmapStats, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        Group {
            switch cell {
            case .measured(let p):
                let rgb = Viridis.color(stats.normalized(p.value))
                let fill = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                Text(Format.ppfd(p)).font(.caption.bold()).monospacedDigit()
                    .foregroundStyle(stats.normalized(p.value) > 0.6 ? .black : .white)
                    .frame(maxWidth: .infinity, minHeight: 44).background(fill, in: shape)
            case .skipped:
                Text("no data").font(.caption2).frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.gray.opacity(0.2), in: shape)
            case .pending:
                Text("—").frame(maxWidth: .infinity, minHeight: 44).background(Color.gray.opacity(0.1), in: shape)
            }
        }
        .overlay(shape.stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3))
    }
}

struct StatsView: View {
    let stats: HeatmapStats

    var body: some View {
        let f = { (v: Double?) in v.map { Format.ppfd(PPFD($0)) } ?? "—" }
        LabeledContent("Min", value: f(stats.min))
        LabeledContent("Average", value: f(stats.average)).accessibilityIdentifier("statAverage")
        LabeledContent("Max", value: f(stats.max))
        LabeledContent("Uniformity", value: stats.uniformity.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
        Text("PPFD in µmol/m²/s. Uniformity = min ÷ average.").font(.caption).foregroundStyle(.secondary)
    }
}
