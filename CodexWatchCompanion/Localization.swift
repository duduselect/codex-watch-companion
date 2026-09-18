import Foundation

/// Shared localization helpers for the watch app and iPhone gateway.
///
/// Both targets ship English and Simplified Chinese string catalogs. Apple
/// chooses Simplified Chinese when the app's preferred language is zh-Hans;
/// every other language falls back to the English development language.
enum L10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    /// Localizes bridge-owned status phrases while leaving project names,
    /// user prompts, and Codex reply content unchanged.
    static func bridgeText(_ value: String) -> String {
        let legacyKeys: [String: String] = [
            "已排队": "Queued",
            "电脑上的 Codex 正在处理，指令已排队": "Codex is busy on the Mac. Your instruction is queued.",
            "指令已送达，等待电脑上的 Codex 处理": "Instruction delivered. Waiting for Codex on the Mac.",
            "指令已送达，等待 Codex 处理": "Instruction delivered. Waiting for Codex to process it.",
            "已出队，正在同步": "Syncing",
            "等待 Codex 返回处理状态": "Waiting for Codex to report task status.",
            "Codex 已回复": "Codex replied",
            "任务已完成": "Task completed",
            "任务失败": "Task failed",
            "请查看 Codex 中的错误详情": "Open Codex for error details",
            "Codex 正在处理": "Codex is working",
            "指令已接收，等待回复": "Instruction received. Waiting for a reply.",
            "已识别文字": "Transcript",
            "录音已保存，转写暂未成功，请点击恢复转写。": "The recording was saved, but transcription has not completed. Tap Resume Transcription."
        ]
        if let key = legacyKeys[value] {
            return text(key)
        }

        let direct = text(value)
        if direct != value {
            return direct
        }

        let formattedPrefixes: [(String, String)] = [
            ("Codex wants to run: ", "Codex wants to run: %@"),
            ("WebSocket handshake failed: ", "WebSocket handshake failed: %@")
        ]
        for (prefix, key) in formattedPrefixes where value.hasPrefix(prefix) {
            return format(key, String(value.dropFirst(prefix.count)))
        }
        return value
    }
}
