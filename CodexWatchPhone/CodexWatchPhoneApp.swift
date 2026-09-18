import SwiftUI

@main
struct CodexWatchPhoneApp: App {
    @StateObject private var model = PhoneGatewayViewModel()

    var body: some Scene {
        WindowGroup {
            PhoneGatewayView(model: model)
        }
    }
}
