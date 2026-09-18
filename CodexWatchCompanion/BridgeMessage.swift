import Foundation

struct CodexPickerItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var kind: String?
    var section: String?
    var project: String?
    var chat: String?
    var projectIndex: Int?
    var chatIndex: Int?
    var unread: Bool?
    var pinned: Bool?

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        kind: String? = nil,
        section: String? = nil,
        project: String? = nil,
        chat: String? = nil,
        projectIndex: Int? = nil,
        chatIndex: Int? = nil,
        unread: Bool? = nil,
        pinned: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.section = section
        self.project = project
        self.chat = chat
        self.projectIndex = projectIndex
        self.chatIndex = chatIndex
        self.unread = unread
        self.pinned = pinned
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case kind
        case section
        case project
        case chat
        case projectIndex
        case chatIndex
        case unread
        case pinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let project = try container.decodeIfPresent(String.self, forKey: .project)
        let chat = try container.decodeIfPresent(String.self, forKey: .chat)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? chat
            ?? project
            ?? UUID().uuidString
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.section = try container.decodeIfPresent(String.self, forKey: .section)
        self.project = project
        self.chat = chat
        self.projectIndex = try container.decodeIfPresent(Int.self, forKey: .projectIndex)
        self.chatIndex = try container.decodeIfPresent(Int.self, forKey: .chatIndex)
        self.unread = try container.decodeIfPresent(Bool.self, forKey: .unread)
        self.pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
    }
}

struct BridgeMessage: Codable {
    // Reconnect must use the current task, not the task selected when the
    // transport was first opened. Copy only routing fields, never actions.
    mutating func updateSelection(from message: BridgeMessage) {
        if let value = message.target { target = value }
        if let value = message.project { project = value }
        if let value = message.chat { chat = value }
        if let value = message.projectIndex { projectIndex = value }
        if let value = message.chatIndex { chatIndex = value }
        if let value = message.newChat { newChat = value }
    }
    var type: String
    var pet: String?
    var state: String?
    var title: String?
    var body: String?
    var text: String?
    var sampleRate: Double?
    var channels: Int?
    var encoding: String?
    var data: String?
    var bytes: Int?
    var path: String?
    var capabilities: [String]?
    var target: String?
    var action: String?
    /// Optional semantic event emitted by the Mac bridge. Unlike `state`, this
    /// identifies a one-time transition such as a completed task or an
    /// approval request so the iPhone can create a notification without
    /// guessing from a localized title.
    var event: String?
    var eventID: String?
    var requestID: String?
    var requestMethod: String?
    var command: String?
    var reason: String?
    var questionID: String?
    var question: String?
    var decision: String?
    var answer: String?
    var delta: Int?
    var index: Int?
    var project: String?
    var chat: String?
    var projectIndex: Int?
    var chatIndex: Int?
    var items: [CodexPickerItem]?
    var newChat: Bool?

    init(
        type: String,
        pet: String? = nil,
        state: String? = nil,
        title: String? = nil,
        body: String? = nil,
        text: String? = nil,
        sampleRate: Double? = nil,
        channels: Int? = nil,
        encoding: String? = nil,
        data: String? = nil,
        bytes: Int? = nil,
        path: String? = nil,
        capabilities: [String]? = nil,
        target: String? = nil,
        action: String? = nil,
        event: String? = nil,
        eventID: String? = nil,
        requestID: String? = nil,
        requestMethod: String? = nil,
        command: String? = nil,
        reason: String? = nil,
        questionID: String? = nil,
        question: String? = nil,
        decision: String? = nil,
        answer: String? = nil,
        delta: Int? = nil,
        index: Int? = nil,
        project: String? = nil,
        chat: String? = nil,
        projectIndex: Int? = nil,
        chatIndex: Int? = nil,
        items: [CodexPickerItem]? = nil,
        newChat: Bool? = nil
    ) {
        self.type = type
        self.pet = pet
        self.state = state
        self.title = title
        self.body = body
        self.text = text
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
        self.data = data
        self.bytes = bytes
        self.path = path
        self.capabilities = capabilities
        self.target = target
        self.action = action
        self.event = event
        self.eventID = eventID
        self.requestID = requestID
        self.requestMethod = requestMethod
        self.command = command
        self.reason = reason
        self.questionID = questionID
        self.question = question
        self.decision = decision
        self.answer = answer
        self.delta = delta
        self.index = index
        self.project = project
        self.chat = chat
        self.projectIndex = projectIndex
        self.chatIndex = chatIndex
        self.items = items
        self.newChat = newChat
    }
}
