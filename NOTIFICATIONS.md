# Optional private completion reminders

Current personal-device choice (2026-09-18): the wearer explicitly approved
restoring Bark automatic reminders after an official-app test reached neither
phone nor Watch. Bark is enabled again, with an ungrouped ordinary active alert
matching the previously successful manual test. Official-app notification
delivery is not under this bridge's control. Real task-completion delivery to
the sleeping Watch still needs wearer confirmation. No companion rebuild is
needed; the bridge must restart to load the revised notification payload.

This integration uses the App Store version of Bark and its APNs service. It is
disabled until the owner consents and pairs their own device. The personal-team
Watch build does not itself have APNs entitlement.

Configuration belongs outside the repository, in
`~/Library/Application Support/CodexWatchRemote/bark.json`, owned by the current
user with mode 0600, in the existing 0700 directory. Fields: `enabled` (boolean),
`deviceKey` (Bark device key). Never paste this key into logs or source control.
Set enabled to false or remove that exact configuration file to stop reminders.
Configuration is reloaded for every event; no restart is needed for key changes.

The Mac bridge notifies for newly observed completed/failed turns in its active
Watch task monitors, independently of the Watch polling connection. It is not a
global monitor of every unrelated desktop project. Reading historical replies
does not itself send a reminder. Mock/test bridge processes disable delivery.

Outbound POST requests go only to `https://api.day.app/push`, with redirects
disabled. Payload contains the Bark routing key, fixed generic Chinese wording,
the fixed Codex title, level=active, and isArchive=1, with no group. Bark can keep
the generic reminder in its history. No project names, reply content,
thread IDs, command details or Codex credentials are sent. The service can still
observe notification timing, IP address and its own device routing identifier.

Local SHA256 event fingerprints suppress duplicate sends and are retained for
the last 2048 delivered events. Delivery errors are logged without sensitive data.
There is currently no durable retry/outbox: network outages can lose a reminder.
An accepted push is not proof of delivery to the Watch.

Allow Bark notifications on iPhone and mirror them in the Watch app. For the
usual Watch notification route, wear and unlock the Watch, then lock the phone.
Display asleep is not the same as passcode locked. Focus and notification
settings may suppress alerts; this integration does not bypass them. Tapping a
Bark notification is not guaranteed to open the Codex Watch app; open it manually
to read/reply. Neither companion app needs to remain foreground for APNs.

Status: Bark pairing and manual screen-asleep delivery were confirmed by the
wearer. Automatic task completion delivery remains under real-device validation.
Queued Watch submissions now persist their task/message IDs and selection in
pending-monitors.json beside the private configuration. Startup restores those
monitors without requiring a connected Watch; completion removes the record.
This fixes monitoring lost when the bridge restarted during app updates. It does
not add a durable notification retry/outbox for provider failures.
