import AVFoundation
import Foundation
import Combine

enum ReplySpeechText {
    static func plain(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "(?s)```.*?```", with: "代码片段请查看屏幕。", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!?\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}[#>]+\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// On-device speech, explicitly started by the wearer. No push or cloud TTS.
@MainActor
final class WatchReplySpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = WatchReplySpeaker()
    @Published private(set) var isSpeaking = false
    @Published private(set) var errorMessage: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ markdown: String) {
        stop()
        errorMessage = nil
        let text = ReplySpeechText.plain(markdown)
        guard !text.isEmpty else { return }
        let language = text.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil ? "zh-CN" : Locale.current.identifier
        guard let voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US") else {
            errorMessage = "手表暂无可用朗读声音，请检查系统语音设置。"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            current = utterance
            isSpeaking = true
            // watchOS requires asynchronous activation for audio-session setup.
            // Keep the default route: longFormAudio can require Bluetooth on SE2.
            // This does not by itself guarantee background speaker eligibility.
            session.activate(options: []) { [weak self] activated, error in
                Task { @MainActor [weak self] in
                    guard let self, self.current === utterance else { return }
                    guard activated, error == nil else {
                        self.current = nil
                        self.isSpeaking = false
                        self.errorMessage = "手表未能启动朗读，请重试。"
                        try? AVAudioSession.sharedInstance().setActive(false)
                        return
                    }
                    self.synthesizer.speak(utterance)
                }
            }
        } catch {
            errorMessage = "无法启动手表朗读，请重试。"
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    func stop() {
        guard current != nil else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard current === utterance else { return }
        current = nil
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

protocol WatchAudioStreaming: AnyObject {
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func start(onChunk: @escaping (AudioChunk) -> Void) throws
    func stop()
}

struct AudioChunk {
    let sampleRate: Double
    let channels: Int
    let encoding: String
    let data: Data
    let level: Double
}

enum AudioLevelMeter {
    static let floor = 0.04

    static func normalizedLevel(rms: Double, peak: Double) -> Double {
        let safeRMS = max(rms, 0.000_001)
        let safePeak = max(peak, 0.000_001)
        let rmsDecibels = 20 * log10(safeRMS)
        let peakDecibels = 20 * log10(safePeak)
        let rmsLevel = normalized(decibels: rmsDecibels, floor: -70, ceiling: -18)
        let peakLevel = normalized(decibels: peakDecibels, floor: -65, ceiling: -10) * 0.85
        let combined = max(rmsLevel, peakLevel)
        let compressed = pow(combined, 0.55)
        return min(1, max(floor, compressed))
    }

    private static func normalized(decibels: Double, floor: Double, ceiling: Double) -> Double {
        min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }
}

final class WatchAudioStreamer: WatchAudioStreaming {
    private let engine = AVAudioEngine()
    private var isRunning = false

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        if #available(watchOS 10.0, *) {
            AVAudioApplication.requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    completion(allowed)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                DispatchQueue.main.async {
                    completion(allowed)
                }
            }
        }
    }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let channels = max(1, Int(format.channelCount))

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            var data = Data(capacity: frameCount * channels * MemoryLayout<Float>.size)
            var squareSum: Double = 0
            var peak: Double = 0
            var sampleCount = 0

            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    var sample = channelData[channel][frame]
                    squareSum += Double(sample * sample)
                    peak = max(peak, Double(abs(sample)))
                    sampleCount += 1
                    withUnsafeBytes(of: &sample) { bytes in
                        data.append(contentsOf: bytes)
                    }
                }
            }

            let rms = sampleCount > 0 ? sqrt(squareSum / Double(sampleCount)) : 0
            let level = AudioLevelMeter.normalizedLevel(rms: rms, peak: peak)

            onChunk(AudioChunk(
                sampleRate: format.sampleRate,
                channels: channels,
                encoding: "pcm-f32le",
                data: data,
                level: level
            ))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
    }
}
