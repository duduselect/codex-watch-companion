import Foundation
import SwiftUI

@MainActor
final class PhoneGatewayViewModel: ObservableObject {
    @Published var bridgeURLString: String {
        didSet {
            defaults.set(bridgeURLString, forKey: Self.bridgeURLKey)
        }
    }
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isWatchReachable = false
    @Published private(set) var latestEventTitle = L10n.text("No Codex event yet")
    @Published private(set) var latestEventBody = L10n.text("The iPhone gateway will show the latest task state here.")
    @Published private(set) var latestEventDate: Date?
    @Published private(set) var lastError: String?

    var isConnected: Bool {
        connectionState == .connected
    }

    var connectionLabel: String {
        switch connectionState {
        case .connected:
            return L10n.text("Mac connected")
        case .connecting:
            return L10n.text("Connecting to Mac")
        case .disconnected:
            return L10n.text("Mac offline")
        }
    }

    var watchLabel: String {
        guard relay.isSupported else { return L10n.text("WatchConnectivity unavailable") }
        return isWatchReachable ? L10n.text("Watch reachable") : L10n.text("Waiting for Watch")
    }

    private static let bridgeURLKey = "phoneBridgeURLString"
    // A local build can inject a private default through the ignored
    // .codex-watch/local.env file. Public builds fall back to a readable
    // placeholder and keep the value editable in the app.
    private static var defaultBridgeURL: String {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CodexWatchDefaultBridgeURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty, !configured.contains("$(") {
            return configured
        }
        return "ws://your-mac.local:17842/codex-watch"
    }

    private let socket: WatchSocketClienting
    private let relay: WatchConnectivityRelay
    private let notificationService: PhoneNotificationService
    private let defaults: UserDefaults
    private var pendingWatchMessages: [BridgeMessage] = []
    private var didStart = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private var selectionHello = BridgeMessage(type: "hello", pet: "codex")
    private static let selectionHelloKey = "gatewaySelectionHello"

    init(
        socket: WatchSocketClienting = WatchSocketClient(),
        relay: WatchConnectivityRelay = .shared,
        notificationService: PhoneNotificationService = PhoneNotificationService(),
        defaults: UserDefaults = .standard
    ) {
        self.socket = socket
        self.relay = relay
        self.notificationService = notificationService
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.selectionHelloKey),
           let saved = try? JSONDecoder().decode(BridgeMessage.self, from: data) {
            selectionHello.updateSelection(from: saved)
        }
        self.bridgeURLString = defaults.string(forKey: Self.bridgeURLKey) ?? Self.defaultBridgeURL

        socket.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        socket.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleBridgeMessage(message)
            }
        }

        relay.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleWatchMessage(message)
            }
        }
        relay.onReachabilityChanged = { [weak self] reachable in
            Task { @MainActor in
                self?.isWatchReachable = reachable
            }
        }
        notificationService.onAction = { [weak self] action, requestID in
            Task { @MainActor in
                self?.handleNotificationAction(action: action, requestID: requestID)
            }
        }
        relay.activate()
        notificationService.configure()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        notificationService.requestAuthorization()
        connect()
    }

    func connect() {
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        startSocketConnection()
    }

    private func startSocketConnection() {
        lastError = nil
        guard
            let url = URL(string: bridgeURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["ws", "wss"].contains(url.scheme?.lowercased() ?? "")
        else {
            connectionState = .disconnected
            lastError = L10n.text("Enter a Mac address beginning with ws:// or wss://.")
            return
        }

        var hello = BridgeMessage(
            type: "hello",
            pet: "codex",
            capabilities: [
                "iphone-gateway",
                "remote-private-network",
                "task-notifications",
                "approval-control",
                "user-input-control",
                "project-chat-picker",
                "new-chat"
            ]
        )
        hello.updateSelection(from: selectionHello)
        socket.connect(to: url, hello: hello)
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        socket.disconnect()
        pendingWatchMessages.removeAll()
    }

    func requestNotificationPermission() {
        notificationService.requestAuthorization()
    }

    func sendTestNotification() {
        notificationService.sendTestNotification()
    }

    private func handleConnectionState(_ state: ConnectionState) {
        connectionState = state
        switch state {
        case .connected:
            lastError = nil
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            flushPendingWatchMessages()
        case .connecting:
            // Keep the gateway visibly alive while the Mac socket is being
            // re-established after a transient Wi-Fi or process interruption.
            break
        case .disconnected:
            guard shouldReconnect else { return }
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }

        connectionState = .connecting
        let delays: [UInt64] = [
            750_000_000,
            1_500_000_000,
            3_000_000_000,
            6_000_000_000,
            12_000_000_000
        ]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.shouldReconnect else { return }
                self.reconnectTask = nil
                self.startSocketConnection()
            }
        }
    }

    private func handleWatchMessage(_ message: BridgeMessage) {
        rememberSelection(message)
        if message.type == "hello" {
            isWatchReachable = true
        }

        guard connectionState == .connected else {
            // Audio cannot be replayed meaningfully. Keep only low-frequency
            // control messages until the Mac socket is ready.
            if message.type.hasPrefix("mic-") {
                lastError = L10n.text("The Mac is offline, so watch audio cannot be sent yet.")
                if message.type != "mic-chunk" {
                    relay.send(BridgeMessage(type: "error", body: lastError))
                }
                return
            }
            if pendingWatchMessages.count < 32 {
                pendingWatchMessages.append(message)
            }
            return
        }
        socket.send(message)
    }

    private func flushPendingWatchMessages() {
        let messages = pendingWatchMessages
        pendingWatchMessages.removeAll()
        for message in messages {
            socket.send(message)
        }
    }

    private func handleBridgeMessage(_ message: BridgeMessage) {
        if let chat = message.chat, chat != "chat", !chat.hasPrefix("chat-") {
            rememberSelection(message)
        }
        print("CodexWatch gateway received type=\(message.type) state=\(message.state ?? "-") title=\(message.title ?? "-") chat=\(message.chat ?? "-") reachable=\(relay.isReachable)")
        if message.type == "error", isTransientConnectionError(message.body) {
            lastError = message.body.map(L10n.bridgeText)
            relay.send(BridgeMessage(
                type: "state",
                state: "waiting",
                title: "Reconnecting",
                body: "Connecting to Mac"
            ), fallbackToTransfer: true)
            return
        }

        if let title = message.title, !title.isEmpty {
            latestEventTitle = L10n.bridgeText(title)
        }
        let body = message.body ?? message.text
        if let body, !body.isEmpty {
            latestEventBody = L10n.bridgeText(body)
        }
        latestEventDate = Date()

        if let event = message.event, !event.isEmpty {
            notificationService.handle(message)
            if event == "task-failed" {
                lastError = message.body.map(L10n.bridgeText)
            }
        }

        // The watch may be in the background. Queue only durable states and
        // one-time events; dropping intermediate previews avoids filling the
        // WatchConnectivity transfer queue during a long-running turn.
        let shouldQueueForWatch = message.event != nil
            || message.items != nil
            || message.state == "review"
            || (message.state == "waiting" && ["Queued", "已排队"].contains(message.title ?? ""))
            || message.state == "failed"
            || message.type == "transcript"
            || message.type == "picker-items"
        relay.send(message, fallbackToTransfer: shouldQueueForWatch)
    }

    private func isTransientConnectionError(_ body: String?) -> Bool {
        guard let body else { return false }
        let normalized = body.lowercased()
        let markers = [
            "network error",
            "connection",
            "socket",
            "timed out",
            "timeout",
            "software caused",
            "http bridge",
            "offline"
        ]
        return markers.contains(where: normalized.contains)
    }

    private func rememberSelection(_ message: BridgeMessage) {
        selectionHello.updateSelection(from: message)
        if let data = try? JSONEncoder().encode(selectionHello) {
            defaults.set(data, forKey: Self.selectionHelloKey)
        }
    }

    private func handleNotificationAction(action: String, requestID: String?) {
        guard let requestID, !requestID.isEmpty else { return }
        let decision: String
        switch action {
        case "approve":
            decision = "accept"
        case "approve-session":
            decision = "acceptForSession"
        case "decline":
            decision = "decline"
        case "cancel":
            decision = "cancel"
        default:
            return
        }

        handleWatchMessage(BridgeMessage(
            type: "approval-response",
            requestID: requestID,
            decision: decision
        ))
    }
}
