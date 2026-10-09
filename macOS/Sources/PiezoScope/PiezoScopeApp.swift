import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ScopeModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

@main
struct PiezoScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ScopeModel()

    var body: some Scene {
        Window("Piezo Scope", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1100, height: 870)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Capture") {
                Button(model.isActive ? "Stop Capture" : "Start Capture", action: model.toggleCapture)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isActive && !model.canStart)
                Toggle("Listen on This Mac", isOn: $model.listenEnabled)
                    .keyboardShortcut("l", modifiers: .command)
                Toggle("Hold Waveform", isOn: $model.hold)
                    .disabled(model.waveform.isEmpty)
            }
        }
    }
}
