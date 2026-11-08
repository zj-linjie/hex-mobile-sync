# Diagnostics

When something fails on the iPhone, two files in the app's Application Support
folder say what happened (the keyboard extension keeps a third in its own
container). Neither holds dictated text, all are excluded from backups, and
nothing leaves the iPhone unless you copy them. This file holds the full
field-by-field detail; the README keeps a short summary.

## Diagnostics

When something fails on the iPhone, two files in the app's Application Support
folder say what happened. Neither holds dictated text, both are excluded from
backups, and nothing leaves the iPhone unless you copy them.

- `diagnostics.log`: start-up and lifecycle events (the last 1000 lines), one
  line per failed audio attempt with the system error, the audio session (its
  category, the outputs of the route, sample rate and output latency) and the
  Live Activities, and the liveness of the microphone during a dictation. When
  an Action Button start fails on `engine.start`, the next attempts reset the
  audio session and then switch it to `.record`; the lines `flow audio retry
  variant=…` and `flow audio unblocked by variant=…` say which. Times are UTC.
- After a dictation `diagnostics.log` also says how the steps after the stop
  went, in counts and seconds, never text: `final pass dt=… outcome=ok|fallback
  engine=… reason=… live=N final=M`, `cleanup availability=…` (once per launch),
  `cleanup dt=… outcome=ok|fallback reason=… in=N out=M` (with `estimate=… available=…` appended when `reason=budget`; `reason` is, among others, `budget`, `timeout`, `language`, or the guard's `empty|refusal|preamble|length|overlap|edited`), `stop to text dt=…`
  (from the stop to the text being ready; the budget is 8 s), `vocabulary respell
  n=…` and, with "Keep Audio" on, `clip kept id=…`.
- `keyboard-diagnostics.log` (in the keyboard extension's own container,
  `<BUNDLE_ID_PREFIX>.HexMobile.Keyboard`, last 200 lines, UTC; pulling it with
  pulled with the `devicectl` command below and the keyboard's bundle
  identifier — tried and working): taps, signals and inserts, plus what tells a crash from a
  process that iOS ended. `keyboard process started pid=… kernelStart=…
  footprint=…MB` is written once per extension process; a new one with no crash
  report before it means the previous process was ended, not that it crashed.
  `appear`, `appeared` (after the first layout) and `disappear` carry the pid,
  `footprint=` (`phys_footprint`, the figure a memory limit is compared with),
  `available=` (`os_proc_available_memory`, `n/a` on the simulator) and
  `controllers=` (keyboard view controllers alive) and `models=` (keyboard models
  alive; it should equal `controllers=`, so a `models=` that only grows is a
  leak). `keyboard load` is written first in `viewDidLoad`, before any SwiftUI:
  the model and the SwiftUI view are built only in `viewWillAppear` and torn down
  in `viewDidDisappear`, so a `keyboard load` with `models=` below `controllers=`
  is a controller iOS loaded and has not shown, and the footprint between it and
  `appear` is the cost of building the view.
  `keyboard recording t=…s` repeats the footprint every 10 s of a recording,
  `keyboard memory warning …` records `didReceiveMemoryWarning`, and `keyboard
  controller deinit` / `keyboard model deinit models=N` show what the system
  released: each controller that appeared is followed by a model deinit within
  the same second; a controller freed without ever appearing ends with
  `unshown` (`keyboard controller deinit controllers=0 models=0 unshown`) and has
  no model. Each signal appears once per event (`signal pong`, …); the same
  signal three times in a row means three models were subscribed.
- `audio-failure-oslog.log`: written only when the microphone engine fails to
  start (`engine.start`, the `'what'` error). It holds what the audio
  frameworks logged inside the app in the 5 seconds before the failure: a
  header line with the time (UTC), the app state, the background time left,
  the microphone permission, the audio session's category, mode and options,
  and then up to 40 log lines of CoreAudio, AVFAudio and AudioToolbox (240
  characters each). It keeps its last 500 lines, and `diagnostics.log` gets one
  line, `oslog dumped n=…`, when a block is written.

Copy a file to the Mac (the bundle identifier is your `BUNDLE_ID_PREFIX` plus
`.HexMobile`; `xcrun devicectl list devices` gives the device):

```sh
xcrun devicectl device copy from --device <identifier> \
  --domain-type appDataContainer --domain-identifier <BUNDLE_ID_PREFIX>.HexMobile \
  --source "Library/Application Support/audio-failure-oslog.log" \
  --destination ./audio-failure-oslog.log
```

For `diagnostics.log` use `--source "Library/Application Support/diagnostics.log"`.
Read both before attaching them to an issue.
