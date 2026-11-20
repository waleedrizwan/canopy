import CanopyCore
import SwiftUI

/// T5.1 calculators and T5.2 guide.
struct ToolsView: View {
    var body: some View {
        List {
            NavigationLink("Hours of light needed") { HoursCalculator() }.accessibilityIdentifier("hoursCalc")
            NavigationLink("PPFD needed") { PPFDCalculator() }
            NavigationLink("Lux ↔ PPFD") { ConverterView() }
            NavigationLink("How to measure") { MeasuringGuide() }.accessibilityIdentifier("measuringGuide")
        }
        .navigationTitle("Tools")
    }
}

private func message(for error: Error) -> String {
    switch error as? ValidationError {
    case .empty: "Enter a value."
    case .notANumber: "That isn't a number."
    case .negative: "Must not be negative."
    case .zero: "Must be more than zero."
    case .outOfRange(let r): "Must be between \(Int(r.lowerBound)) and \(Int(r.upperBound))."
    case .notAStep(let s): "Use steps of \(s)."
    case nil: "Invalid input."
    }
}

private struct HoursCalculator: View {
    @State private var dli = ""
    @State private var ppfd = ""

    var body: some View {
        Form {
            TextField("Target DLI (mol/m²/day)", text: $dli).keyboardType(.decimalPad).accessibilityIdentifier(
                "dliField")
            TextField("PPFD (µmol/m²/s)", text: $ppfd).keyboardType(.decimalPad).accessibilityIdentifier("ppfdField")
            Text(result).font(.title2.bold()).accessibilityIdentifier("hoursResult")
        }
        .navigationTitle("Hours needed")
    }

    private var result: String {
        guard !dli.isEmpty, !ppfd.isEmpty else { return "—" }
        do {
            switch try Calculators.requiredHours(dli: DLI(parseNumber(dli)), ppfd: PPFD(parseNumber(ppfd))) {
            case .hours(let h): return Format.hours(h)
            case .notReachable: return "Not reachable with this light"
            }
        } catch {
            return message(for: error)
        }
    }
}

private struct PPFDCalculator: View {
    @State private var dli = ""
    @State private var hours = ""

    var body: some View {
        Form {
            TextField("Target DLI (mol/m²/day)", text: $dli).keyboardType(.decimalPad)
            TextField("Hours of light per day", text: $hours).keyboardType(.decimalPad)
            Text(result).font(.title2.bold())
        }
        .navigationTitle("PPFD needed")
    }

    private var result: String {
        guard !dli.isEmpty, !hours.isEmpty else { return "—" }
        do {
            let p = try Calculators.requiredPPFD(dli: DLI(parseNumber(dli)), hours: parseNumber(hours))
            return "\(Format.ppfd(p)) µmol/m²/s"
        } catch {
            return message(for: error)
        }
    }
}

private struct ConverterView: View {
    @Environment(AppModel.self) private var app
    @State private var lux = ""

    var body: some View {
        Form {
            if let t = app.activeLightType {
                LabeledContent("Light type", value: t.type.name)
                TextField("Lux", text: $lux).keyboardType(.decimalPad)
                Text(result(t.type)).font(.title2.bold())
                Text("Uses the same factor and calibration as the measure screen.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Choose a light type on the Measure tab first.")
            }
        }
        .navigationTitle("Lux ↔ PPFD")
    }

    private func result(_ t: LightType) -> String {
        guard !lux.isEmpty else { return "—" }
        guard let f = t.fLight else { return "This light type isn't calibrated yet." }
        let kUser = app.setupKey.map { app.data.calibrations.kUser(for: $0) } ?? 1
        do {
            let p = try Calculators.ppfd(fromLux: Lux(parseNumber(lux)), fLight: f, kUser: kUser)
            return "\(Format.ppfd(p)) µmol/m²/s"
        } catch {
            return message(for: error)
        }
    }
}

/// Measuring guide, in our own words.
private struct MeasuringGuide: View {
    var body: some View {
        List {
            Section("Where") {
                Text("Measure where the leaves are: lay the phone at the top of the plant canopy, not on the floor.")
                Text("Measure several spots — the middle under a light is often much brighter than the edges.")
            }
            Section("How") {
                Text(
                    "Point the measuring camera straight up at the light and keep the phone flat. "
                        + "The app warns you if it's tilted.")
                Text("Keep your hand, head and shadow out of the way. Step back once the phone is placed.")
                Text("Wait until the reading says Live and has settled before saving it.")
            }
            Section("Be consistent") {
                Text("Use the same camera and diffuser setting every time.")
                Text(
                    "A case or screen protector over the camera changes the reading — measure the way the app was "
                        + "calibrated.")
                Text("Reflective walls and foil change the light. Keep the phone in the same place when comparing.")
            }
        }
        .navigationTitle("How to measure")
    }
}
