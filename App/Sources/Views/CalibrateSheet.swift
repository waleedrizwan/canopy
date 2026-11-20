import CanopyCore
import SwiftUI

/// T2.2: enter a reference PPFD while measuring the same light.
struct CalibrateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var referenceText = ""
    @State private var message: String?
    @State private var pendingConfirm: Double?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Keep the phone still under the light, read the reference meter, and type its PPFD.")
                    let v = app.values(signal: app.measure.reading.signal)
                    LabeledContent("This app (uncalibrated)", value: v.uncalibratedPPFD.map { Format.ppfd($0) } ?? "—")
                    TextField("Reference PPFD", text: $referenceText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("referenceField")
                }
                if let message {
                    Section { Text(message).accessibilityIdentifier("calibrationMessage") }
                }
                if let k = pendingConfirm {
                    Section {
                        Button("Save multiplier \(String(format: "%.2f", k)) anyway") { save(k) }
                            .accessibilityIdentifier("confirmUnusual")
                    }
                }
            }
            .navigationTitle("Calibrate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Calibrate", action: calibrate).accessibilityIdentifier("confirmCalibrate")
                }
            }
        }
    }

    private func calibrate() {
        pendingConfirm = nil
        guard app.setupKey != nil else {
            message = "Choose a light type first."
            return
        }
        guard UserCalibrations.isStable(app.measure.recentSignals()) else {
            message = "Reading isn't steady yet. Keep the phone still and try again."
            return
        }
        let v = app.values(signal: app.measure.reading.signal)
        guard let current = v.uncalibratedPPFD else {
            message = "No reading to calibrate."
            return
        }
        do {
            let reference = try parseNumber(referenceText)
            switch try UserCalibrations.evaluate(reference: PPFD(reference), uncalibrated: current) {
            case .accept(let k):
                save(k)
            case .needsConfirmation(let k):
                pendingConfirm = k
                message = "That's a large correction (×\(String(format: "%.2f", k))). Re-measure, or save it anyway."
            }
        } catch let e as UserCalibrations.Refusal {
            message = Self.describe(e)
        } catch {
            message = "Enter a number."
        }
    }

    private static func describe(_ refusal: UserCalibrations.Refusal) -> String {
        switch refusal {
        case .zeroReading: "The reading is zero; can't calibrate."
        case .invalidReference: "Enter a reference above zero."
        case .outOfRange(let k): "Correction ×\(String(format: "%.2f", k)) is outside 0.1–10. Not saved."
        case .unstable: "Reading isn't steady yet."
        }
    }

    private func save(_ k: Double) {
        guard let key = app.setupKey else { return }
        do {
            try app.data.calibrations.set(k, for: key)
            dismiss()
        } catch {
            message = "Not saved: correction out of range."
        }
    }
}
