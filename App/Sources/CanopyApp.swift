import AVFoundation
import SwiftUI

@main
struct CanopyApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environment(app)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("seenInstructions") private var seenInstructions = false

    var body: some View {
        // UI tests run on a fixture signal and skip the first-launch instructions.
        let showInstructions = Binding(
            get: { !seenInstructions && app.usesLiveCamera }, set: { if !$0 { seenInstructions = true } })
        TabView {
            NavigationStack { CameraPermissionGate { MeasureView() } }.tabItem {
                Label("Measure", systemImage: "sun.max")
            }
            NavigationStack { HeatmapView() }.tabItem { Label("Map", systemImage: "square.grid.3x3") }
            NavigationStack { LogView() }.tabItem { Label("Log", systemImage: "list.bullet") }
            NavigationStack { ToolsView() }.tabItem { Label("Tools", systemImage: "function") }
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gear") }
        }
        .onChange(of: scenePhase) { _, phase in app.measure.setAppActive(phase == .active) }
        .sheet(isPresented: showInstructions) {
            NavigationStack {
                InstructionsView().toolbar {
                    Button("Done") { seenInstructions = true }.accessibilityIdentifier("closeInstructions")
                }
            }
            .interactiveDismissDisabled()
        }
    }
}

/// T0.1: asks for camera access; if denied, explains and links to Settings.
struct CameraPermissionGate<Content: View>: View {
    @Environment(AppModel.self) private var app
    @ViewBuilder let content: () -> Content
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if !app.usesLiveCamera || status == .authorized {
                content()
            } else if status == .notDetermined {
                ProgressView()
            } else {
                PermissionDeniedView()
            }
        }
        .task {
            guard app.usesLiveCamera, status == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }
}
