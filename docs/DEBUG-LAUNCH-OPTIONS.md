# Debug launch options

Debug-build-only launch arguments used to exercise the app and its
extensions without a microphone. They came out of the original README's
Screenshots section; nothing here affects a Release build.

## Demo content

- `-HexMobileDemo YES -HexMobileTab <tab>`: synthetic demo content on launch.
- `-settings.languageIdentifier <bcp47>`: pick the language for one run (not saved).
- `-HexMobileScroll bottom`: scrolls the Dictate screen to its end after three seconds.

## Automation

- `-HexMobileAutoStart YES`: starts one dictation when the app becomes active
  and stops it after `-HexMobileAutoStartSeconds N` (default 6); the outcome
  goes to the diagnostics log as `autostart` lines, without text. With
  `-HexMobileAutoInstall YES` it also downloads the speech model when the start
  fails for a missing one (what the Download Model button does).
- `-HexMobileAutoStartIntent YES`: runs the Action Button path
  (`IntentBridge.toggleDictation`, a second time after the listening seconds)
  instead of a plain start.
- `-HexMobileAutoHandoff hold|press|adopt`: opens an Action Button session
  holding a synthetic text, to try the wait for the keyboard
  (`printf 'HEXMOBILE-PULL 1\n' | nc 127.0.0.1 47391` plays the keyboard).
- `-HexMobileAutoFlow YES`: opens a flow session for the listening seconds and
  logs the audio and memory fields.
- `-HexMobileAutoDurationChange YES` (with `-HexMobileAutoFlow`): sets the
  running session's idle time to Never, 15 and 5 minutes, 3 s apart, as the
  picker in Settings does. To start a run with a stored value, write it into
  the app's own container: `xcrun simctl spawn <udid> defaults write
  "$(xcrun simctl get_app_container <udid> <bundle id> data)/Library/Preferences/<bundle id>"
  settings.flowSessionMinutes -int 0` (a plain `defaults write <bundle id>`
  goes to another file and the app never reads it).
- `-HexMobileAutoOSLog YES`: opens one and writes the audio OSLog dump
  described in [DIAGNOSTICS.md](DIAGNOSTICS.md).
- `-HexMobileAutoOpenURL <url>`: hands a `hexmobile://` link to the app as if
  the system had opened it (`xcrun simctl openurl` stops at the system's
  «open in Hex Mobile?» alert, which only a tap answers, and a headless
  simulator has none).
- `-HexMobileSlowFlowStart N`: makes a flow session start wait N seconds
  before its first audio attempt.
- `-HexMobileAutoRaceMs M` (with `-HexMobileAutoStartIntent`): presses the
  Action Button intent twice M ms apart, to try the cancel of a start in
  progress.

## Fake engines and failures

- `-HexMobileFakeEngine YES`: swaps the speech recognizer for one that hears
  nothing and "transcribes" a fixed sentence, so the simulator (which has no
  speech model) can run a whole dictation.
- `-HexMobileFakeFinalPass ok|messy|slow|fail|short|empty`: makes the accurate
  pass a fake one (`messy` returns an unpunctuated sentence with a hesitation
  and a spoken correction, to try the cleanup with the real language model);
  `-HexMobileCleanupTimeoutMs N` gives the cleanup N ms.
- `-HexMobileFakeClip <absolute path>`: makes the fake engine record that audio
  file (16 kHz mono 16-bit, as the analyzer writes it) instead of a second of
  silence. With `-settings.finalTextEngine whisper` and
  `-HexMobileWhisperDeadline N` the real Whisper model reads it on the
  simulator (`make push-whisper-model-sim SIM=<udid>` puts the model in its
  container; the simulator runs it on the CPU, about five times slower than
  real time, so the deadline is raised to N seconds; the first launch after
  `simctl install` ignores launch options).
- With the fake engine, `xcrun simctl spawn <udid> notifyutil -p
  io.github.hexmobile.toggle|cancel` plays the keyboard's keys and the `nc`
  line above reads what it would take.
- `-HexMobileSimulateWhat N`: makes the first N `engine.start` calls fail with
  a simulated `'what'`, to run the retry ladder of a flow session start (one
  failure reaches the session reset, two the `.record` category; the real
  error never happens on the simulator).

## Keyboard probe

- `-HexMobileKeyboardProbe YES`: gives a text field focus at launch and asks it
  for the Hex Mobile keyboard (the keyboard must be in Settings > Keyboards of
  the simulator, as it is once added there), so the keyboard extension runs on
  the simulator and writes its log.
- `-HexMobileKeyboardProbeResign N`: makes the field give the keyboard up
  after N seconds (the orderly end of a keyboard session).
- `-HexMobileKeyboardProbeFlick N` (with `-HexMobileKeyboardProbeFlickMs M`,
  default 40): makes it ask for the keyboard and give it up again N times, M ms
  apart: with a small M iOS loads keyboard controllers it never shows
  (`keyboard load` with no `appear`), as on the phone.
