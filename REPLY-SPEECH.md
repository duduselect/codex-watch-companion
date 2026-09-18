# Reply speech

The conversation page displays 朗读回复 for a ready reply when no approval/input
request is pending. It speaks a snapshot of the full reply through watchOS
AVSpeechSynthesizer, without a paid API or sending text to Bark. The button
becomes 停止朗读 while speaking. Chinese text selects the system Mandarin voice;
other text uses the current locale when available.

Background audio is now declared, and the speaker is retained beyond the view's
lifetime. Scene inactivity no longer explicitly stops speech. Starting voice
input or tapping stop still releases the audio session. It never starts
automatically on receipt. Wrist-down playback on SE2 still needs wearer testing;
OS interruptions and output-routing restrictions remain possible.
Build correction (2026-09-18): the previous Watch targets generated their plist
without reading CodexWatchCompanion-Info.plist, so the shipped bundle omitted
UIBackgroundModes entirely. Debug and Release now explicitly merge that source
plist. Check the embedded Watch app's final Info.plist for `audio` after building;
source configuration alone is not proof of a working background session.
Wearer testing after the plist fix still stopped speech on wrist-down. Speech
activation now uses watchOS's asynchronous activate(options:completionHandler:)
instead of synchronous setActive(true), while retaining the default speaker
route. A cancelled/replaced utterance cannot begin from a late activation reply.
This is an experimental correction, not proof of SE2 background speaker support.
The session is still not Apple's Bluetooth-oriented longFormAudio configuration;
real wrist-down testing remains required. No recording/workout/extended-runtime
session is started to keep speech alive.
The wearer subsequently confirmed that speaker playback continues with the
screen asleep on the SE2 after the asynchronous-activation build was installed.
This is a confirmed test, not a promise across calls, force quit, or all OS states.
System audio routing determines speaker/headphone output. Real-device audibility
and Mandarin voice quality must be checked by the wearer; a simulator unit test
cannot establish either. It is not desktop realtime voice and does not promise
the same voice or conversational interruption behavior.

Text preparation retains link labels but omits their destinations, strips common
Markdown decorations, and replaces fenced code with a spoken instruction to view
the screen. Unit tests cover that transformation and the existing model tests.
