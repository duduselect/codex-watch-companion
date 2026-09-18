import SwiftUI

private let codexPetFrameAspect: CGFloat = 192.0 / 208.0
private let pickerVisibleItemLimit = 6

struct CompanionRootView: View {
    @ObservedObject var model: CompanionViewModel

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.environment["CODEX_WATCH_UI_TEST_SCENARIO"] == "transcript" {
                NavigationStack { CompanionWatchContent(model: model) }
            } else {
                TaskListHomeView(model: model)
            }
        }
        .background(.black)
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model)
        }
        .sheet(item: $model.messageReader) { message in
            MessageReaderView(
                message: message,
                reply: {
                    model.replyToCurrentMessage()
                }
            )
        }
    }
}

private struct TaskListHomeView: View {
    @ObservedObject var model: CompanionViewModel

    var body: some View {
        NavigationStack {
            List {
                if model.pickerItems.isEmpty {
                    Text("Fetching projects and conversations…\nKeep iPhone and Mac connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !model.unreadPickerItems.isEmpty {
                    Section("Unread") { rows(model.unreadPickerItems) }
                }
                if !model.pinnedPickerItems.isEmpty {
                    Section("Pinned") { rows(model.pinnedPickerItems) }
                }
                Section("Projects") { rows(model.projectPickerItems) }
                if !model.directChatPickerItems.isEmpty {
                    Section("Chats") { rows(model.directChatPickerItems) }
                }
                Section {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refreshPickerItems()
                    }
                    Button("Connection Settings", systemImage: "gearshape") {
                        model.showingSettings = true
                    }
                }
            }
            .navigationTitle("Projects & Chats")
            .accessibilityIdentifier("task-list-home")
            .onAppear { model.refreshPickerItems() }
        }
    }

    @ViewBuilder
    private func rows(_ items: [CodexPickerItem]) -> some View {
        ForEach(items) { item in
            if model.isProjectPickerItem(item) {
                NavigationLink {
                    TaskProjectView(model: model, project: item)
                } label: {
                    PickerItemRow(item: item, isSelected: false)
                }
            } else {
                TaskConversationLink(model: model, item: item)
            }
        }
    }
}

private struct TaskProjectView: View {
    @ObservedObject var model: CompanionViewModel
    let project: CodexPickerItem

    var body: some View {
        List {
            let chats = model.chatItems(for: project)
            if chats.isEmpty { Text("No chats").foregroundStyle(.secondary) }
            ForEach(chats) { item in
                TaskConversationLink(model: model, item: item)
            }
            NavigationLink {
                CompanionWatchContent(model: model)
                    .navigationTitle("New Chat")
                    .onAppear { model.startNewChat(in: project) }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        .navigationTitle(project.title)
    }
}

private struct TaskConversationLink: View {
    @ObservedObject var model: CompanionViewModel
    let item: CodexPickerItem

    var body: some View {
        NavigationLink {
            CompanionWatchContent(model: model)
                .navigationTitle(item.title)
                .onAppear { model.selectPickerItem(item) }
        } label: {
            PickerItemRow(item: item, isSelected: false)
        }
        .accessibilityIdentifier("conversation-\(item.id)")
    }
}

private struct CompanionWatchContent: View {
    @ObservedObject var model: CompanionViewModel
    @StateObject private var speaker = WatchReplySpeaker.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if !model.isVoiceModeActive {
                    VStack(spacing: 8) {
                        Button {
                            speaker.stop()
                            model.beginRecording()
                        } label: {
                            Label("Speak", systemImage: "mic.fill")
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("conversation-speak")
                        if WatchVoiceJobs.shared.hasUnfinishedRecording && !model.isRecordingPaused && !model.isAwaitingVoiceTranscript {
                            Button("Resume Transcription") { model.retrySavedRecording() }
                            Button("Discard Recording", role: .destructive) { model.cancelVoiceRecording() }
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if model.visualState == .review && model.pendingCodexRequest == nil {
                                    Button(speaker.isSpeaking ? L10n.text("Stop speaking") : L10n.text("Read reply aloud"), systemImage: speaker.isSpeaking ? "stop.fill" : "speaker.wave.2.fill") {
                                        if speaker.isSpeaking { speaker.stop() }
                                        else { speaker.speak(model.petMessageReaderBody) }
                                    }
                                    .accessibilityIdentifier("conversation-read-reply")
                                }
                                if let error = speaker.errorMessage {
                                    Text(error).font(.caption).foregroundStyle(.orange)
                                }
                                Text(model.petMessageTitle)
                                    .font(.headline)
                                MarkdownText(markdown: model.petMessageReaderBody, size: 14, lineSpacing: 3)
                                    .accessibilityIdentifier("conversation-reply")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 8)
                }

                if model.isVoiceModeActive {
                    VoiceModeOverlay(
                        levels: model.waveformLevels,
                        tint: model.selectedPet.accentColor,
                        secondaryTint: model.selectedPet.secondaryAccentColor
                    ) {
                        model.pauseRecording()
                    }
                    .transition(.opacity)
                    VStack {
                        Text("Recording…").font(.headline)
                        Spacer()
                        Button("Stop Recording", systemImage: "stop.fill") { model.pauseRecording() }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel Recording", role: .destructive) { model.cancelVoiceRecording() }
                    }
                }

                if model.isRecordingPaused {
                    ScrollView {
                        VStack(spacing: 8) {
                            Text("Recording Paused").font(.headline)
                            Button("Transcribe") { model.transcribePausedRecording() }
                                .buttonStyle(.borderedProminent)
                            Button("Continue Speaking") { model.beginRecording() }
                                .buttonStyle(.bordered)
                            Button("Discard Recording", role: .destructive) { model.cancelVoiceRecording() }
                        }.frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .zIndex(1)
                }

                if let transcript = model.transcriptReview {
                    TranscriptReviewView(
                        transcript: transcript,
                        append: { model.appendRecording() },
                        close: {
                            model.dismissTranscript()
                        },
                        send: {
                            model.sendTranscript(transcript)
                        }
                    )
                    .transition(.opacity)
                    .zIndex(2)
                }

                if model.isAwaitingVoiceTranscript && model.transcriptReview == nil && !model.isVoiceModeActive {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Uploading / Transcribing").font(.headline)
                        Text("Recording saved\nYou can lower your wrist\nThe transcript will appear when ready")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Discard Recording", role: .destructive) { model.cancelVoiceRecording() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .accessibilityIdentifier("voice-transcription-progress")
                    .zIndex(1)
                }

                if let request = model.pendingCodexRequest,
                   !model.isVoiceModeActive,
                   model.transcriptReview == nil {
                    PendingCodexRequestView(
                        model: model,
                        request: request
                    )
                    .transition(.opacity)
                    .zIndex(3)
                }

            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            // Keep the Crown available to scroll sheets and replies. Task
            // routing is changed only by selecting a real item in the picker.
        }
        .foregroundStyle(.white)
        .onChange(of: model.isVoiceModeActive) { _, active in
            if active { speaker.stop() }
        }
        .animation(.easeInOut(duration: 0.16), value: model.isVoiceModeActive)
        .animation(.easeInOut(duration: 0.16), value: model.hasPetAnnouncement)
    }

    private func petSize(in size: CGSize) -> CGSize {
        let maxHeight = size.height * 0.52
        let maxWidth = size.width * 0.62
        let width = min(maxWidth, maxHeight * codexPetFrameAspect)
        return CGSize(width: width, height: width / codexPetFrameAspect)
    }
}

private struct ActiveTaskPetView: View {
    @ObservedObject var model: CompanionViewModel
    let canvasSize: CGSize

    var body: some View {
        let cardWidth = min(canvasSize.width * 0.92, 196)
        let petWidth = min(canvasSize.width * 0.42, 88)

        VStack(alignment: .center, spacing: 7) {
            PetControlButton(
                pet: model.selectedPet,
                state: model.petDisplayState,
                size: CGSize(width: petWidth, height: petWidth / codexPetFrameAspect),
                label: L10n.text("Start voice"),
                identifier: "mascot-voice-button",
                isPrimaryHandShortcut: false,
                action: {
                    model.beginRecording()
                },
                longPress: {
                    model.showPicker()
                }
            )

            ActiveTaskCard(
                title: model.petMessageTitle,
                message: model.petMessageBody,
                state: model.visualState,
                isUnread: model.hasUnreadMessage,
                width: cardWidth,
                openMessage: {
                    model.openCurrentMessage()
                }
            )
        }
        .frame(width: cardWidth, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.petMessageTitle). \(model.petMessageBody)")
    }
}

private struct PetControlButton: View {
    let pet: CodexPet
    let state: PetVisualState
    let size: CGSize
    let label: String
    let identifier: String
    let isPrimaryHandShortcut: Bool
    let action: () -> Void
    let longPress: () -> Void

    @State private var suppressTap = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard !suppressTap else {
                suppressTap = false
                return
            }
            action()
        } label: {
            CodexPetSpriteView(pet: pet, state: state)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    suppressTap = true
                    longPress()
                    resetTask?.cancel()
                    resetTask = Task {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        await MainActor.run {
                            suppressTap = false
                        }
                    }
                }
        )
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .primaryHandGestureShortcut(isEnabled: isPrimaryHandShortcut)
        .primaryAccessibilityQuickAction(
            label: label,
            action: action,
            isEnabled: isPrimaryHandShortcut
        )
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func primaryHandGestureShortcut(isEnabled: Bool = true) -> some View {
        if #available(watchOS 11.0, *) {
            handGestureShortcut(.primaryAction, isEnabled: isEnabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func primaryAccessibilityQuickAction(label: String, action: @escaping () -> Void, isEnabled: Bool = true) -> some View {
        if isEnabled {
            accessibilityQuickAction(style: .prompt) {
                Button(label, action: action)
            }
        } else {
            self
        }
    }
}

private struct ProjectChatPickerView: View {
    @ObservedObject var model: CompanionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAllProjects = false
    @State private var showsAllChats = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.startNewChat()
                        dismiss()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .accessibilityIdentifier("picker-new-chat-button")
                    .disabled(model.projectPickerItems.isEmpty)
                }

                if !model.unreadPickerItems.isEmpty {
                    Section("Unread") {
                        directRows(model.unreadPickerItems)
                    }
                }

                if !model.pinnedPickerItems.isEmpty {
                    Section("Pinned") {
                        ForEach(model.pinnedPickerItems) { item in
                            pickerRow(for: item)
                        }
                    }
                }

                Section("Projects") {
                    if model.projectPickerItems.isEmpty {
                        Text("No projects yet. Make sure Codex Watch on iPhone is connected to the Mac, then reopen this list.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if model.projectPickerItems.count > pickerVisibleItemLimit && !showsAllProjects {
                        ViewAllButton(
                            title: "View all",
                            remainingCount: model.projectPickerItems.count - pickerVisibleItemLimit,
                            accessibilityIdentifier: "view-all-projects"
                        ) {
                            showsAllProjects = true
                        }
                    }
                    ForEach(visibleProjects) { project in
                        NavigationLink {
                            ProjectChatsView(
                                model: model,
                                project: project,
                                dismissPicker: {
                                    dismiss()
                                }
                            )
                        } label: {
                            PickerItemRow(
                                item: project,
                                isSelected: model.isSelectedPickerItem(project),
                                showsDisclosure: true
                            )
                        }
                    }
                }

                if !model.directChatPickerItems.isEmpty {
                    Section("Chats") {
                        if model.directChatPickerItems.count > pickerVisibleItemLimit && !showsAllChats {
                            ViewAllButton(
                                title: "View all",
                                remainingCount: model.directChatPickerItems.count - pickerVisibleItemLimit,
                                accessibilityIdentifier: "view-all-chats"
                            ) {
                                showsAllChats = true
                            }
                        }
                        directRows(visibleDirectChats)
                    }
                }

                Section("Mascot") {
                    ForEach(CodexPet.builtIns) { pet in
                        Button {
                            model.selectPet(pet)
                            dismiss()
                        } label: {
                            MascotPickerRow(
                                pet: pet,
                                isSelected: pet == model.selectedPet
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mascot-picker-\(pet.id)")
                    }
                }
            }
            .navigationTitle("Switch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    private var visibleProjects: [CodexPickerItem] {
        visibleItems(model.projectPickerItems, isExpanded: showsAllProjects)
    }

    private var visibleDirectChats: [CodexPickerItem] {
        visibleItems(model.directChatPickerItems, isExpanded: showsAllChats)
    }

    private func visibleItems(_ items: [CodexPickerItem], isExpanded: Bool) -> [CodexPickerItem] {
        isExpanded ? items : Array(items.prefix(pickerVisibleItemLimit))
    }

    @ViewBuilder
    private func directRows(_ items: [CodexPickerItem]) -> some View {
        ForEach(items) { item in
            pickerRow(for: item)
        }
    }

    @ViewBuilder
    private func pickerRow(for item: CodexPickerItem) -> some View {
        if model.isProjectPickerItem(item) {
            NavigationLink {
                ProjectChatsView(
                    model: model,
                    project: item,
                    dismissPicker: {
                        dismiss()
                    }
                )
            } label: {
                PickerItemRow(
                    item: item,
                    isSelected: model.isSelectedPickerItem(item),
                    showsDisclosure: true
                )
            }
        } else {
            Button {
                model.selectPickerItem(item)
                dismiss()
            } label: {
                PickerItemRow(
                    item: item,
                    isSelected: model.isSelectedPickerItem(item),
                    showsDisclosure: false
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: CompanionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAllProjects = false
    @State private var showsAllChats = false

    var body: some View {
        NavigationStack {
            List {
                Section("Mascot") {
                    ForEach(CodexPet.builtIns) { pet in
                        Button {
                            model.selectPet(pet)
                        } label: {
                            MascotPickerRow(
                                pet: pet,
                                isSelected: pet == model.selectedPet
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onboarding-mascot-\(pet.id)")
                    }
                }

                Section("Projects") {
                    if model.projectPickerItems.isEmpty {
                        Text("Waiting for projects")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        if model.projectPickerItems.count > pickerVisibleItemLimit && !showsAllProjects {
                            ViewAllButton(
                                title: "View all",
                                remainingCount: model.projectPickerItems.count - pickerVisibleItemLimit,
                                accessibilityIdentifier: "onboarding-view-all-projects"
                            ) {
                                showsAllProjects = true
                            }
                        }
                        ForEach(visibleProjects) { project in
                            NavigationLink {
                                ProjectChatsView(
                                    model: model,
                                    project: project,
                                    dismissPicker: finish
                                )
                            } label: {
                                PickerItemRow(
                                    item: project,
                                    isSelected: model.isSelectedPickerItem(project),
                                    showsDisclosure: true
                                )
                            }
                        }
                    }
                }

                if !model.directChatPickerItems.isEmpty {
                    Section("Chats") {
                        if model.directChatPickerItems.count > pickerVisibleItemLimit && !showsAllChats {
                            ViewAllButton(
                                title: "View all",
                                remainingCount: model.directChatPickerItems.count - pickerVisibleItemLimit,
                                accessibilityIdentifier: "onboarding-view-all-chats"
                            ) {
                                showsAllChats = true
                            }
                        }
                        ForEach(visibleDirectChats) { chat in
                            Button {
                                model.selectPickerItem(chat)
                                finish()
                            } label: {
                                PickerItemRow(
                                    item: chat,
                                    isSelected: model.isSelectedPickerItem(chat),
                                    showsDisclosure: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button {
                        finish()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .accessibilityIdentifier("onboarding-done-button")
                }
            }
            .navigationTitle("Set Up")
        }
    }

    private var visibleProjects: [CodexPickerItem] {
        visibleItems(model.projectPickerItems, isExpanded: showsAllProjects)
    }

    private var visibleDirectChats: [CodexPickerItem] {
        visibleItems(model.directChatPickerItems, isExpanded: showsAllChats)
    }

    private func visibleItems(_ items: [CodexPickerItem], isExpanded: Bool) -> [CodexPickerItem] {
        isExpanded ? items : Array(items.prefix(pickerVisibleItemLimit))
    }

    private func finish() {
        model.completeOnboarding()
        dismiss()
    }
}

private struct ViewAllButton: View {
    let title: String
    let remainingCount: Int
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(L10n.format("%d more", remainingCount))
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MascotPickerRow: View {
    let pet: CodexPet
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            CodexPetSpriteView(pet: pet, state: .idle, isAnimationEnabled: false)
                .frame(width: 26, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(pet.displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(pet.description)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(pet.accentColor)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSelected ? L10n.format("%@, selected", pet.displayName) : pet.displayName)
    }
}

private struct ProjectChatsView: View {
    @ObservedObject var model: CompanionViewModel
    let project: CodexPickerItem
    let dismissPicker: () -> Void
    @State private var showsAllChats = false

    var body: some View {
        let chats = model.chatItems(for: project)
        let visibleChats = showsAllChats ? chats : Array(chats.prefix(pickerVisibleItemLimit))

        List {
            if chats.isEmpty {
                Text("No chats")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                if chats.count > pickerVisibleItemLimit && !showsAllChats {
                    ViewAllButton(
                        title: "View all",
                        remainingCount: chats.count - pickerVisibleItemLimit,
                        accessibilityIdentifier: "view-all-project-chats"
                    ) {
                        showsAllChats = true
                    }
                }
                ForEach(visibleChats) { chat in
                    Button {
                        model.selectPickerItem(chat)
                        dismissPicker()
                    } label: {
                        PickerItemRow(
                            item: chat,
                            isSelected: model.isSelectedPickerItem(chat),
                            showsDisclosure: false
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    model.startNewChat(in: project)
                    dismissPicker()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .accessibilityIdentifier("project-new-chat-button")
            }
        }
        .navigationTitle(project.title)
    }
}

private struct PickerItemRow: View {
    let item: CodexPickerItem
    let isSelected: Bool
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
            } else if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        let section = item.section?.lowercased()
        let kind = item.kind?.lowercased()
        if section == "unread" || item.unread == true {
            return "circle.fill"
        }
        if section == "pinned" || item.pinned == true {
            return "pin.fill"
        }
        if kind == "project" || section == "projects" {
            return "folder.fill"
        }
        return "text.bubble.fill"
    }

    private var symbolColor: Color {
        let section = item.section?.lowercased()
        if section == "unread" || item.unread == true {
            return .blue
        }
        if section == "pinned" || item.pinned == true {
            return .yellow
        }
        return .secondary
    }

    private var accessibilityLabel: String {
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            return "\(item.title). \(subtitle)"
        }
        return item.title
    }
}

private struct ActiveTaskCard: View {
    let title: String
    let message: String
    let state: PetVisualState
    let isUnread: Bool
    let width: CGFloat
    let openMessage: () -> Void

    var body: some View {
        Button(action: openMessage) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.trailing, 22)

                MarkdownText(
                    markdown: message,
                    size: 12.5,
                    lineLimit: 4,
                    minimumScaleFactor: 0.78,
                    foregroundOpacity: 0.92
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("active-message-body")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .primaryHandGestureShortcut()
        .primaryAccessibilityQuickAction(
            label: L10n.text("Open message"),
            action: openMessage
        )
        .accessibilityLabel(L10n.text("Open message"))
        .accessibilityIdentifier("active-message-card")
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(width: width)
        .frame(minHeight: 72)
        .background(Color.white.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            ActiveTaskGlyph(state: state, isUnread: isUnread)
                .frame(width: 18, height: 18)
                .padding(.top, 7)
                .padding(.trailing, 7)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct ActiveTaskGlyph: View {
    let state: PetVisualState
    let isUnread: Bool

    var body: some View {
        switch state {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
        case .review:
            if isUnread {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(L10n.text("Unread"))
            } else {
                Color.clear
            }
        default:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.secondary)
                .scaleEffect(0.78)
        }
    }
}

private struct MessageReaderView: View {
    let message: ReadableMessage
    let reply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if showsInlineTitle {
                            Text(message.title)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("message-reader-title")
                        }

                        MarkdownText(markdown: message.body, size: 15, lineSpacing: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("message-reader-body")

                        Button(action: reply) {
                            Label("Reply", systemImage: "mic.fill")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .accessibilityIdentifier("message-reader-scroll")
            }
            .background(.black)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    private var usesTitleAsNavigationTitle: Bool {
        wordCount(message.body) > 20
    }

    private var showsInlineTitle: Bool {
        !usesTitleAsNavigationTitle && !message.title.isEmpty
    }

    private var navigationTitle: String {
        usesTitleAsNavigationTitle ? message.title : L10n.text("Message")
    }

    private func wordCount(_ text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isNewline
        }.count
    }
}

private struct TranscriptReviewView: View {
    let transcript: VoiceTranscript
    let append: () -> Void
    let close: () -> Void
    let send: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcript")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(transcript.text)
                            .font(.system(size: 15))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(nil)
                            .accessibilityIdentifier("transcript-review-body")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .padding(.top, 28)

                HStack(spacing: 4) {
                    Button("Add More", action: append)
                        .accessibilityIdentifier("transcript-append")
                    Button("Send", action: send)
                        .accessibilityIdentifier("transcript-send")
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("transcript-review")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .background(.black)
    }
}

private struct PendingCodexRequestView: View {
    @ObservedObject var model: CompanionViewModel
    let request: PendingCodexRequest

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: request.isInputRequest ? "text.bubble.fill" : "hand.raised.fill")
                    .foregroundStyle(request.isInputRequest ? .blue : .orange)
                Text(request.title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .lineLimit(2)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    Text(request.body)
                        .font(.system(size: 13, weight: .medium, design: .rounded))

                    if let command = request.command, !command.isEmpty {
                        Text(command)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 92)

            if request.isInputRequest {
                Button {
                    model.beginRecording()
                } label: {
                    Label("Voice answer", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 7) {
                    Button("Deny") {
                        model.declinePendingRequest()
                    }
                    .buttonStyle(.bordered)

                    Button("Approve") {
                        model.approvePendingRequest()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Approve for session") {
                    model.approvePendingRequestForSession()
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pending-codex-request")
    }
}

private struct VoiceModeOverlay: View {
    let levels: [Double]
    let tint: Color
    let secondaryTint: Color
    let stop: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MicrophoneWaveformView(
                    levels: levels,
                    tint: tint,
                    secondaryTint: secondaryTint
                )
                    .frame(
                        width: min(proxy.size.width * 0.70, 150),
                        height: min(proxy.size.height * 0.28, 58)
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: stop)
        }
    }
}

private struct MicrophoneWaveformView: View {
    let levels: [Double]
    let tint: Color
    let secondaryTint: Color

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let count = max(levels.count, 1)
            let barWidth = max(2, (proxy.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = min(1, max(0.03, levels[index]))
                    Capsule(style: .continuous)
                        .fill(index.isMultiple(of: 2) ? tint : secondaryTint)
                        .frame(width: barWidth, height: max(3, proxy.size.height * level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(L10n.text("Microphone waveform"))
        .accessibilityIdentifier("microphone-waveform")
    }
}

private struct MarkdownText: View {
    let markdown: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var lineLimit: Int?
    var lineSpacing: CGFloat = 0
    var minimumScaleFactor: CGFloat = 1
    var foregroundOpacity: Double = 1

    var body: some View {
        Text(CodexMarkdownRenderer.attributedString(
            markdown,
            size: size,
            weight: weight,
            foregroundOpacity: foregroundOpacity
        ))
        .lineLimit(lineLimit)
        .lineSpacing(lineSpacing)
        .minimumScaleFactor(minimumScaleFactor)
    }

}

enum CodexMarkdownRenderer {
    static func attributedString(
        _ markdown: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        foregroundOpacity: Double = 1
    ) -> AttributedString {
        var output: AttributedString
        do {
            output = try AttributedString(markdown: markdown)
        } catch {
            output = AttributedString(markdown)
        }

        output.font = .system(size: size, weight: weight, design: .rounded)
        output.foregroundColor = .primary.opacity(foregroundOpacity)

        let runs = output.runs.map { run in
            (
                range: run.range,
                intent: run.inlinePresentationIntent,
                link: run.link
            )
        }

        for run in runs {
            if let intent = run.intent {
                if intent.contains(.code) {
                    output[run.range].font = .system(size: size * 0.93, weight: .medium, design: .monospaced)
                    output[run.range].foregroundColor = .cyan
                    output[run.range].backgroundColor = .white.opacity(0.13)
                } else if intent.contains(.stronglyEmphasized) {
                    output[run.range].font = .system(size: size, weight: .semibold, design: .rounded)
                } else if intent.contains(.emphasized) {
                    output[run.range].font = .system(size: size, weight: weight, design: .rounded).italic()
                }
            }

            if run.link != nil {
                output[run.range].foregroundColor = .cyan
            }
        }

        return output
    }
}

private struct SettingsView: View {
    @ObservedObject var model: CompanionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            TextField("Bridge URL", text: $model.serverURLString)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            Button {
                model.connect()
                dismiss()
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.fill")
            }

            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
        }
        .padding()
    }
}

#Preview {
    CompanionRootView(model: CompanionViewModel())
}
