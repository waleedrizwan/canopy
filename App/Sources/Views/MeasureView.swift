import CanopyCore
import SwiftUI

extension ReadingState {
    /// States in words, not colour alone (T7.3).
    var words: String {
        switch self {
        case .starting: "Starting…"
        case .live: "Live"
        case .adjusting: "Adjusting…"
        case .tooBright: "Too bright"
        case .tooDark: "Too dark"
        case .paused(.background): "Paused"
        case .paused(.interrupted): "Camera in use elsewhere — paused"
        case .paused(.hot): "Phone is hot, reading paused"
        }
    }
}

struct MeasureView: View {
    @Environment(AppModel.self) private var app
    @State private var showSave = false
    @State private var showCalibrate = false

    var body: some View {
        let m = app.measure
        let shown = m.frozenSignal ?? m.reading.signal ?? m.reading.held
        let v = app.values(signal: shown)
        List {
            Section { ReadingPanel(values: v, state: m.reading.state, frozen: m.frozenSignal != nil) }
            if m.tiltWarning {
                Section {
                    Label("Phone is tilted — lay it flat", systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("tiltWarning")
                }
            }
            Section {
                Button(m.frozenSignal == nil ? "Hold reading" : "Resume live") {
                    m.frozenSignal = m.frozenSignal == nil ? m.reading.signal : nil
                }
                .disabled(m.frozenSignal == nil && m.reading.signal == nil)
                .accessibilityIdentifier("holdButton")
                Button("Save to log") { showSave = true }
                    .disabled(v.dli == nil)
                    .accessibilityIdentifier("saveButton")
                Button("Calibrate to a reference…") { showCalibrate = true }
                    .disabled(v.uncalibratedPPFD == nil)
                    .accessibilityIdentifier("calibrateButton")
            }
            SetupSection()
            PhotoperiodSection(values: v)
        }
        .navigationTitle("Measure")
        .onAppear { m.setVisible("measure", true) }
        .onDisappear { m.setVisible("measure", false) }
        .sheet(isPresented: $showSave) { SaveReadingSheet(values: v) }
        .sheet(isPresented: $showCalibrate) { CalibrateSheet() }
    }
}

private struct ReadingPanel: View {
    let values: DisplayValues
    let state: ReadingState
    let frozen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(frozen ? "Held" : state.words)
                .font(.headline)
                .accessibilityIdentifier("stateLabel")
            switch values.status {
            case .notCalibrated:
                Text("Not calibrated").font(.title.bold()).accessibilityIdentifier("notCalibrated")
                Text("Readings appear once this phone has been calibrated against a reference.")
                    .font(.callout).foregroundStyle(.secondary)
            case .otherPhone(let model):
                Text("Not calibrated for this phone").font(.title.bold()).accessibilityIdentifier("notCalibrated")
                Text("Calibration was done on \(model); this is \(DeviceInfo.modelIdentifier).")
                    .font(.callout).foregroundStyle(.secondary)
            case .calibrated:
                valueRow("Lux", values.lux.map { Format.lux($0) }, id: "luxValue")
                valueRow("PPFD", values.ppfd.map { "\(Format.ppfd($0)) µmol/m²/s" }, id: "ppfdValue")
                valueRow("DLI", values.dli.map { "\(Format.dli($0)) mol/m²/day" }, id: "dliValue")
                if values.lightType == nil {
                    Text("Choose a light type to see PPFD and DLI.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func valueRow(_ name: String, _ value: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.largeTitle.bold()).monospacedDigit()
                .opacity(state == .live || frozen ? 1 : 0.5)
                .accessibilityIdentifier(id)
        }
    }
}

private struct SetupSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section("Setup") {
            LabeledContent("Camera", value: app.settings.camera == .back ? "Back" : "Front")
            LabeledContent("Diffuser", value: app.diffuserName)
            NavigationLink {
                LightTypePicker()
            } label: {
                LabeledContent("Light type") {
                    if let t = app.activeLightType {
                        Text(
                            t.type.name + (t.isDefault ? " (default)" : "")
                                + (t.type.isUnverified ? " · unverified" : ""))
                    } else {
                        Text("None")
                    }
                }
            }
            .accessibilityIdentifier("lightTypeRow")
        }
    }
}

private struct PhotoperiodSection: View {
    @Environment(AppModel.self) private var app
    let values: DisplayValues

    var body: some View {
        @Bindable var app = app
        Section("Daily light") {
            Stepper(value: $app.data.settings.photoperiodHours, in: 0...24, step: 0.5) {
                LabeledContent("Hours of light per day", value: Format.hours(app.data.settings.photoperiodHours))
            }
            .accessibilityIdentifier("photoperiodStepper")
            if values.lightType?.name.localizedCaseInsensitiveContains("sun") == true {
                Text("DLI assumes this intensity for the whole photoperiod; real sunlight changes through the day.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct LightTypePicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let groups = Dictionary(grouping: app.availableLightTypes, by: \.group)
        List {
            if groups.isEmpty {
                Text("No light types yet. They're added during calibration.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? []) { t in
                        Button {
                            app.data.settings.activeLightTypeID = t.id
                        } label: {
                            HStack {
                                Text(t.name)
                                if t.isUnverified { Text("unverified").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if app.data.settings.activeLightTypeID == t.id { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("lightType-\(t.id)")
                    }
                }
            }
        }
        .navigationTitle("Light type")
    }
}

private struct SaveReadingSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let values: DisplayValues
    @State private var label = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label (e.g. shelf, plant)", text: $label).accessibilityIdentifier("labelField")
                TextField("Note", text: $note, axis: .vertical)
            }
            .navigationTitle("Save reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.saveToLog(values, label: label, note: note)
                        dismiss()
                    }
                    .accessibilityIdentifier("confirmSave")
                }
            }
        }
    }
}
