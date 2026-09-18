import Foundation
import WatchKit

protocol WatchHapticPlaying: AnyObject {
    func play(_ type: WKHapticType)
}

final class WatchHaptics: WatchHapticPlaying {
    func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

enum CrownSelectionTarget: String, Codable {
    case project
    case chat

    var next: CrownSelectionTarget {
        switch self {
        case .project:
            return .chat
        case .chat:
            return .project
        }
    }
}

struct CodexPickerSection: Identifiable {
    let id: String
    let title: String
    let items: [CodexPickerItem]
}

struct VoiceTranscript: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct ReadableMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

struct PendingCodexRequest: Identifiable {
    let id: String
    let method: String?
    let title: String
    let body: String
    let command: String?
    let reason: String?
    let questionID: String?
    let question: String?

    var isInputRequest: Bool {
        method == "item/tool/requestUserInput" || question != nil
    }
}

private struct PersistedVisibleTask: Codable {
    let state: String
    let title: String
    let body: String
    let fullBody: String?
    let hasUnreadMessage: Bool
    let signature: String
}

@MainActor
final class CompanionViewModel: ObservableObject {
    @Published var serverURLString: String {
        didSet {
            defaults.set(serverURLString, forKey: "serverURLString")
        }
    }
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var selectedPet: CodexPet
    @Published private(set) var visualState: PetVisualState = .idle
    @Published private(set) var feedbackVisualState: PetVisualState?
    @Published private(set) var hasUnreadMessage = false
    @Published private(set) var statusTitle = "Codex"
    @Published private(set) var statusBody = L10n.text("Offline")
    @Published private(set) var statusFullBody: String?
    @Published private(set) var isRecording = false
    @Published private(set) var isVoiceModeActive = false
    @Published private(set) var waveformLevels = Array(repeating: 0.03, count: 24)
    @Published private(set) var crownTarget: CrownSelectionTarget
    @Published private(set) var projectIndex: Int
    @Published private(set) var chatIndex: Int
    @Published private(set) var pickerItems: [CodexPickerItem] = []
    @Published var transcriptReview: VoiceTranscript? {
        didSet {
            if let draft = transcriptReview {
                defaults.set(draft.text, forKey: "savedVoiceDraft")
            } else if transcriptBeforeAppend == nil {
                defaults.removeObject(forKey: "savedVoiceDraft")
            }
        }
    }
    private var transcriptBeforeAppend: VoiceTranscript?
    @Published private(set) var isAwaitingVoiceTranscript = false
    @Published private(set) var isRecordingPaused = false

    func pauseRecording() {
        guard isRecording else { cancelVoiceRecording(); return }
        audio.stop()
        isRecording = false
        recordingRequested = false
        isRecordRequestPending = false
        isVoiceModeActive = false
        isRecordingPaused = true
        socket.send(BridgeMessage(type: "mic-pause"))
    }

    func transcribePausedRecording() {
        guard isRecordingPaused else { return }
        isRecordingPaused = false
        isAwaitingVoiceTranscript = true
        visualState = .running
        socket.send(envelope(type: "mic-stop", state: visualState))
        startTranscriptionWait()
    }

    func cancelVoiceRecording() {
        recordingRequested = false
        isRecordRequestPending = false
        audio.stop()
        isRecording = false
        isVoiceModeActive = false
        isRecordingPaused = false
        isAwaitingVoiceTranscript = false
        cancelTranscriptionWait()
        socket.send(BridgeMessage(type: "mic-cancel"))
        restoreAppendDraft()
        statusTitle = L10n.text("Recording cancelled")
        statusBody = L10n.text("You can speak again")
        visualState = .idle
    }
    @Published var messageReader: ReadableMessage?
    @Published private(set) var pendingCodexRequest: PendingCodexRequest?
    @Published var showingSettings = false
    @Published var showingPicker = false
    @Published var showingOnboarding = false

    var hasPetAnnouncement: Bool {
        guard !isVoiceModeActive else { return false }
        if visualState != .idle {
            return true
        }
        let inactiveBodies = [
            "",
            L10n.text("Offline"),
            L10n.text("Linked"),
            L10n.text("Bridge linked"),
            L10n.text("Bridge ready"),
            L10n.text("Pet synced"),
            L10n.text("Digital Crown")
        ]
        return !inactiveBodies.contains(statusBody)
    }

    var petDisplayState: PetVisualState {
        if visualState == .review && !hasUnreadMessage {
            return feedbackVisualState ?? .idle
        }
        return feedbackVisualState ?? visualState
    }

    var petMessageTitle: String {
        if !statusTitle.isEmpty && statusTitle != "Codex" {
            return statusTitle
        }

        switch visualState {
        case .thinking:
            return L10n.text("Thinking")
        case .waiting:
            return L10n.text("Thinking")
        case .running, .runningLeft, .runningRight:
            return L10n.text("Working")
        case .review:
            return L10n.text("Ready")
        case .failed:
            return L10n.text("Needs attention")
        case .waving, .jumping:
            return selectedPet.displayName
        case .idle, .recording:
            return selectedPet.displayName
        }
    }

    var petMessageBody: String {
        let trimmed = statusBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != L10n.text("Linked") && trimmed != L10n.text("Offline") {
            return trimmed
        }

        switch visualState {
        case .thinking:
            return L10n.text("Working on it")
        case .waiting:
            return L10n.text("Waiting for Codex")
        case .running, .runningLeft, .runningRight:
            return L10n.text("Task in progress")
        case .review:
            return L10n.text("Tap into Codex to review")
        case .failed:
            return L10n.text("Open Codex for details")
        case .waving, .jumping:
            return crownTarget == .project ? selectedProjectID : selectedChatID
        case .idle, .recording:
            return connectionState.title
        }
    }

    var petMessageReaderBody: String {
        let trimmedFull = statusFullBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFull.isEmpty {
            return trimmedFull
        }
        return petMessageBody
    }

    var pickerSections: [CodexPickerSection] {
        [
            CodexPickerSection(id: "unread", title: L10n.text("Unread"), items: pickerItems.filter(isUnread)),
            CodexPickerSection(id: "pinned", title: L10n.text("Pinned"), items: pickerItems.filter { isPinned($0) && !isUnread($0) }),
            CodexPickerSection(id: "projects", title: L10n.text("Projects"), items: pickerItems.filter(isProjectListItem)),
            CodexPickerSection(id: "chats", title: L10n.text("Chats"), items: pickerItems.filter(isChatListItem))
        ].filter { !$0.items.isEmpty }
    }

    var unreadPickerItems: [CodexPickerItem] {
        pickerItems.filter(isUnread)
    }

    var pinnedPickerItems: [CodexPickerItem] {
        pickerItems.filter { isPinned($0) && !isUnread($0) }
    }

    var projectPickerItems: [CodexPickerItem] {
        pickerItems.filter(isProjectListItem)
    }

    var directChatPickerItems: [CodexPickerItem] {
        pickerItems.filter(isChatListItem)
    }

    var primaryShortcutLabel: String {
        hasReadableMessage ? L10n.text("Open message") : L10n.text("Start voice")
    }

    var hasReadableMessage: Bool {
        hasPetAnnouncement && !petMessageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let socket: WatchSocketClienting
    private let audio: WatchAudioStreaming
    private let runtimeKeeper: WatchRuntimeKeeping
    private let haptics: WatchHapticPlaying
    private let defaults: UserDefaults
    private var isRecordRequestPending = false
    private var recordingRequested = false
    private var feedbackTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private let transcriptionTimeoutNanoseconds: UInt64
    private var lastHapticSignature: String?
    private var reconnectAttempt = 0
    private var serverURLCandidateIndex = 0
    private var shouldReconnect = true
    private static let persistedVisibleTaskKey = "persistedVisibleTask"
    private static let readVisibleTaskSignatureKey = "readVisibleTaskSignature"
    private static let didCompleteOnboardingKey = "didCompleteOnboarding"
    private static let newChatIDPrefix = "new-chat:"
    private var selectedProjectOverride: String? {
        didSet {
            storeOptional(selectedProjectOverride, key: "selectedProjectID")
        }
    }
    private var selectedChatOverride: String? {
        didSet {
            storeOptional(selectedChatOverride, key: "selectedChatID")
        }
    }

    private var selectedProjectID: String {
        selectedProjectOverride ?? "project-\(projectIndex + 1)"
    }

    private var selectedChatID: String {
        selectedChatOverride ?? "chat-\(chatIndex + 1)"
    }

    private var selectedNewChat: Bool {
        selectedChatOverride?.hasPrefix(Self.newChatIDPrefix) == true
    }

    private static let preferredServerURLString = "ws://codex-watch.local:17842/codex-watch"
    private static let fallbackServerURLStrings = [
        "ws://codex-watch.local:17842/codex-watch",
        "ws://your-mac.local:17842/codex-watch"
    ]

    private var serverURLCandidates: [String] {
        if serverURLString.hasPrefix("https://") { return [serverURLString] }
        var candidates = [serverURLString].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for candidate in Self.fallbackServerURLStrings where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    private var activeServerURLString: String {
        let candidates = serverURLCandidates
        return candidates[serverURLCandidateIndex % candidates.count]
    }

    private var capabilities: [String] {
        [
            "codex-pets",
            "mic-stream-pcm-f32le",
            "tap-to-talk",
            "digital-crown-project-chat",
            "project-chat-picker",
            "new-chat",
            "iphone-gateway",
            "remote-private-network",
            "task-notifications",
            "approval-control",
            "user-input-control"
        ]
    }

    init(
        socket: WatchSocketClienting = WatchSocketClient(),
        audio: WatchAudioStreaming = WatchAudioStreamer(),
        runtimeKeeper: WatchRuntimeKeeping = WatchRuntimeKeeper(),
        haptics: WatchHapticPlaying = WatchHaptics(),
        defaults: UserDefaults = .standard,
        transcriptionTimeoutNanoseconds: UInt64 = 45_000_000_000
    ) {
        self.socket = socket
        self.audio = audio
        self.runtimeKeeper = runtimeKeeper
        self.haptics = haptics
        self.defaults = defaults
        self.transcriptionTimeoutNanoseconds = transcriptionTimeoutNanoseconds

        WatchRemoteCredential.installPending(defaults: defaults)
        let environmentURL = ProcessInfo.processInfo.environment["CODEX_WATCH_SERVER_URL"]
        let savedURL = defaults.string(forKey: "serverURLString")
        self.serverURLString = environmentURL ?? savedURL ?? Self.preferredServerURLString

        let petID = defaults.string(forKey: "selectedPetID")
        self.selectedPet = CodexPet.pet(id: petID)
        self.projectIndex = defaults.integer(forKey: "selectedProjectIndex")
        self.chatIndex = defaults.integer(forKey: "selectedChatIndex")
        let savedTarget = defaults.string(forKey: "crownTarget")
        self.crownTarget = CrownSelectionTarget(rawValue: savedTarget ?? "") ?? .chat
        self.selectedProjectOverride = defaults.string(forKey: "selectedProjectID")
        self.selectedChatOverride = defaults.string(forKey: "selectedChatID")
        self.pickerItems = []
        restorePersistedVisibleTask()
        isAwaitingVoiceTranscript = socket is WatchHTTPBridgeClient && WatchVoiceJobs.shared.job != nil && !WatchVoiceJobs.shared.isFailed
        isRecordingPaused = socket is WatchHTTPBridgeClient && WatchVoiceJobs.shared.isPaused
        if let text = defaults.string(forKey: "savedVoiceDraft") {
            transcriptReview = VoiceTranscript(title: L10n.text("Transcript"), text: text)
        }
        self.showingOnboarding = !defaults.bool(forKey: Self.didCompleteOnboardingKey)
            && !ProcessInfo.processInfo.arguments.contains("--ui-testing")

        socket.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }

        socket.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handle(message)
            }
        }
    }

    func startRuntimeSession() {
        runtimeKeeper.start()
    }

    func connectIfPossible() {
        shouldReconnect = true
        guard connectionState == .disconnected else { return }
        connect()
    }

    func connect() {
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil

        let candidate = activeServerURLString
        guard let url = URL(string: candidate), ["ws", "wss", "https"].contains(url.scheme ?? "") else {
            shouldReconnect = false
            statusTitle = L10n.text("Invalid URL")
            statusBody = candidate
            visualState = .failed
            return
        }
        if !hasPersistentVisibleTask {
            statusTitle = selectedPet.displayName
            statusBody = L10n.text("Linking")
            visualState = .waiting
        }
        socket.connect(to: url, hello: envelope(type: "hello", state: visualState))
    }

    func disconnect() {
        cancelTranscriptionWait()
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopRecording()
        socket.disconnect()
        statusTitle = selectedPet.displayName
        statusBody = L10n.text("Offline")
        visualState = .idle
        clearPersistedVisibleTask()
    }

    private func handleConnectionState(_ state: ConnectionState) {
        connectionState = state
        if state != .connected, transcriptionTask != nil, !(socket is WatchHTTPBridgeClient) {
            failTranscription(L10n.text("The connection was interrupted. Open Codex Watch on iPhone, then record again."))
            if state == .disconnected && shouldReconnect { scheduleReconnect() }
            return
        }

        switch state {
        case .connected:
            promoteActiveServerURL()
            resetReconnect()
            if !isVoiceModeActive && transcriptionTask == nil && !hasPersistentVisibleTask {
                statusTitle = selectedPet.displayName
                visualState = .idle
                statusBody = state.title
            }
        case .connecting:
            if !isVoiceModeActive && !hasPersistentVisibleTask {
                statusTitle = selectedPet.displayName
                visualState = .waiting
                statusBody = state.title
            }
        case .disconnected:
            if !(socket is WatchHTTPBridgeClient) && (isRecording || isRecordRequestPending || isVoiceModeActive) {
                cancelRecordingAfterConnectionLoss()
            }
            if shouldReconnect {
                advanceServerCandidate()
                if !hasPersistentVisibleTask {
                    statusTitle = L10n.text("Bridge error")
                    statusBody = L10n.text("Reconnecting")
                    visualState = .waiting
                }
                scheduleReconnect()
            } else {
                statusTitle = selectedPet.displayName
                statusBody = state.title
                if !isVoiceModeActive {
                    visualState = .idle
                }
                clearPersistedVisibleTask()
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }

        let delay = reconnectDelayNanoseconds()
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                guard self.shouldReconnect, self.connectionState == .disconnected else { return }
                self.connect()
            }
        }
    }

    private func resetReconnect() {
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func advanceServerCandidate() {
        let candidates = serverURLCandidates
        guard candidates.count > 1 else { return }
        serverURLCandidateIndex = (serverURLCandidateIndex + 1) % candidates.count
    }

    private func promoteActiveServerURL() {
        let activeURLString = activeServerURLString
        if serverURLString != activeURLString {
            serverURLString = activeURLString
        }
        serverURLCandidateIndex = 0
    }

    private func reconnectDelayNanoseconds() -> UInt64 {
        let delays: [UInt64] = [
            750_000_000,
            1_500_000_000,
            3_000_000_000,
            6_000_000_000,
            12_000_000_000
        ]
        return delays[min(reconnectAttempt, delays.count - 1)]
    }

    private func cancelRecordingAfterConnectionLoss() {
        restoreAppendDraft()
        recordingRequested = false
        isRecordRequestPending = false
        if isRecording {
            audio.stop()
            isRecording = false
        }
        isVoiceModeActive = false
        resetWaveform()
    }

    func cyclePet() {
        guard let index = CodexPet.builtIns.firstIndex(of: selectedPet) else {
            selectPet(CodexPet.builtIns[0])
            return
        }
        selectPet(CodexPet.builtIns[(index + 1) % CodexPet.builtIns.count])
    }

    func selectPet(_ pet: CodexPet) {
        selectedPet = pet
        defaults.set(selectedPet.id, forKey: "selectedPetID")
        statusTitle = selectedPet.displayName
        socket.send(envelope(type: "pet-selected", state: visualState))
    }

    func showPicker() {
        guard !isVoiceModeActive else { return }
        showingPicker = true
        refreshPickerItems()
    }

    func refreshPickerItems() {
        socket.send(BridgeMessage(
            type: "picker-opened",
            pet: selectedPet.id,
            state: visualState.rawValue,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            action: "open",
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: selectedNewChat
        ))
    }

    func completeOnboarding() {
        defaults.set(true, forKey: Self.didCompleteOnboardingKey)
        showingOnboarding = false
    }

    func selectPickerItem(_ item: CodexPickerItem) {
        if item.chat != selectedChatID {
            transcriptBeforeAppend = nil
            transcriptReview = nil
        }
        // Never display the previous conversation's text or approval controls
        // under a newly selected conversation title.
        statusFullBody = nil
        pendingCodexRequest = nil
        hasUnreadMessage = false
        visualState = .idle
        let target = pickerTarget(for: item)
        crownTarget = target
        defaults.set(crownTarget.rawValue, forKey: "crownTarget")

        if let projectIndex = item.projectIndex {
            self.projectIndex = wrappedIndex(projectIndex)
            defaults.set(self.projectIndex, forKey: "selectedProjectIndex")
        }
        if let chatIndex = item.chatIndex {
            self.chatIndex = wrappedIndex(chatIndex)
            defaults.set(self.chatIndex, forKey: "selectedChatIndex")
        }
        if let project = item.project, !project.isEmpty {
            selectedProjectOverride = project
        } else if target == .project {
            selectedProjectOverride = nil
        }
        if let chat = item.chat, !chat.isEmpty {
            selectedChatOverride = chat
        } else if target == .chat {
            selectedChatOverride = nil
        }

        showingPicker = false
        let selectionBody = item.subtitle ?? (target == .project ? selectedProjectID : selectedChatID)
        statusTitle = item.title
        statusBody = L10n.text("Fetching reply…")
        socket.send(BridgeMessage(
            type: target == .project ? "project-selected" : "chat-selected",
            pet: selectedPet.id,
            state: visualState.rawValue,
            title: item.title,
            body: selectionBody,
            capabilities: capabilities,
            target: target.rawValue,
            action: "select",
            index: target == .project ? projectIndex : chatIndex,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: false
        ))
        pulseFeedback(target == .project ? .jumping : .waving)
        if let data = defaults.data(forKey: "voiceRecoveredResult"),
           let result = try? JSONDecoder().decode(BridgeMessage.self, from: data),
           result.chat == selectedChatID { handle(result) }
    }

    func startNewChat(in project: CodexPickerItem? = nil) {
        transcriptBeforeAppend = nil
        transcriptReview = nil
        statusFullBody = nil
        pendingCodexRequest = nil
        hasUnreadMessage = false
        visualState = .idle
        crownTarget = .chat
        defaults.set(crownTarget.rawValue, forKey: "crownTarget")

        let resolvedProject = project ?? selectedProjectItemForNewChat()
        if let projectIndex = resolvedProject?.projectIndex {
            self.projectIndex = wrappedIndex(projectIndex)
            defaults.set(self.projectIndex, forKey: "selectedProjectIndex")
        }
        if let projectID = resolvedProject?.project, !projectID.isEmpty {
            selectedProjectOverride = projectID
        }

        let projectID = selectedProjectID
        selectedChatOverride = Self.newChatID(for: projectID)
        chatIndex = 0
        defaults.set(chatIndex, forKey: "selectedChatIndex")

        showingPicker = false
        statusTitle = L10n.text("New Chat")
        statusBody = L10n.text("Tap Speak to start a new conversation.")
        socket.send(BridgeMessage(
            type: "chat-selected",
            pet: selectedPet.id,
            state: visualState.rawValue,
            title: "New Chat",
            body: resolvedProject?.subtitle ?? projectID,
            capabilities: capabilities,
            target: CrownSelectionTarget.chat.rawValue,
            action: "new-chat",
            index: chatIndex,
            project: projectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: true
        ))
        pulseFeedback(.waving)
    }

    func performPrimaryShortcut() {
        if hasReadableMessage {
            openCurrentMessage()
        } else if !isVoiceModeActive {
            beginRecording()
        }
    }

    func openCurrentMessage() {
        guard hasReadableMessage else { return }
        let title = petMessageTitle
        let body = petMessageBody
        messageReader = ReadableMessage(
            title: title,
            body: petMessageReaderBody
        )
        hasUnreadMessage = false
        markCurrentVisibleTaskRead()
        socket.send(envelope(type: "message-read", state: .idle, title: title, body: body))
    }

    func replyToCurrentMessage() {
        messageReader = nil
        beginRecording()
    }

    func approvePendingRequest() {
        sendPendingDecision("accept")
    }

    func approvePendingRequestForSession() {
        sendPendingDecision("acceptForSession")
    }

    func declinePendingRequest() {
        sendPendingDecision("decline")
    }

    func cancelPendingRequest() {
        sendPendingDecision("cancel")
    }

    func chatItems(for project: CodexPickerItem) -> [CodexPickerItem] {
        guard let projectID = project.project else { return [] }
        return pickerItems.filter { item in
            isChatListItem(item) && item.project == projectID
        }
    }

    func isSelectedPickerItem(_ item: CodexPickerItem) -> Bool {
        if pickerTarget(for: item) == .project {
            if let project = item.project, !project.isEmpty {
                return project == selectedProjectID
            }
            return selectedProjectOverride == nil && item.projectIndex == projectIndex
        }
        if selectedNewChat {
            return false
        }
        if let chat = item.chat, !chat.isEmpty {
            guard chat == selectedChatID else { return false }
            if let project = item.project, !project.isEmpty {
                return project == selectedProjectID
            }
            return true
        }
        return selectedChatOverride == nil
            && item.chatIndex == chatIndex
            && projectMatchesSelection(item.project)
    }

    func isProjectPickerItem(_ item: CodexPickerItem) -> Bool {
        pickerTarget(for: item) == .project
    }

    func appendRecording() {
        guard let draft = transcriptReview, !isVoiceModeActive, !isRecordRequestPending else { return }
        transcriptBeforeAppend = draft
        transcriptReview = nil
        beginRecording()
    }

    private func restoreAppendDraft() {
        guard let draft = transcriptBeforeAppend else { return }
        transcriptReview = draft
        transcriptBeforeAppend = nil
    }

    func beginRecording() {
        guard !isRecording, !isRecordRequestPending else { return }
        if socket is WatchHTTPBridgeClient, WatchVoiceJobs.shared.hasUnfinishedRecording, !isRecordingPaused {
            statusTitle = L10n.text("Recording is still pending")
            statusBody = L10n.text("The saved recording is being restored. Wait for the transcript before adding more.")
            restoreAppendDraft()
            return
        }
        cancelTranscriptionWait()
        recordingRequested = true
        isRecordRequestPending = true
        isVoiceModeActive = true
        resetWaveform()
        visualState = .recording
        audio.requestPermission { [weak self] allowed in
            guard let self else { return }
            self.isRecordRequestPending = false
            if allowed && self.recordingRequested {
                self.startRecording()
            } else if !allowed {
                self.recordingRequested = false
                self.isVoiceModeActive = false
                self.statusTitle = L10n.text("Mic blocked")
                self.statusBody = L10n.text("Permission denied")
                self.visualState = .failed
                self.restoreAppendDraft()
            } else {
                self.isVoiceModeActive = false
                self.visualState = self.connectionState == .connected ? .idle : .idle
            }
        }
    }

    func retrySavedRecording() {
        isAwaitingVoiceTranscript = true
        WatchVoiceJobs.shared.retry()
        socket.send(BridgeMessage(type: "ping"))
        if connectionState == .disconnected { connectIfPossible() }
    }

    func stopRecording() {
        recordingRequested = false
        isRecordRequestPending = false
        guard isVoiceModeActive || isRecording else { return }
        if isRecording {
            audio.stop()
            isRecording = false
            isAwaitingVoiceTranscript = true
            socket.send(envelope(type: "mic-stop", state: visualState))
            isVoiceModeActive = false
            statusTitle = L10n.text("Transcribing")
            statusBody = L10n.text("Processing audio")
            visualState = .running
            startTranscriptionWait()
            return
        }
        isVoiceModeActive = false
        statusTitle = selectedPet.displayName
        statusBody = connectionState == .connected ? L10n.text("Linked") : L10n.text("Offline")
        visualState = .idle
    }

    func dismissTranscript() {
        cancelTranscriptionWait()
        transcriptBeforeAppend = nil
        transcriptReview = nil
        messageReader = nil
        statusTitle = selectedPet.displayName
        statusBody = connectionState == .connected ? L10n.text("Bridge ready") : L10n.text("Offline")
        visualState = .idle
        clearPersistedVisibleTask()
    }

    func sendTranscript(_ transcript: VoiceTranscript) {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            haptics.play(.failure)
            return
        }

        if let pendingRequest = pendingCodexRequest {
            if pendingRequest.isInputRequest {
                sendPendingInput(text, request: pendingRequest)
                return
            }
            if let decision = approvalDecision(from: text) {
                sendPendingDecision(decision)
                return
            }
            statusTitle = L10n.text("Say approve or deny")
            statusBody = L10n.text("Use the buttons for this request")
            haptics.play(.failure)
            return
        }

        haptics.play(.start)
        transcriptBeforeAppend = nil
        transcriptReview = nil
        messageReader = nil
        statusTitle = L10n.text("Sending")
        statusBody = text
        visualState = .running
        persistVisibleTaskIfNeeded()
        socket.send(BridgeMessage(
            type: "transcript-send",
            pet: selectedPet.id,
            state: PetVisualState.running.rawValue,
            title: transcript.title,
            body: text,
            text: text,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            action: "send",
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: selectedNewChat
        ))
    }

    func rotateCrown(delta: Int) {
        guard delta != 0 else { return }
        let boundedDelta = max(-24, min(24, delta))

        switch crownTarget {
        case .project:
            projectIndex = wrappedIndex(projectIndex + boundedDelta)
            selectedProjectOverride = nil
            defaults.set(projectIndex, forKey: "selectedProjectIndex")
            advertiseSelection(type: "project-selected", delta: boundedDelta)
        case .chat:
            chatIndex = wrappedIndex(chatIndex + boundedDelta)
            selectedChatOverride = nil
            defaults.set(chatIndex, forKey: "selectedChatIndex")
            advertiseSelection(type: "chat-selected", delta: boundedDelta)
        }

        pulseFeedback(.waving)
    }

    func toggleCrownTarget() {
        crownTarget = crownTarget.next
        defaults.set(crownTarget.rawValue, forKey: "crownTarget")
        advertiseSelection(type: "selection-focus", delta: nil)
        pulseFeedback(.jumping)
    }

    func applyUITestScenario(_ scenario: String?) {
        guard let scenario else { return }

        connectionState = .connected
        isRecording = false
        isRecordRequestPending = false
        recordingRequested = false
        feedbackVisualState = nil
        hasUnreadMessage = false
        transcriptReview = nil
        messageReader = nil
        statusFullBody = nil
        showingPicker = false
        showingOnboarding = false
        pendingCodexRequest = nil
        resetWaveform()

        switch scenario {
        case "idle":
            statusTitle = selectedPet.displayName
            statusBody = L10n.text("Bridge ready")
            visualState = .idle
        case "markdown":
            statusTitle = "Markdown"
            statusBody = L10n.text("Use **bold**, `inlineCode`, and [docs](https://example.com) from the watch.")
            visualState = .review
            hasUnreadMessage = true
        case "long-message":
            statusTitle = L10n.text("Codex replied")
            statusBody = L10n.text("This is a longer markdown reply with more than twenty words so the message reader should move the title into the navigation bar and leave the body to start immediately. It keeps enough body text on screen to prove that the reply control belongs to the scroll content instead of being pinned over the bottom edge.")
            visualState = .review
            hasUnreadMessage = true
        case "reader":
            statusTitle = L10n.text("Codex replied")
            statusBody = L10n.text("This is a longer markdown reply with `inlineCode`, **bold text**, and enough content to make the reader feel like a real Codex response.")
            visualState = .review
            messageReader = ReadableMessage(
                title: L10n.text("Codex replied"),
                body: L10n.text("This is a longer markdown reply with `inlineCode`, **bold text**, and enough content to make the reader feel like a real Codex response. The reply button lives at the bottom of the scroll view.")
            )
        case "thinking":
            statusTitle = L10n.text("Codex is thinking")
            statusBody = L10n.text("Working on it")
            visualState = .thinking
        case "error":
            statusTitle = L10n.text("Bridge error")
            statusBody = L10n.text("Reconnect failed")
            visualState = .failed
        case "transcript":
            transcriptReview = VoiceTranscript(
                title: L10n.text("Transcript"),
                text: "Ship `inlineCode` with **bold** confidence."
            )
            statusTitle = selectedPet.displayName
            statusBody = L10n.text("Bridge ready")
            visualState = .idle
        case "voice":
            waveformLevels = [0.12, 0.42, 0.2, 0.72, 0.36, 0.88, 0.44, 0.66, 0.24, 0.52, 0.18, 0.38]
            isVoiceModeActive = true
            visualState = .recording
            statusTitle = L10n.text("Listening")
            statusBody = selectedPet.displayName
        case "picker":
            pickerItems = []
            showingPicker = true
            statusTitle = selectedPet.displayName
            statusBody = L10n.text("Bridge ready")
            visualState = .idle
        case "picker-many":
            pickerItems = Self.manyPickerItems()
            showingPicker = true
            statusTitle = selectedPet.displayName
            statusBody = L10n.text("Bridge ready")
            visualState = .idle
        case "onboarding":
            pickerItems = Self.manyPickerItems()
            showingOnboarding = true
            statusTitle = selectedPet.displayName
            statusBody = L10n.text("Bridge ready")
            visualState = .idle
        default:
            break
        }
    }

    private func startRecording() {
        do {
            try audio.start { [weak self] chunk in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.pushAudioLevel(chunk.level)
                    self.socket.send(self.envelope(
                        type: "mic-chunk",
                        state: .recording,
                        sampleRate: chunk.sampleRate,
                        channels: chunk.channels,
                        encoding: chunk.encoding,
                        data: chunk.data.base64EncodedString(),
                        bytes: chunk.data.count
                    ))
                }
            }
            socket.send(envelope(type: "mic-start", state: .recording))
            isRecordingPaused = false
            isRecording = true
            isVoiceModeActive = true
            statusTitle = L10n.text("Listening")
            statusBody = selectedPet.displayName
            visualState = .recording
        } catch {
            recordingRequested = false
            isRecordRequestPending = false
            isVoiceModeActive = false
            statusTitle = L10n.text("Mic error")
            statusBody = error.localizedDescription
            visualState = .failed
            isRecording = false
            restoreAppendDraft()
        }
    }

    private func handle(_ message: BridgeMessage) {
        switch message.type {
        case "voice-empty":
            isAwaitingVoiceTranscript = false
            cancelTranscriptionWait()
            restoreAppendDraft()
            statusTitle = L10n.text("No speech was detected")
            statusBody = L10n.text("Please record again")
            visualState = .idle
        case "voice-failed":
            isAwaitingVoiceTranscript = false
            cancelTranscriptionWait()
            statusTitle = L10n.text("Recording saved")
            statusBody = message.body.map(L10n.bridgeText) ?? L10n.text("Reconnect later to resume transcription.")
            visualState = .failed
        case "voice-pending", "voice-missing":
            if !isRecording {
                isAwaitingVoiceTranscript = true
                statusTitle = L10n.text("Recording saved")
                statusBody = L10n.text("Uploading or transcribing. The result will return when the app resumes.")
                visualState = .running
            }
        case "state":
            if transcriptionTask != nil, message.state == "idle", message.event == nil {
                return
            }
            if message.title == "Transcribing" {
                startTranscriptionWait()
            } else if message.state == "failed" || message.event != nil {
                cancelTranscriptionWait()
                clearPersistedVisibleTask()
            }
            if let items = message.items {
                updatePickerItems(items)
            }
            if let pet = message.pet {
                selectedPet = CodexPet.pet(id: pet)
            }
            if message.project != nil || message.chat != nil || message.projectIndex != nil || message.chatIndex != nil || message.newChat != nil {
                applySelection(message)
            }
            if let state = message.state, let visual = PetVisualState.desktopState(from: state) {
                if shouldIgnoreReadReplay(message, visual: visual) || shouldIgnoreGenericIdle(message, visual: visual) {
                    return
                }
                visualState = isVoiceModeActive ? .recording : visual
                hasUnreadMessage = visual == .review
            }
            if let title = message.title, title != "Codex" {
                statusTitle = L10n.bridgeText(title)
            } else if !isRecording {
                statusTitle = selectedPet.displayName
            }
            statusBody = message.body.map(L10n.bridgeText) ?? statusBody
            statusFullBody = message.text ?? message.body.map(L10n.bridgeText) ?? statusFullBody
            updatePendingRequest(from: message)
            persistVisibleTaskIfNeeded()
            playFeedback(for: message)
        case "error":
            cancelTranscriptionWait()
            restoreAppendDraft()
            if !(socket is WatchHTTPBridgeClient) && (isRecording || isVoiceModeActive || isRecordRequestPending) {
                cancelRecordingAfterConnectionLoss()
            }
            clearPersistedVisibleTask()
            if shouldReconnect && isTransientConnectionError(message.body) {
                statusTitle = L10n.text("Reconnecting")
                statusBody = L10n.text("Connecting to Mac")
                visualState = .waiting
                scheduleReconnect()
            } else {
                statusTitle = L10n.text("Bridge error")
                playHaptic(.failure, signature: "error:\(message.body ?? "unknown")")
                statusBody = message.body.map(L10n.bridgeText) ?? L10n.text("Unknown")
                visualState = .failed
            }
        case "pong":
            statusBody = L10n.text("Linked")
        case "picker-items":
            updatePickerItems(message.items ?? [])
        case "transcript":
            if let id = message.requestID {
                if let chat = message.chat, chat != selectedChatID { return }
                guard defaults.string(forKey: "lastVoiceResultID") != id else { return }
                if transcriptBeforeAppend == nil, let original = defaults.string(forKey: "savedVoiceDraft") {
                    transcriptBeforeAppend = VoiceTranscript(title: L10n.text("Transcript"), text: original)
                }
            }
            cancelTranscriptionWait()
            isAwaitingVoiceTranscript = false
            let text = (message.text ?? message.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let original = transcriptBeforeAppend
            transcriptBeforeAppend = nil
            let combined = [original?.text, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            transcriptReview = VoiceTranscript(
                title: original?.title ?? message.title.map(L10n.bridgeText) ?? L10n.text("Transcript"),
                text: combined.isEmpty ? L10n.text("No transcript text was returned.") : combined
            )
            if let id = message.requestID { defaults.set(id, forKey: "lastVoiceResultID") }
            playHaptic(.notification, signature: "transcript:\(text.prefix(96))")
            statusTitle = selectedPet.displayName
            statusBody = connectionState == .connected ? L10n.text("Bridge ready") : L10n.text("Offline")
            visualState = .idle
            clearPersistedVisibleTask()
        case "selection", "selection-focus", "project-selected", "chat-selected":
            applySelection(message)
        default:
            statusBody = message.text ?? message.body ?? statusBody
        }
    }

    private func updatePendingRequest(from message: BridgeMessage) {
        guard let event = message.event else { return }
        switch event {
        case "approval-needed", "input-needed":
            guard let requestID = message.requestID, !requestID.isEmpty else { return }
            pendingCodexRequest = PendingCodexRequest(
                id: requestID,
                method: message.requestMethod,
                title: message.title.map(L10n.bridgeText) ?? L10n.text(event == "input-needed" ? "Input needed" : "Approval needed"),
                body: message.body.map(L10n.bridgeText) ?? L10n.text("Codex is waiting for your response"),
                command: message.command,
                reason: message.reason,
                questionID: message.questionID,
                question: message.question
            )
        case "task-complete", "task-failed":
            pendingCodexRequest = nil
        default:
            break
        }
    }

    private func sendPendingDecision(_ decision: String) {
        guard let request = pendingCodexRequest else { return }
        pendingCodexRequest = nil
        transcriptReview = nil
        messageReader = nil
        statusTitle = L10n.text("Response sent")
        statusBody = L10n.text("Codex is continuing")
        visualState = .thinking
        haptics.play(decision == "decline" || decision == "cancel" ? .failure : .success)
        socket.send(BridgeMessage(
            type: "approval-response",
            pet: selectedPet.id,
            state: PetVisualState.thinking.rawValue,
            title: request.title,
            body: request.body,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            requestID: request.id,
            requestMethod: request.method,
            decision: decision,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: selectedNewChat
        ))
    }

    private func sendPendingInput(_ answer: String, request: PendingCodexRequest) {
        pendingCodexRequest = nil
        transcriptReview = nil
        messageReader = nil
        statusTitle = L10n.text("Response sent")
        statusBody = L10n.text("Codex is continuing")
        visualState = .thinking
        haptics.play(.success)
        socket.send(BridgeMessage(
            type: "input-response",
            pet: selectedPet.id,
            state: PetVisualState.thinking.rawValue,
            title: request.title,
            body: answer,
            text: answer,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            requestID: request.id,
            requestMethod: request.method,
            questionID: request.questionID,
            answer: answer,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: selectedNewChat
        ))
    }

    private func approvalDecision(from text: String) -> String? {
        let normalized = text.lowercased()
        if ["批准", "同意", "允许", "可以", "继续", "approve", "approved", "allow", "yes", "ok"].contains(where: { normalized.contains($0) }) {
            return "accept"
        }
        if ["拒绝", "不同意", "不允许", "否", "取消", "deny", "denied", "decline", "cancel", "no"].contains(where: { normalized.contains($0) }) {
            return "decline"
        }
        return nil
    }

    private func envelope(
        type: String,
        state: PetVisualState,
        title: String? = nil,
        body: String? = nil,
        sampleRate: Double? = nil,
        channels: Int? = nil,
        encoding: String? = nil,
        data: String? = nil,
        bytes: Int? = nil,
        items: [CodexPickerItem]? = nil
    ) -> BridgeMessage {
        BridgeMessage(
            type: type,
            pet: selectedPet.id,
            state: state.rawValue,
            title: title,
            body: body,
            sampleRate: sampleRate,
            channels: channels,
            encoding: encoding,
            data: data,
            bytes: bytes,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            items: items,
            newChat: selectedNewChat
        )
    }

    private func advertiseSelection(type: String, delta: Int?) {
        socket.send(BridgeMessage(
            type: type,
            pet: selectedPet.id,
            state: visualState.rawValue,
            body: "Digital Crown",
            capabilities: capabilities,
            target: crownTarget.rawValue,
            action: actionName(for: delta),
            delta: delta,
            index: crownTarget == .project ? projectIndex : chatIndex,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: selectedNewChat
        ))
    }

    private func applySelection(_ message: BridgeMessage) {
        if let target = message.target, let value = CrownSelectionTarget(rawValue: target) {
            crownTarget = value
            defaults.set(value.rawValue, forKey: "crownTarget")
        }
        if let projectIndex = message.projectIndex {
            self.projectIndex = wrappedIndex(projectIndex)
            defaults.set(self.projectIndex, forKey: "selectedProjectIndex")
        }
        if let chatIndex = message.chatIndex {
            self.chatIndex = wrappedIndex(chatIndex)
            defaults.set(self.chatIndex, forKey: "selectedChatIndex")
        }
        if let project = message.project, !project.isEmpty {
            selectedProjectOverride = project
        }
        if let chat = message.chat, !chat.isEmpty {
            selectedChatOverride = chat
        } else if message.newChat == false {
            selectedChatOverride = nil
        }
        if message.newChat == false, let chat = message.chat, !chat.hasPrefix(Self.newChatIDPrefix) {
            selectedChatOverride = chat
        }
    }

    private func selectedProjectItemForNewChat() -> CodexPickerItem? {
        if let exact = projectPickerItems.first(where: { $0.project == selectedProjectID }) {
            return exact
        }
        if selectedProjectOverride == nil {
            return projectPickerItems.first(where: { $0.projectIndex == projectIndex }) ?? projectPickerItems.first
        }
        return projectPickerItems.first
    }

    private func updatePickerItems(_ items: [CodexPickerItem]) {
        pickerItems = items
    }

    private func isUnread(_ item: CodexPickerItem) -> Bool {
        item.section?.lowercased() == "unread" || item.unread == true
    }

    private func isPinned(_ item: CodexPickerItem) -> Bool {
        item.section?.lowercased() == "pinned" || item.pinned == true
    }

    private func isProjectListItem(_ item: CodexPickerItem) -> Bool {
        guard !isUnread(item), !isPinned(item) else { return false }
        let section = item.section?.lowercased()
        return section == "projects" || section == "project" || pickerTarget(for: item) == .project
    }

    private func isChatListItem(_ item: CodexPickerItem) -> Bool {
        guard !isUnread(item), !isPinned(item) else { return false }
        let section = item.section?.lowercased()
        return section == "chats" || section == "chat" || pickerTarget(for: item) == .chat
    }

    private func pickerTarget(for item: CodexPickerItem) -> CrownSelectionTarget {
        let kind = item.kind?.lowercased()
        let section = item.section?.lowercased()
        if kind == "project" || section == "projects" || (item.project != nil && item.chat == nil) {
            return .project
        }
        return .chat
    }

    private func actionName(for delta: Int?) -> String {
        guard let delta, delta != 0 else { return "focus" }
        return delta > 0 ? "next" : "previous"
    }

    private func projectMatchesSelection(_ project: String?) -> Bool {
        guard let project, !project.isEmpty else {
            return true
        }
        return project == selectedProjectID
    }

    private static func newChatID(for project: String) -> String {
        "\(newChatIDPrefix)\(project)"
    }

    private func reconnectingStatusBody(for errorBody: String?) -> String {
        guard let errorBody else { return L10n.text("Reconnecting") }
        if errorBody.localizedCaseInsensitiveContains("offline") {
            return L10n.text("Watch network offline")
        }
        return L10n.text("Reconnecting")
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
            "offline",
            "中断",
            "未连接"
        ]
        return markers.contains(where: normalized.contains)
    }

    private func wrappedIndex(_ index: Int) -> Int {
        let count = 100
        return (index % count + count) % count
    }

    private func resetWaveform() {
        waveformLevels = Array(repeating: 0.03, count: waveformLevels.count)
    }

    private func pushAudioLevel(_ level: Double) {
        waveformLevels.removeFirst()
        waveformLevels.append(level)
    }

    private func playFeedback(for message: BridgeMessage) {
        let title = message.title ?? ""
        let state = message.state ?? ""
        let body = message.body ?? ""

        if state == PetVisualState.failed.rawValue {
            playHaptic(.failure, signature: "failed:\(title):\(body.prefix(96))")
        } else if title == "Codex replied" {
            playHaptic(.notification, signature: "reply:\(body.prefix(96))")
        } else if state == PetVisualState.thinking.rawValue || title == "Codex started" || title == "Codex is thinking" {
            playHaptic(.success, signature: "started:\(selectedChatID):\(body.prefix(96))")
        }
    }

    private func playHaptic(_ type: WKHapticType, signature: String) {
        guard lastHapticSignature != signature else { return }
        lastHapticSignature = signature
        haptics.play(type)
    }

    private func pulseFeedback(_ state: PetVisualState) {
        guard !isVoiceModeActive else { return }
        feedbackTask?.cancel()
        feedbackVisualState = state
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run {
                guard let self, !self.isVoiceModeActive else { return }
                self.feedbackVisualState = nil
            }
        }
    }

    private var hasPersistentVisibleTask: Bool {
        persistentVisibleTaskState != nil
    }

    private var persistentVisibleTaskState: PetVisualState? {
        // Recording/transcription are local, temporary operations, not Codex
        // tasks. Never restore them after a disconnect or app relaunch.
        guard !matchesStatus(statusTitle, key: "Transcribing"), !matchesStatus(statusTitle, key: "Listening") else { return nil }
        switch visualState {
        case .review:
            return hasUnreadMessage ? .review : nil
        case .thinking, .running, .runningLeft, .runningRight:
            return visualState
        case .waiting:
            return matchesStatus(statusTitle, key: "Queued") || statusTitle == "已排队" ? .waiting : nil
        case .idle, .failed, .waving, .jumping, .recording:
            return nil
        }
    }

    private func restorePersistedVisibleTask() {
        guard
            let data = defaults.data(forKey: Self.persistedVisibleTaskKey),
            let task = try? JSONDecoder().decode(PersistedVisibleTask.self, from: data),
            let state = PetVisualState.desktopState(from: task.state)
        else { return }

        guard !matchesStatus(task.title, key: "Transcribing"), !matchesStatus(task.title, key: "Listening") else {
            clearPersistedVisibleTask()
            return
        }

        visualState = state
        statusTitle = task.title
        statusBody = task.body
        statusFullBody = task.fullBody
        hasUnreadMessage = task.hasUnreadMessage && state == .review
    }

    private func persistVisibleTaskIfNeeded() {
        guard let state = persistentVisibleTaskState else {
            clearPersistedVisibleTask()
            return
        }
        let signature = visibleTaskSignature(
            state: state,
            title: petMessageTitle,
            body: petMessageBody,
            fullBody: petMessageReaderBody
        )
        if state != .review {
            defaults.removeObject(forKey: Self.readVisibleTaskSignatureKey)
        }
        let task = PersistedVisibleTask(
            state: state.rawValue,
            title: petMessageTitle,
            body: petMessageBody,
            fullBody: petMessageReaderBody,
            hasUnreadMessage: hasUnreadMessage,
            signature: signature
        )
        guard let data = try? JSONEncoder().encode(task) else { return }
        defaults.set(data, forKey: Self.persistedVisibleTaskKey)
    }

    private func clearPersistedVisibleTask() {
        defaults.removeObject(forKey: Self.persistedVisibleTaskKey)
    }

    private func startTranscriptionWait() {
        if socket is WatchHTTPBridgeClient {
            statusTitle = L10n.text("Recording saved")
            statusBody = L10n.text("Uploading or transcribing. You can lower your wrist.")
            return
        }
        guard transcriptionTask == nil else { return }
        clearPersistedVisibleTask()
        let timeout = transcriptionTimeoutNanoseconds
        transcriptionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) }
            catch { return }
            self?.failTranscription(L10n.text("Transcription timed out. Check the iPhone and Mac connection, then record again."))
        }
    }

    private func cancelTranscriptionWait() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private func failTranscription(_ reason: String) {
        isAwaitingVoiceTranscript = false
        cancelTranscriptionWait()
        restoreAppendDraft()
        statusTitle = L10n.text("Voice request incomplete")
        statusBody = reason
        statusFullBody = reason
        visualState = .failed
        clearPersistedVisibleTask()
    }

    private func markCurrentVisibleTaskRead() {
        let signature = visibleTaskSignature(
            state: visualState,
            title: petMessageTitle,
            body: petMessageBody,
            fullBody: petMessageReaderBody
        )
        defaults.set(signature, forKey: Self.readVisibleTaskSignatureKey)
        clearPersistedVisibleTask()
    }

    private func shouldIgnoreGenericIdle(_ message: BridgeMessage, visual: PetVisualState) -> Bool {
        guard visual == .idle, hasPersistentVisibleTask else { return false }
        let title = message.title ?? ""
        let body = message.body ?? ""
        return title.isEmpty
            || title == "Codex"
            || matchesStatus(body, key: "Bridge linked")
            || matchesStatus(body, key: "Bridge ready")
            || matchesStatus(body, key: "Linked")
    }

    private func shouldIgnoreReadReplay(_ message: BridgeMessage, visual: PetVisualState) -> Bool {
        guard visual == .review, let readSignature = defaults.string(forKey: Self.readVisibleTaskSignatureKey) else {
            return false
        }
        let signature = visibleTaskSignature(
            state: visual,
            title: message.title ?? "",
            body: message.body ?? "",
            fullBody: message.text ?? message.body ?? ""
        )
        if signature == readSignature {
            clearPersistedVisibleTask()
            return true
        }
        return false
    }

    private func visibleTaskSignature(state: PetVisualState, title: String, body: String, fullBody: String?) -> String {
        [
            state.rawValue,
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            (fullBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    private func storeOptional(_ value: String?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func matchesStatus(_ value: String, key: String) -> Bool {
        value == key || value == L10n.text(key)
    }

    private static func defaultPickerItems(projectIndex: Int, chatIndex: Int) -> [CodexPickerItem] {
        [
            CodexPickerItem(
                id: "unread-chat-\(chatIndex + 1)",
                title: "Latest Codex reply",
                subtitle: "chat-\(chatIndex + 1)",
                kind: "chat",
                section: "unread",
                project: "project-\(projectIndex + 1)",
                chat: "chat-\(chatIndex + 1)",
                projectIndex: projectIndex,
                chatIndex: chatIndex,
                unread: true
            ),
            CodexPickerItem(
                id: "pinned-project-\(projectIndex + 1)",
                title: "Pinned project",
                subtitle: "project-\(projectIndex + 1)",
                kind: "project",
                section: "pinned",
                project: "project-\(projectIndex + 1)",
                projectIndex: projectIndex,
                pinned: true
            ),
            CodexPickerItem(
                id: "project-1",
                title: "Project 1",
                subtitle: "project-1",
                kind: "project",
                section: "projects",
                project: "project-1",
                projectIndex: 0
            ),
            CodexPickerItem(
                id: "project-2",
                title: "Project 2",
                subtitle: "project-2",
                kind: "project",
                section: "projects",
                project: "project-2",
                projectIndex: 1
            ),
            CodexPickerItem(
                id: "chat-1",
                title: "Chat 1",
                subtitle: "project-\(projectIndex + 1)",
                kind: "chat",
                section: "chats",
                project: "project-\(projectIndex + 1)",
                chat: "chat-1",
                projectIndex: projectIndex,
                chatIndex: 0
            ),
            CodexPickerItem(
                id: "chat-2",
                title: "Chat 2",
                subtitle: "project-\(projectIndex + 1)",
                kind: "chat",
                section: "chats",
                project: "project-\(projectIndex + 1)",
                chat: "chat-2",
                projectIndex: projectIndex,
                chatIndex: 1
            )
        ]
    }

    private static func manyPickerItems() -> [CodexPickerItem] {
        var items: [CodexPickerItem] = []
        for projectIndex in 0..<8 {
            let projectID = "project-\(projectIndex + 1)"
            items.append(CodexPickerItem(
                id: projectID,
                title: "Project \(projectIndex + 1)",
                subtitle: "~/Projects/project-\(projectIndex + 1)",
                kind: "project",
                section: "projects",
                project: projectID,
                projectIndex: projectIndex
            ))
            for chatIndex in 0..<8 {
                items.append(CodexPickerItem(
                    id: "\(projectID)-chat-\(chatIndex + 1)",
                    title: "Chat \(chatIndex + 1)",
                    subtitle: "Project \(projectIndex + 1)",
                    kind: "chat",
                    section: "chats",
                    project: projectID,
                    chat: "\(projectID)-chat-\(chatIndex + 1)",
                    projectIndex: projectIndex,
                    chatIndex: chatIndex
                ))
            }
        }
        return items
    }
}
