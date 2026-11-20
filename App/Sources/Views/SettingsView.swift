import CanopyCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            Section("Measuring") {
                Picker("Camera", selection: $app.settings.camera) {
                    Text("Back").tag(Calibration.CameraPosition.back)
                    Text("Front").tag(Calibration.CameraPosition.front)
                }
                Picker("Diffuser", selection: $app.settings.diffuserID) {
                    ForEach(app.config.diffusers) { d in Text(d.name).tag(d.id) }
                }
                if app.config.lightTypes.contains(where: \.reef) {
                    Toggle("Aquarium / reef mode", isOn: $app.settings.reefMode)
                }
            }
            Section("Your calibrations") {
                let cals = app.data.calibrations.multipliers.sorted { $0.key.lightType < $1.key.lightType }
                if cals.isEmpty { Text("None. Readings use the built-in calibration.").foregroundStyle(.secondary) }
                ForEach(cals, id: \.key) { key, k in
                    LabeledContent(
                        "\(app.config.lightType(id: key.lightType)?.name ?? key.lightType) · \(key.camera.rawValue)",
                        value: "×\(String(format: "%.2f", k))")
                }
                .onDelete { offsets in
                    for i in offsets { app.data.calibrations.reset(cals[i].key) }
                }
                if !cals.isEmpty {
                    Button("Delete all calibrations", role: .destructive) { app.data.calibrations.deleteAll() }
                }
            }
            Section("About this phone") {
                LabeledContent("Phone model", value: app.modelIdentifier)
                LabeledContent("Calibrated on", value: app.config.phoneModel ?? "Not calibrated yet")
                LabeledContent("Signal method", value: app.config.signalMethod?.rawValue ?? "Not chosen yet (T0.0)")
                if let e = app.saveError { Text(e).foregroundStyle(.red) }
            }
            Section("Development") {
                NavigationLink("T0.0 spike screen") { SpikeView() }
            }
        }
        .navigationTitle("Settings")
    }
}
