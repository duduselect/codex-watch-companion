import Foundation

@main
struct SelectionReconnectChecks {
    static func main() throws {
        var hello = BridgeMessage(type: "hello", chat: "chat-1")
        hello.updateSelection(from: BridgeMessage(
            type: "transcript-send", text: "Do not replay this command",
            target: "chat", project: "project:real", chat: "thread-real", newChat: false
        ))
        assert(hello.type == "hello" && hello.text == nil)
        assert(hello.chat == "thread-real" && hello.project == "project:real")
        hello.updateSelection(from: BridgeMessage(type: "state", state: "idle"))
        assert(hello.chat == "thread-real", "Generic transport state must not clear routing")
        let restored = try JSONDecoder().decode(BridgeMessage.self, from: JSONEncoder().encode(hello))
        assert(restored.chat == "thread-real" && restored.newChat == false)
        print("Reconnect selection checks passed")
    }
}
