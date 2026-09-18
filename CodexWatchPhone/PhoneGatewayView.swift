import SwiftUI

struct PhoneGatewayView: View {
    @ObservedObject var model: PhoneGatewayViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.connectionLabel, systemImage: connectionSymbol)
                        .foregroundStyle(connectionColor)
                    Label(model.watchLabel, systemImage: "applewatch")
                        .foregroundStyle(model.isWatchReachable ? .green : .secondary)
                } header: {
                    Text("Connection Status")
                }

                Section {
                    TextField("ws://Mac-address:17842/codex-watch", text: $model.bridgeURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        model.connect()
                    } label: {
                        Label("Connect Mac", systemImage: "bolt.horizontal.fill")
                    }

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(!model.isConnected && model.connectionState != .connecting)
                } header: {
                    Text("Mac Codex Bridge Address")
                } footer: {
                    Text("For remote use, enter the Mac's private Tailscale address, such as ws://100.x.y.z:17842/codex-watch. Allow Local Network and notification access when prompted.")
                }

                Section {
                    Text(model.latestEventTitle)
                        .font(.headline)
                    Text(model.latestEventBody)
                        .foregroundStyle(.secondary)
                    if let date = model.latestEventDate {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Latest Codex Status")
                }

                Section {
                    Button {
                        model.requestNotificationPermission()
                    } label: {
                        Label("Allow Task Notifications", systemImage: "bell.badge")
                    }

                    Button {
                        model.sendTestNotification()
                    } label: {
                        Label("Send Test Notification", systemImage: "paperplane")
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("iPhone creates a local notification when a task completes, fails, needs approval, or waits for input. Apple decides whether it appears on iPhone or Apple Watch.")
                }

                if let lastError = model.lastError {
                    Section {
                        Label(lastError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } header: {
                        Text("Notice")
                    }
                }
            }
            .navigationTitle("Codex Watch")
            .task {
                model.start()
            }
        }
    }

    private var connectionSymbol: String {
        switch model.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "wifi.slash"
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .secondary
        }
    }
}

#Preview {
    PhoneGatewayView(model: PhoneGatewayViewModel())
}
