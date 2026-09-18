import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const bridgeStrings = {
  "Approval needed": "需要批准",
  "Approval received": "已收到批准",
  "Audio streaming": "正在传输录音",
  "Bridge error": "桥接错误",
  "Bridge linked": "桥接已连接",
  "Bridge ready": "桥接已就绪",
  "Codex failed": "Codex 任务失败",
  "Codex is busy on the Mac. Your instruction is queued.": "电脑上的 Codex 正在处理，指令已排队。",
  "Codex is continuing": "Codex 正在继续",
  "Codex is replying": "Codex 正在回复",
  "Codex is thinking": "Codex 正在思考",
  "Codex is waiting for approval": "Codex 正在等待批准",
  "Codex is waiting for input": "Codex 正在等待输入",
  "Codex is waiting for your response": "Codex 正在等待你的回复",
  "Codex is working": "Codex 正在处理",
  "Codex replied": "Codex 已回复",
  "Codex started": "Codex 已开始",
  "Codex wants to apply file changes": "Codex 想要应用文件更改",
  "Codex wants to run: %@": "Codex 想要运行：%@",
  "Connecting to Mac": "正在连接 Mac",
  "Digital Crown": "数码表冠",
  "File change approval": "文件更改需要批准",
  "Input needed": "需要输入",
  "Instruction delivered. Waiting for Codex on the Mac.": "指令已送达，等待电脑上的 Codex 处理。",
  "Instruction delivered. Waiting for Codex to process it.": "指令已送达，等待 Codex 处理。",
  "Instruction received. Waiting for a reply.": "指令已接收，等待回复。",
  "Open Codex for error details": "打开 Codex 查看错误详情",
  "Open Codex to review": "打开 Codex 查看",
  "Permission needed": "需要权限",
  "Pet synced": "伙伴已同步",
  "Queued": "已排队",
  "Send failed": "发送失败",
  "Starting chat": "正在开始对话",
  "Syncing": "正在同步",
  "Task completed": "任务已完成",
  "Task failed": "任务失败",
  "That Codex approval request is no longer active.": "这项 Codex 批准请求已失效。",
  "The recording was saved, but transcription has not completed. Tap Resume Transcription.": "录音已保存，但转写尚未完成。请点击“恢复转写”。",
  "Transcription unavailable": "暂时无法转写",
  "Waiting for Codex to report task status.": "等待 Codex 返回任务状态。",
  "Working on it": "正在处理"
};

const watchStrings = {
  ...bridgeStrings,
  "%@, selected": "%@，已选择",
  "%d more": "还有 %d 项",
  "A balanced stack for deep work": "适合深度工作的平衡堆栈",
  "A steady rock when the diff gets large": "改动再大也稳如磐石",
  "A tidy duck for calm workspace days": "让工作空间保持从容整洁的小鸭",
  "A tiny blue-screen companion": "小小的蓝屏伙伴",
  "Add More": "补充录音",
  "An unfinished recording exists. Resume it first to avoid overwriting it.": "存在尚未处理的录音。请先恢复，避免覆盖。",
  "Apple Watch could not start speaking. Try again.": "Apple Watch 未能启动朗读，请重试。",
  "Approve": "批准",
  "Approve for session": "本次会话均批准",
  "Bridge URL": "桥接地址",
  "Cancel Recording": "取消录音",
  "Chats": "对话",
  "Code blocks are available on screen.": "代码片段请查看屏幕。",
  "Connect": "连接",
  "Connection interrupted. Delivery is uncertain: %@": "连接中断，发送结果需要确认：%@",
  "Connection Settings": "连接设置",
  "Continue Speaking": "继续说话",
  "Deny": "拒绝",
  "Discard Recording": "取消这段录音",
  "Done": "完成",
  "Enter a Mac address beginning with ws:// or wss://.": "请输入以 ws:// 或 wss:// 开头的 Mac 地址。",
  "Fetching projects and conversations…\nKeep iPhone and Mac connected.": "正在获取项目和对话…\n请保持 iPhone 与 Mac 连接。",
  "Fetching reply…": "正在获取回复…",
  "HTTP bridge request failed": "HTTP 桥接请求失败",
  "HTTP connection failed": "HTTP 连接失败",
  "Hot path energy for fast iteration": "为快速迭代带来充沛能量",
  "Invalid URL": "地址无效",
  "Invalid WebSocket URL": "WebSocket 地址无效",
  "Keep iPhone and Mac connected.": "请保持 iPhone 与 Mac 连接。",
  "Linked": "已连接",
  "Linking": "正在连接",
  "Listening": "正在聆听",
  "Mascot": "伙伴",
  "Message": "消息",
  "Mic blocked": "麦克风已被阻止",
  "Mic error": "麦克风错误",
  "Microphone waveform": "麦克风波形",
  "Needs attention": "需要处理",
  "New Chat": "新对话",
  "No audio was recorded. Discard it and record again.": "没有录到声音。请取消后重新录音。",
  "No chats": "暂无对话",
  "No projects yet. Make sure Codex Watch on iPhone is connected to the Mac, then reopen this list.": "尚未收到项目列表。请确认 iPhone 上的 Codex Watch 已连接 Mac，然后重新打开列表。",
  "No speaking voice is available on Apple Watch. Check the system voice settings.": "Apple Watch 暂无可用朗读声音，请检查系统语音设置。",
  "No speech was detected": "没有识别到说话内容",
  "No transcript text was returned.": "没有返回转写文字。",
  "Offline": "离线",
  "Open Codex for details": "打开 Codex 查看详情",
  "Open message": "打开消息",
  "Permission denied": "权限被拒绝",
  "Pinned": "置顶",
  "Please record again": "请重新录音",
  "Processing audio": "正在处理录音",
  "Projects": "项目",
  "Projects & Chats": "项目与对话",
  "Quiet signal from the void": "来自虚空的安静信号",
  "Read reply aloud": "朗读回复",
  "Ready": "已就绪",
  "Reconnect failed": "重新连接失败",
  "Reconnect later to resume transcription.": "请稍后重新连接并恢复转写。",
  "Reconnecting": "正在重新连接",
  "Recording cancelled": "录音已取消",
  "Recording is still pending": "录音尚未处理完",
  "Recording Paused": "录音已暂停",
  "Recording saved": "录音已保存",
  "Recording saved\nYou can lower your wrist\nThe transcript will appear when ready": "录音已保存\n可以放下手腕\n完成后会显示文字确认页",
  "Recording…": "正在录音…",
  "Refresh": "刷新列表",
  "Remote device credentials are missing. Complete secure pairing first.": "尚未配置远程设备凭证，请先完成安全配对。",
  "Reply": "回复",
  "Response sent": "回复已发送",
  "Resume Transcription": "恢复转写",
  "Say approve or deny": "请说“批准”或“拒绝”",
  "Send": "发送",
  "Sending": "正在发送",
  "Set Up": "设置",
  "Small green shoots for new ideas": "为新想法萌发的小小绿芽",
  "Socket closed": "连接已关闭",
  "Speak": "说话",
  "Start voice": "开始说话",
  "Stop Recording": "结束录音",
  "Stop speaking": "停止朗读",
  "Switch": "切换",
  "Tap Speak to start a new conversation.": "点击“说话”开始新对话。",
  "Tap into Codex to review": "点开查看 Codex 回复",
  "Task in progress": "任务处理中",
  "The connection was interrupted. Open Codex Watch on iPhone, then record again.": "连接已中断。请打开 iPhone 上的 Codex Watch，然后重新录音。",
  "The Mac is offline, so watch audio cannot be sent yet.": "Mac 尚未连接，暂时无法传输手表录音。",
  "The network send queue is full. Reconnect and try again.": "网络发送队列已满，请重新连接后再试。",
  "The original Codex companion": "原版 Codex 伙伴",
  "The previous recording is still being transcribed. Resume it first.": "上一段录音仍在转写，请先恢复该段录音。",
  "The recording could not be saved. Discard it and try again.": "无法暂存录音，请取消后重试。",
  "The remote credential is invalid or revoked. Pair again.": "远程凭证无效或已撤销，请重新配对。",
  "The saved recording is being restored. Wait for the transcript before adding more.": "已保存的录音正在恢复，请等待文字出现后再补充。",
  "The transcript will appear when ready": "完成后会显示文字确认页",
  "Thinking": "正在思考",
  "This is a longer markdown reply with `inlineCode`, **bold text**, and enough content to make the reader feel like a real Codex response.": "这是一条较长的 Markdown 回复，包含 `行内代码`、**粗体文字**和足够的内容，用于展示真实的 Codex 回复效果。",
  "This is a longer markdown reply with `inlineCode`, **bold text**, and enough content to make the reader feel like a real Codex response. The reply button lives at the bottom of the scroll view.": "这是一条较长的 Markdown 回复，包含 `行内代码`、**粗体文字**和足够的内容。回复按钮位于滚动内容底部。",
  "This is a longer markdown reply with more than twenty words so the message reader should move the title into the navigation bar and leave the body to start immediately. It keeps enough body text on screen to prove that the reply control belongs to the scroll content instead of being pinned over the bottom edge.": "这是一条较长的回复，用来验证阅读页面、标题位置和底部回复按钮的布局。",
  "Transcribe": "转文字",
  "Transcribing": "正在转写",
  "Transcript": "已识别文字",
  "Transcription timed out. Check the iPhone and Mac connection, then record again.": "语音转文字超时。请检查 iPhone 与 Mac 的连接，然后重新录音。",
  "Unknown": "未知错误",
  "Unread": "未读",
  "Uploading / Transcribing": "正在上传／转文字",
  "Uploading or transcribing. The result will return when the app resumes.": "正在上传或转写，应用恢复后会显示结果。",
  "Uploading or transcribing. You can lower your wrist.": "正在上传或转写，可以放下手腕。",
  "Use **bold**, `inlineCode`, and [docs](https://example.com) from the watch.": "在手表上显示 **粗体**、`行内代码` 和 [链接](https://example.com)。",
  "Use the buttons for this request": "请使用按钮处理这项请求",
  "Voice answer": "语音回答",
  "Voice request incomplete": "语音未完成",
  "Voice transfer was interrupted. Open Codex Watch on iPhone, then record again.": "语音传输中断。请打开 iPhone 上的 Codex Watch，然后重新录音。",
  "Waiting": "等待处理",
  "Waiting for Codex": "等待 Codex",
  "Waiting for projects": "等待项目列表",
  "Watch network offline": "手表网络离线",
  "WebSocket handshake failed: %@": "WebSocket 握手失败：%@",
  "Working": "正在处理",
  "You can lower your wrist": "可以放下手腕",
  "You can speak again": "可以重新说话"
};

const phoneStrings = {
  ...bridgeStrings,
  "Allow Task Notifications": "允许任务通知",
  "Approve": "批准",
  "Approve for session": "本次会话均批准",
  "Codex Watch": "Codex Watch",
  "Codex Watch notification test": "Codex Watch 通知测试",
  "Codex is waiting for your approval": "Codex 等待你的批准",
  "Codex is waiting for your input": "Codex 等待你的输入",
  "Codex task completed": "Codex 任务完成",
  "Codex task failed": "Codex 任务失败",
  "Connect Mac": "连接 Mac",
  "Connection Status": "连接状态",
  "Deny": "拒绝",
  "Disconnect": "断开",
  "Enter a Mac address beginning with ws:// or wss://.": "请输入以 ws:// 或 wss:// 开头的 Mac 地址。",
  "For remote use, enter the Mac's private Tailscale address, such as ws://100.x.y.z:17842/codex-watch. Allow Local Network and notification access when prompted.": "人在外面时，请填写 Mac 的 Tailscale 私网地址，例如 ws://100.x.y.z:17842/codex-watch。首次连接时请允许本地网络和通知权限。",
  "If you can see this message, task notifications are enabled.": "如果你看到了这条消息，任务通知通道已经打开。",
  "iPhone creates a local notification when a task completes, fails, needs approval, or waits for input. Apple decides whether it appears on iPhone or Apple Watch.": "任务完成、失败、需要审批或等待输入时，iPhone 会创建本地通知；系统会按照 Apple 的通知规则将它显示在 iPhone 或 Apple Watch 上。",
  "Latest Codex Status": "最近的 Codex 状态",
  "Mac Codex Bridge Address": "Mac Codex 桥接地址",
  "Mac connected": "Mac 已连接",
  "Mac offline": "Mac 离线",
  "No Codex event yet": "尚无 Codex 事件",
  "Notice": "提示",
  "Notifications": "通知",
  "Open Codex Watch for details.": "打开 Codex Watch 查看详情。",
  "Send Test Notification": "发送测试通知",
  "The iPhone gateway will show the latest task state here.": "iPhone 网关会在这里显示最近的任务状态。",
  "The Mac is offline, so watch audio cannot be sent yet.": "Mac 尚未连接，暂时无法传输手表录音。",
  "Waiting for Watch": "等待 Apple Watch",
  "Watch reachable": "Apple Watch 可连接",
  "WatchConnectivity unavailable": "WatchConnectivity 不可用",
  "ws://Mac-address:17842/codex-watch": "ws://Mac-地址:17842/codex-watch"
};

const watchInfo = {
  CFBundleDisplayName: {
    en: "Codex Watch",
    zh: "Codex Watch"
  },
  NSLocalNetworkUsageDescription: {
    en: "Connects to a local or private Mac bridge to sync Codex state and voice data.",
    zh: "连接本地或私有网络中的 Mac 桥接服务，以同步 Codex 状态和语音数据。"
  },
  NSMicrophoneUsageDescription: {
    en: "Uses the microphone to send voice instructions to Codex while recording.",
    zh: "使用麦克风录制语音指令并发送给 Codex。"
  }
};

const phoneInfo = {
  CFBundleDisplayName: {
    en: "Codex Watch",
    zh: "Codex Watch"
  },
  NSLocalNetworkUsageDescription: {
    en: "Connects to the Mac Codex bridge so the paired Apple Watch can control Codex remotely.",
    zh: "连接 Mac 上的 Codex 桥接服务，让配对的 Apple Watch 可以远程控制 Codex。"
  }
};

function makeCatalog(entries) {
  const strings = {};
  for (const key of Object.keys(entries).sort((a, b) => a.localeCompare(b))) {
    strings[key] = {
      extractionState: "manual",
      localizations: {
        en: { stringUnit: { state: "translated", value: key } },
        "zh-Hans": { stringUnit: { state: "translated", value: entries[key] } }
      }
    };
  }
  return { sourceLanguage: "en", strings, version: "1.0" };
}

function makeInfoCatalog(entries) {
  const strings = {};
  for (const key of Object.keys(entries).sort((a, b) => a.localeCompare(b))) {
    strings[key] = {
      extractionState: "manual",
      localizations: {
        en: { stringUnit: { state: "translated", value: entries[key].en } },
        "zh-Hans": { stringUnit: { state: "translated", value: entries[key].zh } }
      }
    };
  }
  return { sourceLanguage: "en", strings, version: "1.0" };
}

function write(relativePath, value) {
  const target = path.join(root, relativePath);
  fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n");
}

write("CodexWatchCompanion/Localizable.xcstrings", makeCatalog(watchStrings));
write("CodexWatchCompanion/InfoPlist.xcstrings", makeInfoCatalog(watchInfo));
write("CodexWatchPhone/Localizable.xcstrings", makeCatalog(phoneStrings));
write("CodexWatchPhone/InfoPlist.xcstrings", makeInfoCatalog(phoneInfo));

console.log(`Generated ${Object.keys(watchStrings).length} watch strings and ${Object.keys(phoneStrings).length} phone strings.`);
