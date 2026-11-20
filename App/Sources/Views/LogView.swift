import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

/// T4.1 log list and T4.2 CSV export.
struct LogView: View {
    @Environment(AppModel.self) private var app
    @State private var labelFilter: String?
    @State private var lightFilter: String?
    @State private var lastDeletion: LogBook.Deletion?

    var body: some View {
        let entries = app.data.log.filtered(label: labelFilter, lightType: lightFilter)
        List {
            if entries.isEmpty {
                Text("No saved readings yet.").foregroundStyle(.secondary)
            }
            ForEach(entries) { e in
                NavigationLink {
                    LogDetailView(entry: e)
                } label: {
                    LogRow(entry: e)
                }
            }
            .onDelete { offsets in
                for i in offsets { lastDeletion = app.data.log.delete(id: entries[i].id) }
            }
        }
        .accessibilityIdentifier("logList")
        .navigationTitle("Log")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: CSVFile(entries: entries), preview: SharePreview("Light readings.csv")) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
                .accessibilityIdentifier("exportCSV")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let d = lastDeletion {
                HStack {
                    Text("Reading deleted")
                    Spacer()
                    Button("Undo") {
                        app.data.log.undo(d)
                        lastDeletion = nil
                    }
                    .accessibilityIdentifier("undoDelete")
                }
                .padding().background(.thinMaterial)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button("All readings") {
                labelFilter = nil
                lightFilter = nil
            }
            Section("Label") {
                ForEach(app.data.log.labels, id: \.self) { l in Button(l) { labelFilter = l } }
            }
            Section("Light type") {
                ForEach(app.data.log.lightTypes, id: \.self) { l in Button(l) { lightFilter = l } }
            }
        } label: {
            Label(labelFilter ?? lightFilter ?? "Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(Format.ppfd(entry.ppfd)) µmol/m²/s · \(Format.dli(entry.dli)) DLI").font(.headline)
            Text(
                [entry.label, entry.lightType, entry.timestamp.formatted(date: .abbreviated, time: .shortened)]
                    .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct LogDetailView: View {
    let entry: LogEntry

    var body: some View {
        List {
            LabeledContent("Time", value: entry.timestamp.formatted(date: .long, time: .standard))
            LabeledContent("Lux", value: Format.lux(entry.lux))
            LabeledContent("PPFD", value: "\(Format.ppfd(entry.ppfd)) µmol/m²/s")
            LabeledContent("DLI", value: "\(Format.dli(entry.dli)) mol/m²/day")
            LabeledContent("Hours of light", value: Format.hours(entry.photoperiodHours))
            LabeledContent("Light type", value: entry.lightType)
            LabeledContent("Diffuser", value: entry.diffuser)
            LabeledContent("Camera", value: entry.camera.rawValue)
            LabeledContent("Calibration multiplier", value: String(format: "%.2f", entry.kUser))
            if let l = entry.label { LabeledContent("Label", value: l) }
            if let n = entry.note { Text(n) }
        }
        .navigationTitle("Reading")
    }
}

/// CSV as a shareable file.
struct CSVFile: Transferable {
    let entries: [LogEntry]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("light-readings.csv")
            try CSVExport.data(file.entries).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
