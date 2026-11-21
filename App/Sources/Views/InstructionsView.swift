import SwiftUI

/// Plain-language guide for the person collecting calibration captures with Photone.
/// Shown once on first launch and kept under Settings.
struct InstructionsView: View {
    var body: some View {
        List {
            Section {
                Text(
                    "Canopy measures light with the iPhone's camera. Before it can show lux, PPFD and DLI, "
                        + "it has to be tuned to this phone by comparing it with Photone.")
                Text(
                    "Until that's done, the Measure tab says \u{201C}Not calibrated\u{201D}. That's expected.")
            } header: {
                Text("What this version is for")
            }

            Section("Before you start") {
                Text("Turn the grow lights on and let them warm up for 10 minutes.")
                Text("In Photone, choose the front camera and no diffuser.")
                Text("Take the phone case off if it covers the front camera.")
            }

            Section("At each spot") {
                step(1, "Lay the phone flat, screen up, where the leaves would be.")
                step(2, "Open Photone and note the lux reading. Don't move the phone.")
                step(3, "Switch to Canopy and open the capture screen (button below).")
                step(4, "Set Camera to Front and Method to A. Tap Record capture, then take your hand away.")
                step(5, "Wait for \u{201C}Saved #…\u{201D}. Switch Method to B and record again.")
                step(6, "Type the Photone lux into the box under both new captures.")
            }

            Section("Spots to use") {
                Text("Aim for 8 to 10 spots with very different brightness:")
                Text("• right under a light, close up")
                Text("• the edges of the tray")
                Text("• higher and lower, and further away from the lights")
                Text("• one or two by a window in daylight")
            }

            Section("When you're done") {
                Text(
                    "At the bottom of the capture screen, tap Prepare captures to send, then Send captures. "
                        + "AirDrop or Messages both work. The file is large, so use Wi-Fi.")
            }

            Section {
                NavigationLink("Open the capture screen") { SpikeView() }
                    .bold()
                    .accessibilityIdentifier("openCaptures")
            }
        }
        .navigationTitle("Instructions")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Text("\(n)").font(.headline).monospacedDigit()
        }
    }
}
