# Codex Watch Companion

![Codex Watch Companion preview](docs/assets/group-9.png)

[简体中文](README.zh-CN.md) · English

This personal-use extension is based on the original
[b-nnett/codex-apple-watch](https://github.com/b-nnett/codex-apple-watch) project.

## Install with Codex, Claude Code, or another AI coding agent

Clone or download this repository, open its folder in your coding agent, and paste this prompt:

```text
Prepare and install Codex Watch Companion on my own iPhone and paired Apple Watch. Read README.md first. Check Xcode, signing, connected-device IDs, and the Mac bridge. Then run CODEX_WATCH_SHOW_NETWORK_HINTS=1 ./scripts/install.sh --test --phone-device <IPHONE_DEVICE_ID> --watch-device <APPLE_WATCH_DEVICE_ID>, start the bridge, install and launch both apps, and diagnose any errors. Ask me only when a physical action or Apple confirmation is required.
```

The agent can inspect the Mac, build the project, start the bridge, install the apps, and troubleshoot errors. Apple still requires the owner to perform a few physical/security steps: connect and unlock the iPhone, trust the Mac and developer certificate, enable Developer Mode, and select the Apple ID's Personal Team in Xcode. No AI agent can bypass those confirmations.

For the simulator:

```sh
./scripts/install.sh --test --simulator
```

For physical devices:

```sh
xcrun devicectl list devices
./scripts/install.sh --test --phone-device <IPHONE_DEVICE_ID> --watch-device <APPLE_WATCH_DEVICE_ID>
```

## What It Is

Codex Watch Companion is a personal Apple Watch + iPhone companion for a Mac that is running Codex. The production path is:

```text
Apple Watch ⇄ WatchConnectivity ⇄ iPhone gateway ⇄ Tailscale/private network ⇄ Mac bridge ⇄ Codex app-server
```

The iPhone owns the Mac connection, so a non-cellular Apple Watch can use the iPhone's network while you are away from the Mac. The Mac bridge reads Codex projects and chats, streams task state, forwards voice transcripts, and routes approval responses back into the same Codex app-server turn.

The first screen shows the available projects and chats. Open a chat, tap `Speak`, review the transcript, add more voice if needed, and send it to the same Codex task. Replies, approvals, task state, and unread status return to the watch.

## Language Support

- Simplified Chinese (`zh-Hans`) and English (`en`) are built in for both the iPhone and Apple Watch apps.
- The app follows the preferred language of each device. A Chinese device displays Simplified Chinese; an English device displays English.
- Every other language currently falls back to English, so the project is not limited to Chinese-speaking users.
- Project names, chat names, user prompts, and Codex replies are displayed in their original language and are not translated by the app.

## What Works

- Codex pet sprites and animation states ported from `/Applications/Codex.app` and the Codex CLI pet renderer.
- Mac bridge at `ws://<mac-lan-ip>:17842/codex-watch`.
- iPhone gateway target that forwards WatchConnectivity messages to the Mac bridge.
- Watch microphone streaming as base64 `pcm-f32le`.
- Transcription through the same Codex Desktop auth path by default, with optional direct OpenAI fallback.
- Project/chat picker populated from `~/.codex/sessions`.
- First-run onboarding for choosing a pet and selecting a project/chat.
- New chat creation from the switcher or a project chat list.
- Project/chat sections capped to six rows with `View all` controls for larger histories.
- Voice transcript review and send flow.
- Streaming reply previews from Codex app-server turn events.
- Command/file-change approval requests shown on the watch with Approve, Deny, and Approve for session controls.
- Codex `request_user_input` prompts answered by voice from the watch.
- Semantic task-complete and task-failed events forwarded to iPhone local notifications and mirrored by Apple Watch.
- Notification actions on iPhone for common approval requests.
- Markdown rendering in full message view, including inline code/link attributes.
- Haptics for send, reply, transcript, and failure states.
- Durable unread/thinking state across watch app restarts and bridge reconnects, plus app-open state refresh for the selected chat.

## Requirements

- macOS with Xcode and watchOS simulator/device support.
- Node.js 20+; the installer automatically uses the Node runtime bundled with Codex when a system `node` is not on `PATH`.
- `/Applications/Codex.app` or a `codex` CLI that supports `app-server`.
- An iPhone running iOS 17 or newer, paired with the Apple Watch.
- A paired Apple Watch for device installs, or a watchOS simulator.
- For remote use: Tailscale installed and signed in on both the Mac and iPhone. Its personal plan is sufficient; no server or paid relay is required.
- Optional: `tmux` for keeping the bridge running in a named session.

### The no-cost installation model

This is designed for one person's own devices. A paid Apple Developer Program membership is not required for device testing, but a free Apple Personal Team provisioning profile expires after seven days. You will need to rebuild and reinstall the iPhone/Watch pair roughly once a week. That is an Apple signing limit, not a limitation added by this project.

GitHub distributes the source code, not a pre-signed App Store app. Anyone can clone or download it and use Xcode—manually or with help from Codex, Claude Code, or another coding agent—to install it on their own devices. Each person signs the app with their own Apple ID; your certificate, Apple account, device IDs, private addresses, and notification credentials are not shared by this repository.

There is no permanent cloud connection hidden in this project: Tailscale provides the private path between your iPhone and Mac, and the Mac bridge runs locally on your own computer.

### First physical install with a free Apple ID

1. Connect the iPhone to the Mac, unlock it, and tap `Trust` if iOS asks.
2. Open `CodexWatchCompanion.xcodeproj` in Xcode. Select the `CodexWatchPhone` target, open `Signing & Capabilities`, and choose your Apple ID's `Personal Team`. Repeat for the `CodexWatchCompanion` watch target.
3. In Xcode, choose the connected iPhone as the run destination and build once. If iOS says the developer is not trusted, open `Settings > General > VPN & Device Management` on the iPhone and trust the Apple ID.
4. Run `xcrun devicectl list devices`, then run the install command below with the iPhone and paired Watch identifiers.

This Xcode signing step does not enroll you in the paid Apple Developer Program. The free Personal Team profile is the part that expires after seven days.

Machine-specific signing and connection defaults can be kept in the ignored
`.codex-watch/local.env` file instead of committed to Git:

```sh
CODEX_WATCH_DEVELOPMENT_TEAM="YOUR_APPLE_TEAM_ID"
CODEX_WATCH_DEFAULT_BRIDGE_URL="ws://YOUR-MAC-HOST:17842/codex-watch"
CODEX_WATCH_DEFAULT_MAC_HOST="YOUR-MAC-HOST"
```

The installer loads this file automatically. Existing addresses saved inside
the iPhone and Watch apps continue to take priority, so moving personal values
out of the public source does not reset an installed app.

## Remote setup with Tailscale

1. Install Tailscale on the Mac and iPhone, sign in to the same account, and leave it connected on both devices.
2. Start the bridge with `CODEX_WATCH_SHOW_NETWORK_HINTS=1 ./scripts/install.sh --bridge-only`.
3. In the iPhone Codex Watch app, enter the Mac's Tailscale address, for example `ws://100.x.y.z:17842/codex-watch`, and tap Connect Mac.
4. Allow notifications. The phone will forward task states to the watch and create notifications when Codex completes, fails, or needs your response.

The watch does not need cellular service for this path. It still depends on the iPhone being reachable over Bluetooth/Wi-Fi and on iOS being allowed to wake the companion app. If iOS has suspended the gateway, WatchConnectivity may deliver a queued control message later rather than immediately; opening the iPhone app once before a long remote session gives the most reliable behavior.

### Optional Bark notification fallback

The iPhone app creates native local notifications. If you also want an independent completion alert when iOS has suspended the gateway, the Mac bridge can send a privacy-minimized Bark notification containing only a generic completion/failure message—never the project name, prompt, reply, URL, or Codex credentials.

Copy [docs/bark.example.json](docs/bark.example.json) to:

```text
~/Library/Application Support/CodexWatchRemote/bark.json
```

Replace `YOUR_BARK_DEVICE_KEY`, set `language` to `en` or `zh-Hans`, and restrict the file to your account:

```sh
chmod 600 "$HOME/Library/Application Support/CodexWatchRemote/bark.json"
```

Unsupported notification languages fall back to English. This private configuration lives outside the repository and must never be committed.

## Install Script

The installer starts/restarts the Mac bridge, builds the iPhone gateway plus Watch App, installs them, and launches them. The Mac Node runtime bundled with Codex is used automatically when necessary.

```sh
./scripts/install.sh --phone-device <IPHONE_DEVICE_ID> --watch-device <APPLE_WATCH_DEVICE_ID>
```

Useful modes:

```sh
./scripts/install.sh --bridge-only
./scripts/install.sh --simulator
./scripts/install.sh --test --phone-device <IPHONE_DEVICE_ID> --watch-device <APPLE_WATCH_DEVICE_ID>
```

The bridge log is written to:

```text
build/codex-watch-bridge.log
```

If `tmux` is installed, the installer starts the bridge in a detached session named `codex-watch-bridge`. Without `tmux`, it uses a macOS `launchctl` user job. In both cases the script restarts the bridge when requested, runs a local health check before returning, and supervises it so it restarts automatically if Node exits.

```sh
CODEX_WATCH_SHOW_NETWORK_HINTS=1 ./scripts/install.sh --bridge-only
tmux ls
tmux attach -t codex-watch-bridge
tail -f build/codex-watch-bridge.log
# Without tmux, use:
tail -f /tmp/codex-watch-bridge.log
```

Stop the detached bridge:

```sh
tmux kill-session -t codex-watch-bridge
# If tmux is not installed:
launchctl remove codex-watch-bridge
```

Tune crash restart delay:

```sh
CODEX_WATCH_RESTART_DELAY=5 ./scripts/install.sh --bridge-only
```

## Manual Bridge

```sh
npm run bridge
```

If `node` is not on your `PATH`, use the same bundled runtime as the installer:

```sh
CODEX_WATCH_NODE_PATH=/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node ./scripts/install.sh --bridge-only
```

By default the bridge avoids printing machine-specific network details. To print connection URLs while pairing a watch, run:

```sh
CODEX_WATCH_SHOW_NETWORK_HINTS=1 npm run bridge
```

That prints URLs like:

```text
ws://<your-mac-lan-ip>:17842/codex-watch
ws://<your-mac-hostname>.local:17842/codex-watch
ws://127.0.0.1:17842/codex-watch
```

Set `CODEX_WATCH_OPEN_CODEX=1` if you want the bridge to open `/Applications/Codex.app` when the watch connects.

To start the bridge manually in `tmux` without the installer:

```sh
mkdir -p build
tmux kill-session -t codex-watch-bridge 2>/dev/null || true
tmux new-session -d -s codex-watch-bridge "cd \"$PWD\" && exec env CODEX_WATCH_SHOW_NETWORK_HINTS=1 bash scripts/run-bridge-supervisor.sh"
tail -f build/codex-watch-bridge.log
```

## Watch Controls

- Open a project, then a chat: view its current task state and latest reply.
- Speak: start voice mode in the selected chat.
- Tap waveform: stop recording and transcribe.
- Add More: append another recording to the visible transcript.
- Cancel Recording: discard an empty or incorrect recording.
- Send: send the reviewed transcript into the selected Codex chat.
- Read Reply Aloud: play the latest reply through the Apple Watch speaker.
- New Chat: start a fresh Codex thread for the selected project.
- Double Tap: open visible text if present, otherwise start voice mode.
- Reply button in message view: scroll to the bottom of the message and tap `Reply`.
- Approval card: tap `Approve`, `Deny`, or `Approve for session`; for a Codex input prompt, tap `Voice answer` and send the transcript.

## State Model

The bridge sends these watch-visible states:

- `idle`: bridge linked and no active task.
- `thinking`: Codex has started and is working before reply text arrives.
- `running`: audio/transcript/send/reply work is in progress.
- `review`: a reply or approval/input request is ready.
- `failed`: an error needs attention.

Unread replies and thinking/running task cards are persisted locally on the watch. The bridge also replays the last durable task state when the watch reconnects, and on app open asks Codex app-server for the selected chat state so completed replies or active work are restored when possible. Opening a message marks it read and clears the replay state for the current project/chat.

One-time events carry a stable `eventID`, so reconnecting the phone or watch does not create a second completion notification for the same Codex turn.

## Development

Run bridge tests:

```sh
npm run check
```

Run watch tests:

```sh
xcodebuild -project CodexWatchCompanion.xcodeproj \
  -scheme CodexWatchCompanion \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -derivedDataPath build/DerivedData \
  test
```

Build for a physical watch:

```sh
xcodebuild -project CodexWatchCompanion.xcodeproj \
  -scheme CodexWatchCompanion \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates \
  build
```

Build the complete iPhone + Watch bundle for a physical iPhone without signing (useful for checking the project on a Mac):

```sh
xcodebuild -project CodexWatchCompanion.xcodeproj \
  -scheme CodexWatchPhone \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Screenshot Fixtures

The app supports deterministic UI fixtures for screenshots and UI tests:

```sh
CODEX_WATCH_UI_TEST_SCENARIO=markdown
CODEX_WATCH_UI_TEST_SCENARIO=long-message
CODEX_WATCH_UI_TEST_SCENARIO=reader
CODEX_WATCH_UI_TEST_SCENARIO=thinking
CODEX_WATCH_UI_TEST_SCENARIO=voice
CODEX_WATCH_UI_TEST_SCENARIO=picker
CODEX_WATCH_UI_TEST_SCENARIO=picker-many
CODEX_WATCH_UI_TEST_SCENARIO=onboarding
```

Screenshots captured during release prep live in:

```text
docs/screenshots/
```

## Notes

- watchOS does not let third-party apps stay awake forever off-wrist. This app starts a `WKExtendedRuntimeSession`, but a dedicated old watch should also have Wrist Detection disabled in system settings.
- The Mac bridge is intentionally a personal, unauthenticated LAN/Tailscale endpoint. Keep port `17842` inside your private network; do not forward it to the public Internet.
- If the Mac Tailscale address changes, update the URL in the iPhone app. The watch itself does not need a separate Mac URL.
- iOS may suspend a background companion app. Interactive WatchConnectivity is used when available and queued delivery is used as a fallback, so a fully real-time remote session is best tested with the iPhone app opened once.
- This is a personal device build, not an App Store release.
