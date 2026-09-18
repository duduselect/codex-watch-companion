import SwiftUI

@main
struct CodexWatchCompanionApp: App {
    @WKExtensionDelegateAdaptor(VoiceBackgroundDelegate.self) private var backgroundDelegate
    @StateObject private var model = CompanionViewModel(socket: WatchHTTPBridgeClient())

    var body: some Scene {
        WindowGroup {
            CompanionRootView(model: model)
                .onAppear {
                    let process = ProcessInfo.processInfo
                    if process.arguments.contains("--ui-testing") {
                        model.applyUITestScenario(process.environment["CODEX_WATCH_UI_TEST_SCENARIO"])
                    } else {
                        model.startRuntimeSession()
                        model.connectIfPossible()
                    }
                }
        }
    }
}
