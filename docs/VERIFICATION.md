# Device verification

The project's honesty ledger: what has been confirmed on a physical iPhone,
and what only builds and passes unit tests. Reports are welcome — reports
from real iPhones are the most useful thing right now.

## Verified on a real device

Confirmed by the original author on an iPhone 16 Pro (3 Nov 2026), with
everyday use:

- Dictating into other apps with the Hex keyboard, including the Darwin
  notifications between the app and the keyboard without an App Group.
- Starting a dictation from the Action Button with the app in the background,
  with the Live Activity on the Lock Screen and in the Dynamic Island.

Confirmed by the fork maintainer on an iPhone 16 Pro (8 Nov 2026):

- The Chinese nine-key end to end: candidates, paging (eight per page),
  quick punctuation, 重输 / 换行, hold-to-repeat delete, the recent-dictation
  picker, and key-tap feedback (haptic and click) outside a flow session.
- Curated contextual corrections applying on dictated text.
- 7-day renewal by rebuilding and reinstalling over the same bundle
  identifier (app data kept).

## Not yet verified on a real device

These parts build and are covered by unit tests where possible, but have not
been confirmed on a physical iPhone.

- Opening the app from the keyboard (`hexmobile://dictate`) on iOS 27, and
  whether iOS shows its way-back button at the top left when the link comes
  from a keyboard.
- Whether passing vocabulary terms as recognizer context improves accuracy.
- launchd `WatchPaths` on a file inside iCloud Drive: it fires only once the
  file is downloaded locally; the 15-minute interval covers the rest.
- Background recording started from Control Center, and the Action Button and
  Live Activity flow on iOS versions other than the authors'.
- Audio route changes and media services resets during a recording or a flow
  session (Bluetooth headphones, CarPlay).
- Flushing the converter's held-over audio at the end of a dictation, so the
  last words are not cut.
- `allowedExecutionTargets` keeping both intents in the app process on iOS 27.
- The keyboard's state handling: `session.ended`, the reply timeouts and
  inserting a result automatically only after a stop it requested.
- The accurate second pass on the iPhone: how long it takes after a long
  dictation, and whether it finishes inside the background time of an Action
  Button start (the Mac numbers are in
  [ARCHITECTURE.md](ARCHITECTURE.md#accurate-pass-and-text-cleanup)).
- The language-model cleanup on the iPhone: Apple Intelligence availability,
  the speed of the model, and whether the system limits it (`rateLimited`)
  when the app runs in the background, as it does from the Action Button.
- The "Fixing the text…" Live Activity label, and the Settings sections added
  for the cleanup and for keeping audio.
- Whether the second pass and the cleanup fix real speech: the numbers so far
  come from a synthetic voice, which is easier than a person.
- Whisper on the iPhone, all of it: that `devicectl device copy to` copies a
  folder as `make push-whisper-model` expects, the real-time factor and the
  cost of a piece (the time estimate is fitted on four phone runs of single
  windows; pieces were measured on the Mac only), the memory peak against the
  limit, how much memory Core ML gives back after the unload (`whisper
  unloaded +10s`), the Neural Engine in the background, and whether the model
  survives a flow session of hours. The first Core ML compile was measured
  once, 746.58 s on 2 Nov 2026 (iPhone 16 Pro): the "about 12 minutes" in
  Settings is that one figure, not a range.
- Pulling `keyboard-diagnostics.log` from the keyboard extension's container
  with the `devicectl` command in the README (the keyboard's bundle
  identifier as the domain identifier) — used successfully by the fork
  maintainer on 8 Nov 2026, but not by the original author.
