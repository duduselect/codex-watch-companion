# Codex Watch Companion

![Codex Watch Companion 预览](docs/assets/group-9.png)

简体中文 · [English](README.md)

这是一个开源的 Apple Watch + iPhone + Mac 项目，让你在离开电脑时继续控制 Mac 上正在运行的 Codex：浏览项目和对话、用手表录入语音指令、查看或朗读回复，以及处理审批请求。

本项目在 [b-nnett/codex-apple-watch](https://github.com/b-nnett/codex-apple-watch) 的基础上继续开发。

## 主要功能

- 手表首页直接显示 Codex 项目与对话列表。
- 在手表上录音，转成文字后先预览，再补充录音、取消或发送。
- 在手表熄屏或离开应用后保留录音与转写任务，并在恢复时显示结果。
- 查看 Codex 的处理中、已回复、失败、等待批准等状态。
- 在手表上批准或拒绝命令与文件修改请求。
- 用语音回答 Codex 的提问。
- 在手表上查看完整回复，并通过手表扬声器朗读。
- iPhone 作为网关，让没有蜂窝网络的 Apple Watch 也能借助 iPhone 网络连接家里的 Mac。
- 支持 iPhone 通知，并由 Apple 系统镜像到 Apple Watch；还可选配 Bark 作为完成通知的备用通道。
- 支持 Tailscale 私有网络，从户外安全连接家里的 Mac，无需把端口公开到互联网。

## 语言

- iPhone 与 Apple Watch 均内置简体中文和英文。
- 应用跟随各设备的首选语言：简体中文设备显示中文，英文设备显示英文。
- 暂未翻译的其他语言默认显示英文，因此这个项目并不只面向中文用户。
- 项目名称、对话名称、你的指令和 Codex 回复保持原文，不会被应用自动翻译。

## 工作方式

```text
Apple Watch ⇄ WatchConnectivity ⇄ iPhone 网关 ⇄ Tailscale/私有网络 ⇄ Mac 桥接服务 ⇄ Codex app-server
```

iPhone 负责与 Mac 保持连接。Apple Watch 即使没有蜂窝网络，只要仍能通过蓝牙或 Wi‑Fi 使用 iPhone 的网络，就可以在户外向家里的 Mac 发送指令。

## 免费安装模式

本项目发布的是源代码，不是已经签名的 App Store 安装包。任何人都可以从 GitHub 下载或克隆代码，再用 Xcode 安装到自己的 iPhone 与配对的 Apple Watch。

不需要付费加入 Apple Developer Program。使用普通 Apple ID 的免费 `Personal Team` 即可安装到自己的设备，但 Apple 的免费签名通常只有 7 天有效期，因此大约每周需要重新编译和安装一次。这是 Apple 的限制，不是本项目收取的费用。

每位使用者都用自己的 Apple ID 给应用签名。你的 Apple 账号、证书、设备编号、Mac 私网地址和通知密钥不会包含在公开仓库中。

## 让 Codex、Claude Code 或其他 AI Agent 协助安装

先下载或克隆本仓库，在 Codex、Claude Code 或其他代码 Agent 中打开项目文件夹，然后发送下面这段话：

```text
请帮我把 Codex Watch Companion 安装到我自己的 iPhone 和配对的 Apple Watch。先完整阅读 README.zh-CN.md，检查 Xcode、签名、已连接设备编号和 Mac 桥接服务。然后运行 CODEX_WATCH_SHOW_NETWORK_HINTS=1 ./scripts/install.sh --test --phone-device <IPHONE_DEVICE_ID> --watch-device <APPLE_WATCH_DEVICE_ID>，启动桥接服务，安装并打开手机端和手表端，并帮我诊断所有报错。只有在必须由我操作实体设备或确认 Apple 安全提示时才让我动手。
```

AI Agent 可以完成 Mac 上的大部分操作，包括检查环境、编译、安装、启动桥接服务和排查错误。但 Apple 要求设备所有者亲自完成以下安全操作，AI 无法代替：

1. 连接并解锁 iPhone，在提示时信任这台 Mac。
2. 在 iPhone 和 Apple Watch 上打开开发者模式。
3. 在 Xcode 的两个 Target 中选择自己的 Apple ID `Personal Team`。
4. 在 iPhone 上信任自己的开发者证书，并在系统弹窗中允许本地网络、麦克风和通知权限。

## 环境要求

- 一台安装了 Xcode 的 Mac。
- Codex 桌面端，或支持 `app-server` 的 Codex CLI。
- iOS 17 或更新版本的 iPhone。
- 与该 iPhone 配对的 Apple Watch，或 watchOS 模拟器。
- Node.js 20 或更新版本；如果系统没有 Node.js，安装脚本会尝试使用 Codex/ChatGPT 桌面端自带的 Node 运行环境。
- 远程使用时，Mac 与 iPhone 安装并登录同一 Tailscale 网络。Tailscale 个人免费方案即可。

## 首次安装到真机

1. 用数据线连接 iPhone 与 Mac，解锁手机并选择“信任”。
2. 用 Xcode 打开 `CodexWatchCompanion.xcodeproj`。
3. 依次选择 `CodexWatchPhone` 和 `CodexWatchCompanion` Target，在 `Signing & Capabilities` 中选择自己的 `Personal Team`。
4. 选择已连接的 iPhone 作为运行设备，在 Xcode 中编译一次。
5. 如遇“不受信任的开发者”，在 iPhone 的“设置 > 通用 > VPN 与设备管理”中信任自己的 Apple ID。
6. 查看设备编号并运行安装脚本：

```sh
xcrun devicectl list devices
CODEX_WATCH_SHOW_NETWORK_HINTS=1 ./scripts/install.sh --test \
  --phone-device <IPHONE_DEVICE_ID> \
  --watch-device <APPLE_WATCH_DEVICE_ID>
```

模拟器安装：

```sh
./scripts/install.sh --test --simulator
```

## 户外远程连接

1. 在 Mac 和 iPhone 上安装 Tailscale，并登录同一个账号。
2. 在 Mac 上启动桥接服务：

```sh
CODEX_WATCH_SHOW_NETWORK_HINTS=1 ./scripts/install.sh --bridge-only
```

3. 在 iPhone 的 Codex Watch 中填入 Mac 的 Tailscale 地址，例如：

```text
ws://100.x.y.z:17842/codex-watch
```

4. 点击“连接 Mac”，并允许通知和本地网络权限。

手表本身不需要蜂窝网络，但必须仍能通过附近的 iPhone 获得网络。Mac 需要保持开机，Codex 和桥接服务需要能够运行。

### 可选：用 Bark 作为备用通知

iPhone 端会创建 Apple 原生通知。如果 iOS 暂停了后台网关，而你仍希望收到一条独立的完成提醒，可以启用 Bark。Mac 桥接服务只会发送“任务已完成”或“任务失败”这类通用文字，不会发送项目名、指令、回复正文、地址或 Codex 凭证。

把 [docs/bark.example.json](docs/bark.example.json) 复制到：

```text
~/Library/Application Support/CodexWatchRemote/bark.json
```

将 `YOUR_BARK_DEVICE_KEY` 替换为自己的 Bark Key，把 `language` 设置为 `zh-Hans` 或 `en`，再限制文件权限：

```sh
chmod 600 "$HOME/Library/Application Support/CodexWatchRemote/bark.json"
```

其他语言会默认使用英文通知。这个私人配置保存在仓库之外，绝对不要上传到 GitHub。

## 手表操作

- 打开项目，再打开对话：查看当前任务状态和最新回复。
- “说话”：开始录制语音指令。
- 点击波形或“结束录音”：停止录音并开始转写。
- “补充录音”：在已经显示的文字后继续添加一段语音。
- “取消录音”：放弃空白或说错的录音。
- “发送”：把确认后的完整文字发送到当前 Codex 对话。
- “朗读回复”：通过 Apple Watch 扬声器朗读最新回复。
- 审批卡片：选择“批准”“拒绝”或“本次会话均批准”。

## 开发与测试

运行桥接服务测试：

```sh
npm run check
```

重新生成中英文本地化资源：

```sh
npm run localizations
```

不签名编译完整的 iPhone + Apple Watch 工程：

```sh
xcodebuild -project CodexWatchCompanion.xcodeproj \
  -scheme CodexWatchPhone \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 安全说明

- Mac 桥接服务是为个人私有网络设计的，请只在局域网或 Tailscale 私网中使用端口 `17842`，不要直接暴露到公网。
- 免费签名安装适合个人自用和开源测试，不等同于 App Store 上架。
- iOS 可能暂停长时间处于后台的网关应用。开始远程工作前先打开一次 iPhone 端应用，通常会更稳定。
- 由于 Apple 的通知分配规则，通知可能显示在 iPhone 或 Apple Watch 上；Bark 可作为可选的备用提醒通道。

更完整的技术说明、状态模型和截图测试方式请参阅 [英文 README](README.md)。
