import Foundation
import Security
import WatchKit

final class VoiceBackgroundDelegate: NSObject, WKExtensionDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let transfer = task as? WKURLSessionRefreshBackgroundTask {
                WatchVoiceJobs.shared.handleBackground(transfer)
            } else { task.setTaskCompletedWithSnapshot(false) }
        }
    }
}

/// File-backed recording and system-managed uploads survive foreground disconnects.
final class WatchVoiceJobs: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = WatchVoiceJobs()
    static let resultReceived = Notification.Name("CodexWatchVoiceResultReceived")
    private struct Envelope: Decodable { let messages: [BridgeMessage]? }
    private var responseData: [Int: Data] = [:]
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceOutbox")
    private var file: FileHandle?
    private var recording: BridgeMessage?
    private var uploading = false
    private var pausedRecording = false
    var isPaused: Bool { pausedRecording || FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording-paused").path) }
    var isFailed: Bool { job?.requestID != nil && job?.requestID == UserDefaults.standard.string(forKey: "failedVoiceJobID") }
    func markFailed() { UserDefaults.standard.set(job?.requestID, forKey: "failedVoiceJobID") }
    func isDiscarded(_ id: String?) -> Bool {
        guard let id else { return false }
        return (UserDefaults.standard.stringArray(forKey: "discardedVoiceJobIDs") ?? []).contains(id)
    }
    func pause() throws {
        try file?.synchronize()
        try file?.close()
        file = nil
        pausedRecording = true
        try Data().write(to: directory.appendingPathComponent("recording-paused"), options: .atomic)
    }
    func discard() {
        let oldID = job?.requestID
        if let oldID {
            let ids = UserDefaults.standard.stringArray(forKey: "discardedVoiceJobIDs") ?? []
            UserDefaults.standard.set(Array((ids + [oldID]).suffix(100)), forKey: "discardedVoiceJobIDs")
        }
        try? file?.close()
        file = nil
        recording = nil
        pausedRecording = false
        uploading = false
        for name in ["job.json", "job-meta.json", "recording.raw", "recording.json", "result-request.json", "recording-paused"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        background.getAllTasks { tasks in
            for task in tasks where oldID != nil && task.taskDescription == oldID { task.cancel() }
        }
    }
    private var backgroundTasks: [WKURLSessionRefreshBackgroundTask] = []
    private lazy var background: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "dev.codexwatch.voice-upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    var job: BridgeMessage? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("job-meta.json")) else { return nil }
        return try? JSONDecoder().decode(BridgeMessage.self, from: data)
    }
    var hasUnfinishedRecording: Bool {
        job != nil || FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.raw").path)
    }
    func start(_ message: BridgeMessage) throws {
        if isPaused {
            file = try FileHandle(forWritingTo: directory.appendingPathComponent("recording.raw"))
            try file?.seekToEnd()
            pausedRecording = false
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("recording-paused"))
            return
        }
        guard job == nil else { throw NSError(domain: "VoiceOutbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "上一段录音仍在转写，请先恢复该段录音。"]) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = directory.appendingPathComponent("recording.raw")
        if FileManager.default.fileExists(atPath: raw.path) {
            throw NSError(domain: "VoiceOutbox", code: 2, userInfo: [NSLocalizedDescriptionKey: "有未处理的录音，请先恢复，避免覆盖。"])
        }
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        file = try FileHandle(forWritingTo: raw)
        recording = message
    }
    func append(_ message: BridgeMessage) throws {
        guard let data = message.data.flatMap({ Data(base64Encoded: $0) }), file != nil else { return }
        try file?.write(contentsOf: data)
        if recording?.sampleRate != message.sampleRate {
            var metadata = message
            metadata.data = nil
            try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("recording.json"), options: .atomic)
        }
        recording = message
    }
    func finish() throws {
        try file?.synchronize()
        try file?.close()
        file = nil
        if recording == nil, let data = try? Data(contentsOf: directory.appendingPathComponent("recording.json")) {
            recording = try JSONDecoder().decode(BridgeMessage.self, from: data)
        }
        pausedRecording = false
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("recording-paused"))
        guard var message = recording else { throw NSError(domain: "VoiceOutbox", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有录到声音，请取消后重新录音。"]) }
        let data = try Data(contentsOf: directory.appendingPathComponent("recording.raw"))
        guard !data.isEmpty else { throw NSError(domain: "VoiceOutbox", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有录到声音，请取消后重新录音。"]) }
        message.type = "voice-job"
        message.requestID = UUID().uuidString
        message.data = data.base64EncodedString()
        message.bytes = data.count
        try JSONEncoder().encode(message).write(to: directory.appendingPathComponent("job.json"), options: .atomic)
        message.data = nil
        try JSONEncoder().encode(message).write(to: directory.appendingPathComponent("job-meta.json"), options: .atomic)
        UserDefaults.standard.set(0, forKey: "voiceBackgroundWaitRounds")
        recording = nil
    }
    func upload(to url: URL, authorization: String?) {
        guard job != nil, !uploading, !isFailed else { return }
        let expectedID = job?.requestID
        uploading = true
        background.getAllTasks { tasks in
            DispatchQueue.main.async {
                guard tasks.isEmpty, let job = self.job, job.requestID == expectedID else { return }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
                let waiting = self.directory.appendingPathComponent("result-request.json")
                let source = FileManager.default.fileExists(atPath: waiting.path) ? waiting : self.directory.appendingPathComponent("job.json")
                let task = self.background.uploadTask(with: request, fromFile: source)
                task.taskDescription = job.requestID
                task.resume()
            }
        }
    }
    func completed(_ message: BridgeMessage, announce: Bool = true) {
        guard message.requestID == job?.requestID,
              let data = try? JSONEncoder().encode(message) else { return }
        UserDefaults.standard.set(data, forKey: "voiceRecoveredResult")
        uploading = false
        for name in ["job.json", "job-meta.json", "recording.raw", "recording.json", "result-request.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        if announce { NotificationCenter.default.post(name: Self.resultReceived, object: nil, userInfo: ["message": message]) }
    }
    func recoverRecording() {
        if file == nil && job == nil && !isPaused { try? finish() }
    }
    func retry() {
        recoverRecording()
        uploading = false
        UserDefaults.standard.removeObject(forKey: "failedVoiceJobID")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("result-request.json"))
        UserDefaults.standard.set(0, forKey: "voiceBackgroundWaitRounds")
    }
    func handleBackground(_ task: WKURLSessionRefreshBackgroundTask) {
        backgroundTasks.append(task)
        _ = background
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }
        backgroundTasks.removeAll()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let size = (responseData[dataTask.taskIdentifier]?.count ?? 0) + data.count
        guard size <= 2 * 1024 * 1024 else { dataTask.cancel(); return }
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responseData.removeValue(forKey: task.taskIdentifier)
        guard let job, task.taskDescription == job.requestID else { return }
        uploading = false
        guard error == nil, (task.response as? HTTPURLResponse)?.statusCode == 200,
              let data, let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let message = envelope.messages?.first(where: { $0.requestID == job.requestID }) else { return }
        if ["transcript", "voice-empty"].contains(message.type) {
            completed(message)
        } else if message.type == "voice-pending" {
            // Continue retrieving the result through a file-backed background
            // request, without needing the foreground poll timer to run.
            let rounds = UserDefaults.standard.integer(forKey: "voiceBackgroundWaitRounds")
            guard rounds < 12, let request = task.originalRequest, let url = request.url else { return }
            let next = BridgeMessage(type: "voice-wait", requestID: job.requestID)
            do {
                try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("result-request.json"), options: .atomic)
                UserDefaults.standard.set(rounds + 1, forKey: "voiceBackgroundWaitRounds")
                upload(to: url, authorization: request.value(forHTTPHeaderField: "Authorization"))
            } catch { /* Keep the original recording for foreground recovery. */ }
        } else if message.type == "voice-failed" {
            markFailed()
            NotificationCenter.default.post(name: Self.resultReceived, object: nil, userInfo: ["message": message])
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum WatchRemoteCredential {
    private static let service = "dev.codexwatchcompanion.remote"
    private struct Provision: Codable { let url: String; let token: String }

    static func installPending(defaults: UserDefaults) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = documents.appendingPathComponent("remote-connection.json")
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(Provision.self, from: data),
              let url = URL(string: value.url), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              value.token.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression) != nil else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "device"]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { print("Remote credential storage failed: \(status)"); return }
        do { try FileManager.default.removeItem(at: file) }
        catch { print("Remote provisioning cleanup required"); return }
        defaults.set(value.url, forKey: "serverURLString")
        print("Remote credential installed in Keychain")
    }

    static func authorization(for url: URL) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "device",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = try? JSONDecoder().decode(Provision.self, from: data),
              let trusted = URL(string: value.url), url.scheme == "https",
              url.host == trusted.host, url.port == trusted.port,
              url.path == trusted.path else { return nil }
        return "Bearer \(value.token)"
    }
}

private final class NoRemoteRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Uses watchOS-supported HTTP requests, not a running iPhone companion app.
/// All requests are serialized so audio and state envelopes keep their order.
final class WatchHTTPBridgeClient: WatchSocketClienting {
    var onMessage: ((BridgeMessage) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?
    private struct Envelope: Decodable { let messages: [BridgeMessage]? }
    private var session: URLSession?
    private var baseURL: URL?
    private var clientID = ""
    private var generation = UUID()
    private var pending: [BridgeMessage] = []
    private var busy = false
    private var ready = false
    private var pollTimer: Timer?
    private var audio = Data()
    private var audioTemplate: BridgeMessage?
    private let redirectPolicy = NoRemoteRedirects()
    private var authorization: String?
    private var awaitingTranscript = false
    private var voiceResultObserver: NSObjectProtocol?

    init() {
        voiceResultObserver = NotificationCenter.default.addObserver(forName: WatchVoiceJobs.resultReceived, object: nil, queue: .main) { [weak self] notification in
            guard let self, let message = notification.userInfo?["message"] as? BridgeMessage else { return }
            self.awaitingTranscript = false
            self.onMessage?(message)
        }
    }

    deinit {
        if let voiceResultObserver { NotificationCenter.default.removeObserver(voiceResultObserver) }
    }

    func connect(to url: URL, hello: BridgeMessage) {
        reset(notify: false)
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = url.scheme == "wss" || url.scheme == "https" ? "https" : "http"
        // A local build may inject a private migration host. The public source
        // never contains a person's LAN address, and explicit custom addresses
        // remain unchanged.
        if ["codex-watch.local", "your-mac.local"].contains(url.host ?? "") {
            let configuredHost = (Bundle.main.object(forInfoDictionaryKey: "CodexWatchDefaultMacHost") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let configuredHost,
               !configuredHost.isEmpty,
               !configuredHost.contains("$("),
               URL(string: "http://\(configuredHost)")?.host == configuredHost {
                parts?.host = configuredHost
            }
        }
        guard let endpoint = parts?.url else { return }
        baseURL = endpoint
        authorization = WatchRemoteCredential.authorization(for: endpoint)
        if endpoint.scheme == "https", authorization == nil {
            onMessage?(BridgeMessage(type: "error", body: "未配置远程设备凭证，请先完成安全配对。"))
            return
        }
        clientID = UserDefaults.standard.string(forKey: "voiceStableClientID") ?? "watch-http-" + UUID().uuidString
        UserDefaults.standard.set(clientID, forKey: "voiceStableClientID")
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
        onStateChange?(.connecting)
        pending.append(hello)
        WatchVoiceJobs.shared.recoverRecording()
        if let data = UserDefaults.standard.data(forKey: "voiceRecoveredResult"),
           let message = try? JSONDecoder().decode(BridgeMessage.self, from: data) { onMessage?(message) }
        pump()
    }

    func disconnect() {
        reset(notify: true)
    }

    private func reset(notify: Bool) {
        generation = UUID()
        pollTimer?.invalidate()
        pollTimer = nil
        session?.invalidateAndCancel()
        session = nil
        authorization = nil
        awaitingTranscript = false
        pending.removeAll()
        audio.removeAll()
        audioTemplate = nil
        busy = false
        ready = false
        if notify { onStateChange?(.disconnected) }
    }

    func send(_ message: BridgeMessage) {
        if message.type == "mic-cancel" {
            WatchVoiceJobs.shared.discard()
            awaitingTranscript = false
            return
        }
        if message.type == "mic-pause" {
            do { try WatchVoiceJobs.shared.pause() }
            catch { onMessage?(BridgeMessage(type: "voice-failed", body: "无法暂存录音，请取消后重试。")) }
            return
        }
        if ["mic-start", "mic-chunk", "mic-stop"].contains(message.type) {
            do {
                if message.type == "mic-start" { try WatchVoiceJobs.shared.start(message) }
                if message.type == "mic-chunk" { try WatchVoiceJobs.shared.append(message) }
                if message.type == "mic-stop" {
                    try WatchVoiceJobs.shared.finish()
                    awaitingTranscript = true
                    if let baseURL {
                        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
                        parts.path = baseURL.path + "/message"
                        parts.queryItems = [URLQueryItem(name: "client", value: clientID)]
                        if let url = parts.url { WatchVoiceJobs.shared.upload(to: url, authorization: authorization) }
                    }
                    pump()
                }
            } catch { onMessage?(BridgeMessage(type: "voice-failed", body: error.localizedDescription)) }
            return
        }
        guard session != nil else { return }
        if message.type == "mic-start" {
            awaitingTranscript = false
            audio.removeAll()
            audioTemplate = nil
        }
        if message.type == "mic-chunk" {
            guard let encoded = message.data, let data = Data(base64Encoded: encoded) else { return }
            audio.append(data)
            audioTemplate = message
            // Batch the microphone's small callbacks into ordinary HTTP posts.
            if audio.count >= 128 * 1024 { flushAudio() }
            return
        }
        if message.type == "mic-stop" {
            awaitingTranscript = true
            flushAudio()
        }
        pending.append(message)
        if pending.count > 128 {
            fail("网络发送积压，请重新连接后再试。")
            return
        }
        pump()
    }

    private func flushAudio() {
        guard !audio.isEmpty, var message = audioTemplate else { return }
        message.data = audio.base64EncodedString()
        message.bytes = audio.count
        audio.removeAll(keepingCapacity: true)
        pending.append(message)
        if pending.count > 128 {
            fail("网络发送积压，请重新连接后再试。")
            return
        }
        pump()
    }

    private func pump() {
        guard !busy, let session, let baseURL else { return }
        pollTimer?.invalidate()
        var message = pending.isEmpty ? nil : pending.removeFirst()
        if message == nil, !WatchVoiceJobs.shared.isFailed, let job = WatchVoiceJobs.shared.job {
            message = BridgeMessage(type: "voice-result", requestID: job.requestID)
        }
        guard message != nil || ready else { return }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + parts.path + (message == nil ? "/poll" : "/message")
        parts.queryItems = [URLQueryItem(name: "client", value: clientID)]
        guard let url = parts.url else { return }
        if WatchVoiceJobs.shared.job != nil { WatchVoiceJobs.shared.upload(to: url, authorization: authorization) }
        var request = URLRequest(url: url)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let message {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try JSONEncoder().encode(message) }
            catch { fail(error.localizedDescription); return }
        }
        busy = true
        let current = generation
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.busy = false
                if [401, 403].contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
                    self.fail("远程凭证无效或已撤销，请重新配对。")
                    return
                }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                    self.fail(error?.localizedDescription ?? "HTTP 连接失败")
                    return
                }
                if !self.ready {
                    self.ready = true
                    print("CodexWatch direct HTTP connected")
                    self.onStateChange?(.connected)
                }
                for value in envelope.messages ?? [] {
                    if WatchVoiceJobs.shared.isDiscarded(value.requestID) { continue }
                    if ["voice-pending", "voice-missing"].contains(value.type), WatchVoiceJobs.shared.isFailed { continue }
                    // An older foreground response must not replace a result
                    // already checkpointed by the background transfer.
                    if ["voice-pending", "voice-missing", "voice-failed"].contains(value.type),
                       value.requestID != WatchVoiceJobs.shared.job?.requestID { continue }
                    if ["transcript", "voice-empty"].contains(value.type), value.requestID != nil { WatchVoiceJobs.shared.completed(value, announce: false) }
                    if value.type == "voice-failed" { WatchVoiceJobs.shared.markFailed() }
                    if value.type == "transcript" || value.type == "error" { self.awaitingTranscript = false }
                    self.onMessage?(value)
                }
                if !self.pending.isEmpty { self.pump() }
                else {
                    self.pollTimer = Timer.scheduledTimer(withTimeInterval: self.awaitingTranscript ? 0.4 : 1, repeats: false) { [weak self] _ in
                        self?.pump()
                    }
                }
            }
        }.resume()
    }

    private func fail(_ reason: String) {
        // Do not retry an uncertain command automatically: it may already have
        // reached Codex. Reconnect only restores state, never resends commands.
        disconnect()
        onMessage?(BridgeMessage(type: "error", body: "连接中断，发送结果需确认：\(reason)"))
    }
}

/// Watch-side socket substitute. The iPhone owns the real Mac socket; this
/// object keeps the existing Watch view model unaware of that extra hop.
final class WatchPhoneBridgeClient: WatchSocketClienting {
    var onMessage: ((BridgeMessage) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    private let relay = WatchConnectivityRelay.shared
    private let directFallback = WatchSocketClient()
    private var hello: BridgeMessage?
    private var usesDirectFallback = false

    func connect(to url: URL, hello: BridgeMessage) {
        disconnect(notify: false)
        self.hello = hello

        // A direct socket is useful for the simulator and as a diagnostic
        // escape hatch. A real watch uses the paired iPhone by default.
        usesDirectFallback = !relay.isSupported
            || ProcessInfo.processInfo.environment["CODEX_WATCH_DIRECT_BRIDGE"] == "1"
        if usesDirectFallback {
            directFallback.onMessage = { [weak self] message in
                self?.onMessage?(message)
            }
            directFallback.onStateChange = { [weak self] state in
                self?.onStateChange?(state)
            }
            directFallback.connect(to: url, hello: hello)
            return
        }

        onStateChange?(.connecting)
        relay.onDeliveryFailure = { [weak self] reason in
            self?.onMessage?(BridgeMessage(type: "error", body: reason))
        }
        relay.onMessage = { [weak self] message in
            guard let self else { return }
            self.hello?.updateSelection(from: message)
            self.onStateChange?(.connected)
            self.onMessage?(message)
        }
        relay.onReachabilityChanged = { [weak self] reachable in
            guard let self else { return }
            self.onStateChange?(reachable ? .connected : .connecting)
            if reachable, let hello = self.hello {
                self.relay.send(hello)
            }
        }
        relay.activate()
        if relay.isReachable {
            onStateChange?(.connected)
            relay.send(hello)
        } else {
            // This is still a valid connection attempt: WatchConnectivity may
            // deliver the hello through its background transfer path.
            relay.send(hello)
        }
    }

    func disconnect() {
        disconnect(notify: true)
    }

    func send(_ message: BridgeMessage) {
        hello?.updateSelection(from: message)
        if usesDirectFallback {
            directFallback.send(message)
            return
        }

        let isHighFrequencyAudio = message.type == "mic-start"
            || message.type == "mic-chunk"
            || message.type == "mic-stop"
        relay.send(message, fallbackToTransfer: !isHighFrequencyAudio)
    }

    private func disconnect(notify: Bool) {
        if usesDirectFallback {
            directFallback.disconnect()
        }
        relay.onMessage = nil
        relay.onReachabilityChanged = nil
        relay.onDeliveryFailure = nil
        hello = nil
        usesDirectFallback = false
        if notify {
            onStateChange?(.disconnected)
        }
    }
}
