# Recoverable voice work

Recording controls (2026-09-18): End Recording now pauses capture and offers
Transcribe, Continue Speaking (append raw audio), and Cancel This Recording.
Pause is persisted locally, so reconnect does not silently submit paused audio.
Cancellation is also available while recording, waiting, and after failure. It
discards only the current local raw/job files, cancels matching transfer tasks,
and ignores late results using persisted discarded recording IDs. Earlier text
from an append operation is restored. An upload already accepted by the Mac may
finish there; cancellation is not deletion of server-side history or Codex chats.
Failed jobs stop automatic polling/upload retries until explicit recovery.
Empty recognized text is a terminal voice-empty result, not an endless retry.
Transcription HTTP requests now have a 60-second timeout. No speech detector is
claimed: background noise may still produce recognized text for the user to review.

WatchVoiceJobs writes microphone bytes to Documents/VoiceOutbox instead of
streaming through the short-lived UI connection. A completed recording gets a
stable job UUID and a JSON upload file. URLSession background upload transfers
that file independently of the foreground polling session. The stable client ID
is kept in defaults; the existing gateway scopes it by the authenticated owner.

Background result delivery (2026-09-18): voice-job responses now wait up to 25
seconds for persisted transcription. The upload's data delegate reads the
response and checkpoints the result without waiting for the foreground poll
timer. Pending responses schedule a small file-backed voice-wait upload through
the same authenticated background session, bounded to 12 continuations per
recording/retry. The gateway gives only voice-job/voice-wait a 35-second upstream
timeout; ordinary messages keep their existing timeout and size limit. Errors
retain the original recording. Foreground polling remains a recovery path.
The live view receives a local result event; after relaunch, the saved result is
replayed with existing request-ID deduplication. watchOS may still defer transfers
or delegate delivery; this is not a guarantee of immediate screen-off completion.
Real-device wrist-down transcription validation is pending for this revision.

The Mac stores voice jobs outside the repository in the owner's private
CodexWatchRemote/voice-jobs directory. Voice uploads are idempotent per client
and recording UUID. Results remain queryable across reconnect and bridge restart.
No voice-job endpoint submits an instruction to Codex: the wearer must still
review the words and tap Send. Failed transcription retains the source; the
恢复转写 button explicitly resubmits it. Partial local recordings can be finalized
on reconnect after app termination, provided audio metadata was captured.

Completed transcript delivery is first stored locally, then merged with the
saved draft. Result IDs prevent replay from duplicating appended words. Audio
outbox files are removed only after this local result checkpoint. The latest
checkpoint remains in defaults for recovery. The Mac retains audio and results;
automatic retention limits are not yet implemented.

Uploads use the existing authenticated HTTPS origin, reject redirects, and allow
at most 64 MiB JSON for voice-job only; other gateway messages remain capped at
2 MiB. Background scheduling can delay upload. This is not unlimited background
execution, and cannot guarantee uninterrupted capture through calls, force quit,
device reboot, missing network, or OS process termination. A recording currently
finishes upload only after the wearer ends capture, not while it is being recorded.

Background audio mode is declared for genuine recording/reading, not silent
keepalive. Frontend connection errors no longer cancel local microphone capture.
Real-device acceptance still requires wrist-down tests for recording, upload /
transcription recovery, and spoken playback separately. Runtime sessions and
foreground polling are not substitutes for that test.
