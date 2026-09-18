import Foundation
import WatchConnectivity

/// The small, shared transport between the watch app and its iPhone companion.
///
/// Interactive messages are used whenever the other side is reachable. Control
/// messages can fall back to transferUserInfo so that iOS gets a chance to wake
/// up and forward them to the Mac later. High-frequency audio deliberately opts
/// out of that fallback; queuing microphone chunks would be both slow and
/// wasteful.
final class WatchConnectivityRelay: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityRelay()

    var onMessage: ((BridgeMessage) -> Void)?
    var onReachabilityChanged: ((Bool) -> Void)?
    var onDeliveryFailure: ((String) -> Void)?

    private let session: WCSession?
    private var pendingActivationPayloads: [[String: Any]] = []
    private let chunks = RelayChunkAssembler()

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    var isSupported: Bool {
        session != nil
    }

    var isActivated: Bool {
        session?.activationState == .activated
    }

    var isReachable: Bool {
        session?.isReachable ?? false
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ message: BridgeMessage, fallbackToTransfer: Bool = true) {
        guard let payload = encode(message), let session else { return }
        for part in Self.wirePayloads(payload) {
            enqueueOrSend(part, session: session, fallbackToTransfer: fallbackToTransfer)
        }
    }

    // Lists with hundreds of tasks cannot fit in one WatchConnectivity message.
    // Fragment only at the transport boundary so both apps retain one protocol.
    static func wirePayloads(_ payload: [String: Any]) -> [[String: Any]] {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count > 20_000 else {
            return [payload]
        }
        let id = UUID().uuidString
        let count = (data.count + 19_999) / 20_000
        return (0..<count).map { index in
            ["relayChunkID": id, "index": index, "count": count,
             "data": data.subdata(in: (index * 20_000)..<min((index + 1) * 20_000, data.count))]
        }
    }

    private func enqueueOrSend(_ payload: [String: Any], session: WCSession, fallbackToTransfer: Bool) {

        // WCSession activation is asynchronous. In particular, the first hello
        // must not be transferred before activation has completed.
        guard session.activationState == .activated else {
            if fallbackToTransfer, pendingActivationPayloads.count < 128 {
                pendingActivationPayloads.append(payload)
            } else if !fallbackToTransfer {
                reportAudioFailure(payload)
            }
            return
        }

        sendPayload(payload, fallbackToTransfer: fallbackToTransfer)
    }

    private func sendPayload(_ payload: [String: Any], fallbackToTransfer: Bool) {
        guard let session else { return }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
                guard fallbackToTransfer else {
                    self?.reportAudioFailure(payload)
                    return
                }
                self?.transfer(payload)
            }
        } else if fallbackToTransfer {
            transfer(payload)
        } else {
            reportAudioFailure(payload)
        }
    }

    private func reportAudioFailure(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String, type.hasPrefix("mic-") else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onDeliveryFailure?(L10n.text("Voice transfer was interrupted. Open Codex Watch on iPhone, then record again."))
        }
    }

    private func transfer(_ payload: [String: Any]) {
        guard let session else { return }
        session.transferUserInfo(payload)
    }

    private func encode(_ message: BridgeMessage) -> [String: Any]? {
        guard
            let data = try? JSONEncoder().encode(message),
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any]
        else {
            return nil
        }
        return payload
    }

    private func deliver(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let assembled = self.chunks.receive(payload),
                  JSONSerialization.isValidJSONObject(assembled),
                  let data = try? JSONSerialization.data(withJSONObject: assembled),
                  let message = try? JSONDecoder().decode(BridgeMessage.self, from: data) else { return }
            self.onMessage?(message)
        }
    }

    private func publishReachability(_ reachable: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onReachabilityChanged?(reachable)
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        print("CodexWatch relay activation=\(activationState.rawValue) reachable=\(session.isReachable) error=\(error?.localizedDescription ?? "none")")
#if os(iOS)
        print("CodexWatch relay paired=\(session.isPaired) watchAppInstalled=\(session.isWatchAppInstalled)")
#endif
        DispatchQueue.main.async { [weak self] in
            guard let self, activationState == .activated else { return }
            let payloads = self.pendingActivationPayloads
            self.pendingActivationPayloads.removeAll()
            for payload in payloads {
                self.sendPayload(payload, fallbackToTransfer: true)
            }
        }
        publishReachability(activationState == .activated && session.isReachable)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        publishReachability(session.isReachable)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        deliver(message)
        replyHandler(["ok": true])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
}

final class RelayChunkAssembler {
    private struct Assembly {
        var started = Date()
        var count: Int
        var parts: [Int: Data] = [:]
    }
    private var pending: [String: Assembly] = [:]

    func receive(_ payload: [String: Any]) -> [String: Any]? {
        guard let id = payload["relayChunkID"] as? String else { return payload }
        pending = pending.filter { Date().timeIntervalSince($0.value.started) < 120 }
        guard let count = payload["count"] as? Int, (1...128).contains(count),
              let index = payload["index"] as? Int, (0..<count).contains(index),
              let data = payload["data"] as? Data, data.count <= 20_000 else { return nil }
        if pending[id] == nil {
            guard pending.count < 16 else { return nil }
            pending[id] = Assembly(count: count)
        }
        guard pending[id]?.count == count else { return nil }
        pending[id]?.parts[index] = data
        guard let assembly = pending[id], assembly.parts.count == count else { return nil }
        pending.removeValue(forKey: id)
        var joined = Data()
        for i in 0..<count {
            guard let part = assembly.parts[i] else { return nil }
            joined.append(part)
        }
        return (try? JSONSerialization.jsonObject(with: joined)) as? [String: Any]
    }
}
