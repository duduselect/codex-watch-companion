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
                    Text("连接状态")
                }

                Section {
                    TextField("ws://Mac 地址:17842/codex-watch", text: $model.bridgeURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        model.connect()
                    } label: {
                        Label("连接 Mac", systemImage: "bolt.horizontal.fill")
                    }

                    Button {
                        model.disconnect()
                    } label: {
                        Label("断开", systemImage: "xmark.circle")
                    }
                    .disabled(!model.isConnected && model.connectionState != .connecting)
                } header: {
                    Text("Mac Codex 桥接地址")
                } footer: {
                    Text("人在外面时，把这里填成 Mac 的 Tailscale 私网地址，例如 ws://100.x.y.z:17842/codex-watch。首次连接时请允许本地网络和通知权限。")
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
                    Text("最近的 Codex 状态")
                }

                Section {
                    Button {
                        model.requestNotificationPermission()
                    } label: {
                        Label("允许任务通知", systemImage: "bell.badge")
                    }

                    Button {
                        model.sendTestNotification()
                    } label: {
                        Label("发送测试通知", systemImage: "paperplane")
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("任务完成、失败、需要审批或等待输入时，iPhone 会创建本地通知；系统会按 Apple 的通知规则把它显示到 iPhone 或 Apple Watch。")
                }

                if let lastError = model.lastError {
                    Section {
                        Label(lastError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } header: {
                        Text("提示")
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
