# Whisper on the iPhone (optional)

The accurate pass after the stop can run a second engine, Whisper
(`large-v3` turbo, 632 MB, through [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift),
MIT). It reads the same recording after the Apple pass and, when it finishes
inside the time left, its text replaces Apple's, with your vocabulary terms
as the prompt. The default stays Apple. Settings > **Final Text Engine** offers
Whisper only when the model is installed, and says why when it is not.
The short version lives in the README; this file holds the full detail:
setup, the planning and budget rules, the text guard, and the log lines.

## Whisper on the iPhone (optional)

The accurate pass after the stop can run a second engine, Whisper
(`large-v3` turbo, 632 MB, through [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift),
MIT). It reads the same recording after the Apple pass and, when it finishes
inside the time left, its text replaces Apple's, with your vocabulary terms
as the prompt. The default stays Apple. Settings > **Final Text Engine** offers
Whisper only when the model is installed, and says why when it is not.

**The app never downloads the model.** It looks for it in its own container,
`Library/Application Support/whisper/`, and you copy it there from the Mac. The
folder is excluded from backups. WhisperKit contains code that downloads models
and tokenizers from Hugging Face; the app never calls it (`download: false`)
and refuses to start Whisper unless the model and the tokenizer files are on
disk, because the library would otherwise fetch a missing tokenizer by itself.

1. Put the model and the tokenizer on the Mac, in `build/whisper-models`: the
   folders `models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB`
   and `tokenizers/models/openai/whisper-large-v3` (`tokenizer.json`,
   `tokenizer_config.json`, `config.json`). One way is `whisperkit-cli transcribe
   --model large-v3-v20240930_turbo_632MB --download-model-path build/whisper-models
   --download-tokenizer-path build/whisper-models/tokenizers --audio-path <any short clip>`
   (da verificare: the exact `--model` spelling was not re-run when this was written).
   Only the `large-v3` family is accepted.
2. Copy them to the iPhone (the app installed, the iPhone unlocked):

   ```sh
   make push-whisper-model DEVICE=<udid>        # xcrun devicectl list devices
   ```

   It runs `xcrun devicectl device copy to --domain-type appDataContainer
   --domain-identifier <BUNDLE_ID_PREFIX>.HexMobile` twice (the model folder
   to `Library/Application Support/whisper/<model folder>`, the tokenizer folder
   to `Library/Application Support/whisper/tokenizers/models/openai/whisper-large-v3`)
   and lists the result. Copying a folder with `devicectl` was not proven on a
   device when this was written, and where a copied folder lands (as the
   destination, or inside it) is not documented, so the app accepts the model
   up to two folders below `whisper/` and the tokenizer up to five. To see
   where things landed: `xcrun devicectl device info files --device <udid>
   --domain-type appDataContainer --domain-identifier <BUNDLE_ID_PREFIX>.HexMobile
   --subdirectory "Library/Application Support/whisper"` (and one level deeper).
   For a simulator, `make push-whisper-model-sim SIM=<udid>` copies into the app's
   container folder (`devicectl` cannot reach simulators).
3. Open Settings > Final Text Engine and tap **Prepare Whisper**, with the app
   open on screen. The first load after a copy, or after an iOS update, makes
   Core ML compile the model for the Neural Engine: **about 12 minutes** on an
   iPhone 16 Pro (746.58 s, the phone log of 2 Nov 2026; later loads 2.9 to
   3.6 s). Until it ends, Apple's text is used. Settings says so: under the
   button, while Whisper has never been prepared on this model and this iOS
   version ("No record of Whisper loading on this iPhone yet, or iOS was updated since … about 12 minutes …
   keep Hex Mobile open on screen until the status says Ready"), and under the
   progress indicator while it compiles. "Prepared" is a marker written after a
   load on the Neural Engine that succeeded (not the CPU-only load that follows a Core ML
   error, which compiles nothing for it), keyed by model name and iOS version
   (`WhisperModel.preparedFor`); it says that load worked once, not that Core
   ML still holds the compiled model (ipotesi: the system may drop its cache).
   A phone that compiled the model before this marker existed shows the note
   once, until its next successful load (3 s). The app does not keep the screen awake and does not ask for confirmation
   before the load: a choice made in place of the author, to leave the button as
   it was.

How it runs:

- **Order and time.** Apple's pass runs first. Whisper then starts only if its
  estimated time **and** the estimated time of the cleanup both fit in what is
  left of the 8 s after the stop. Whisper must be done at `8 s - cleanup reserve`
  **after the stop** (an absolute time, not a duration) and has what is left of
  that: `available = 8 s - reserve - time since the stop`. The reserve is 1.3 x
  (0.25 s + 3.9 ms per character of Apple's text), at least 1 s, **plus 0.4 s** (and 0.45 s more, below):
  a Core ML prediction cannot be interrupted, so when Whisper reaches its deadline
  the model goes on for a moment on the Neural Engine, the cleanup starts on the
  same unit, and a short text used to reserve just the 1 s under which the
  cleanup is not started (0.4 is a choice in place of the author, between the 0.3
  and 0.5 asked for; the contention is not measured on a phone). The reserve also
  holds the 0.45 s the cleanup itself keeps before the 8 s (a choice in place of
  the author, between the 0.4 and 0.5 asked for; see the next item). So the cleanup
  always finds at least 1.4 s. When there is no cleanup (setting off, model not
  available) the reserve is zero. After the plan the app awaits the Live Activity
  update, which takes time of its own: the plan is **asked again with the clock
  as it is then**, and the deadline handed to Whisper is the same absolute time
  minus that wait (before, the wait came out of the cleanup's reserve and a
  short text lost its cleanup). `at=` in the log line is that clock. Whisper's
  estimate is 1.15 x (0.1 s + 0.4 s per
  piece + 15 ms per decoder step), the steps being the prompt and control tokens
  of every piece plus 6 tokens per second of audio. An estimate that does not
  fit is not started (`reason=budget`, log `whisper plan skip estimate=…
  available=…`, with `after-wait` when the wait took the room). There is no
  tighter ceiling on Whisper's deadline (such as 1.5 x the estimate): the
  estimate comes from four runs without pieces, and one is left to the
  measurements of the phone. **This is a choice made by the coordinator in place
  of the author** (2 Nov 2026), who asked for the text formatted and then to go on
  without questions: on a long dictation Apple's text goes to the cleanup instead
  of Whisper's, because a punctuated and capitalized text is what the author asked for and
  Whisper's gain does not pay for losing it. To flip it, give the reserve a zero
  in `FinalPassPolicy.whisperPlan`. Where it lands (elapsed 0.5 to 2 s after the
  stop, 18 characters per second of speech; a replica of the formulas, not a phone
  run): **with the vocabulary prompt** Whisper runs up to about 14.7 s, one piece
  (15.0 s for a 98-token prompt; 12.5 s when Apple's pass ended 2 s after the
  stop); from 15 s the recording is two pieces, the
  estimate jumps to about 6.2 s and it is skipped. **Without terms** (no prompt) it
  runs up to 21 to 27 s (the end-to-end margin took about 2.5 s off the 24 to 29
  of batch 10). The constants are fitted on four phone
  runs; the piece count and the cost of a piece come from the Mac, the phone has
  not run pieces yet (ipotesi: slower than the estimate for fast speakers). `whisper plan run estimate=…`, `whisper
  timings` and `rtf=` in `diagnostics.log` are what replaces them.
- **Cleanup time grows with the text, and it does not start if it would overrun.**
  The cleanup model writes the text again: 0.25 s + 3.9 ms per character on the
  phone (86 characters in 0.55 to 0.63 s, 435 in 1.65 s, 760 in 3.17 s, 1127 in
  4.19 s). The text must be there 8 s after the stop at the latest, and 0.45 s of
  that are kept for what follows the cleanup (guard, spelling, history, insertion;
  a choice in place of the author, between the 0.4 and 0.5 asked for). So the
  cleanup has an absolute deadline, 7.55 s after the stop, and starts only if its
  estimate fits what is left until then (and that is at least 1 s). If not, the
  raw text arrives at once and the log says `cleanup dt=0.00 outcome=fallback
  reason=budget in=N out=0 estimate=… available=…`. On 2 Nov 2026 1890
  characters started 1.3 s after the stop, were cut at 6.6 s and returned nothing;
  now they are skipped. The longest text that still gets the cleanup is
  (7.55 s - time of Apple's pass - 0.25 s) / 3.9 ms: about 1,740 characters after
  a 0.5 s pass, about 1,540 after the 1.3 s one of that long dictation. Running
  the cleanup during the recording is a later batch.
- **Guard.** Whisper's text is used only if it has at least half of the words of
  the text in hand and refuses no gap in it; otherwise that text stays
  (`reason=short`, `empty`, `gap`, `timeout`, `error`). The text in hand is
  Apple's pass, **or the live transcript when the Apple pass fell back**
  (`apple.text` is the live text then; the log calls it `live=` and
  `live_words=`, not `apple`). The length rule alone cannot see a lost
  sentence: on 2 Nov 2026 Whisper's 728 characters against Apple's 760 had six
  words missing. The gap check aligns the two texts word by word (lowercase, no
  punctuation, accents count, as in the WER of `asr-bench`) and compares, in each
  stretch between matched words, the words of the text in hand with no counterpart
  (`unmatched`) with the words Whisper wrote there (`written`). A name spelled another
  way or a number written out ("3" for "tre") is a substitution: one for one, no
  cost. A gap is refused when `unmatched - written` is at least **five**, or when
  `unmatched` is at least five and Whisper wrote at least **three** fewer words
  (half the run, rounded up). The second rule exists because Whisper can fill the
  silence at the end of a piece with words that were never said, and nine lost
  words behind five invented ones are a net of four. Two stretches with one
  matched word of one or two letters between them (`il`, `di`, `e`) count as one,
  because the aligner takes any such word inside a lost stretch as an anchor and
  would split five lost words in two and three; two matched words in a row, or
  one of three letters, keep them apart. Five covers the two losses seen (6 and 25
  words); on 13 complete synthetic texts the longest run was 1. The cover
  rule (3) and the merge are not measured on a phone, ipotesi: a real text with
  five unmatched words and two written, none of them a loss, is refused. It is
  conservative: if Apple itself holds five words that Whisper rightly left out,
  Apple's text stays. `guard gap=N at=i … unmatched=R written=C` in the log gives
  the net, the index of the first unmatched word and the two counts, so the line
  says which rule fired. Two texts too long to align (about 1000 words each, not a
  dictation of this app) are not judged and Whisper's text is used: the log says
  `guard skipped reason=too-long cells=…`.
- **Loading.** The model loads when a flow session opens (the Action Button or
  the keyboard) and stays in memory until the session ends, or until a memory
  warning. A dictation outside a flow session (the button in the app) loads it
  alongside the recording and releases it at the end, so it only helps when the
  load finishes before you stop; otherwise Apple's text is used
  (`reason=not-ready`). In practice Whisper pays off inside flow sessions, and
  after Settings > Prepare Whisper has made Core ML compile the model once.
  A model that is loading when the session ends is released as soon as the load
  ends.
- **Compute units.** The mel spectrogram runs on the CPU; the encoder and the
  decoder on the CPU and Neural Engine. Whether the Neural Engine is allowed in
  the background (the Action Button) was not verified; after a Core ML error in
  a run, the next load uses the CPU only. The simulator always uses the CPU.
- **Prompt.** At most 100 tokens of terms (WhisperKit keeps only the last 111 of a
  longer prompt, silently dropping the first terms); `whisper prompt terms=N/M
  tokens=K` says how many fit. With no terms there is no prompt, and the
  Dictate and Settings notice above says it.
- **Long dictations are read in pieces.** The Whisper decoder has a context of 224
  tokens, shared by the prompt, five control tokens and the text it writes. With
  the 100-token prompt that is room for about 15 s of speech; in a 30 s window
  WhisperKit ran out of room and dropped the rest of the window without a word
  (the phone of 2 Nov 2026 lost one to two sentences of a 42 s dictation at second
  30; the same on the Mac with the same options: 23 % of the words missing on
  three 42 to 104 s clips). Now a recording longer than the room is cut where the
  speaker pauses (the quietest 240 ms between half and the whole of the allowed
  length) and read piece by piece in one call: `max = (224 - 5 - 1 - prompt tokens)
  / 8 tokens per second`, 15.0 s for a 98-token prompt, between 8 and 28 s. A
  recording shorter than that is read as before. In continuous speech with no
  pause a cut can fall inside a word (the text guard below sees only five
  missing words in a row, not one). Each piece starts as a new sentence
  for the model, so a capital followed a comma («registrazioni, Perché»). The
  pieces are now joined by `WhisperClips.join`: the first letter of a piece that
  follows a comma, a semicolon, a colon or a word with no punctuation is
  lowercased; after `.`, `!`, `?` or `…` the capital stays, and so do words with
  two or more capitals (`IBAN`, `LoRA`) and a piece that opens with a quote or a
  bracket. The user's terms get their spelling back from the respell that follows.
  **A proper name that is not one of the terms and opens a piece after a comma is
  lowercased too** («…, bergamo»): a name cannot be told from a sentence start
  without a dictionary, and the Apple join (`appendingSegment`) still leaves the
  capital alone for that reason. The cleanup, when it runs, may give it back
  (da verificare). The join applies only when the library wrote one segment per
  window; otherwise its text is kept. In every case the text starts with a
  capital (`WhisperClips.capitalizingFirstLetter`): with the vocabulary prompt,
  which ends with a comma, Whisper began a sentence in lowercase («sta andando…»,
  2 Nov 2026). A first word with a capital inside (`iPhone`), a digit, a quote or
  a bracket stays as it is.
  The price is one more encoder pass and one more prompt per piece (about 0.4 s and
  1.5 s): the same 42 s clip takes 9.3 s on the Mac instead of 5.5 s and the
  text is whole.
- **Reproducing it on the Mac.** `tools/whisper-bench` runs the very same recipe
  (`Packages/HexMobileWhisper`, the one place that builds the decoding options)
  and prints the text; `asr-bench --external` scores it. `--no-pieces` brings back
  the cut text. See `tools/whisper-bench/README.md`.

Log lines (`diagnostics.log`, never any dictated text):

| Line | Meaning |
| --- | --- |
| `whisper load begin reason=flow-session\|dictation\|dictation-in-session\|setting-changed\|prepare model=…` | a load started |
| `whisper load dt=… units=mel:…/enc:…/dec:… footprint=…MB peak=…MB` | the model is in memory; `units` are the compute units actually requested; `peak` is the most the process has used so far |
| `whisper load failed dt=… reason=…` | the load failed (the reason is a domain/code or `no-tokenizer`) |
| `whisper plan run estimate=… deadline=… at=…s rec=…s prompt=T cleanup=N` / `whisper plan skip estimate=… available=… [after-wait] …` / `whisper plan not ready state=…` | the decision after the stop; `at` is the time since the stop when the plan was decided again after the Live Activity update (`deadline` is counted from it), `prompt` is the prompt tokens the plan counted: the real count of the terms when the model is ready (the tokenizer, bounded to 0.3 s), else the cap of 100, written `prompt=100(cap)`, `cleanup` the characters the cleanup reserve was computed on (`-`: no cleanup follows) |
| `whisper prompt terms=N/M tokens=K` | how many vocabulary terms fit the prompt |
| `whisper pieces n=4 max=15.0s prompt=98 rec=42.4s` | the recording is read in `n` pieces of at most `max` seconds (`n=1`: as it is) |
| `whisper timings windows=W steps=S enc=…s dec=…s pipeline=…s` | what the library measured: windows decoded, decoder steps (prompt included, once per window), seconds in the encoder, in the decoding loop (encoder included) and in all |
| `whisper join pieces=4 lowercased=2` | the pieces were put together; `lowercased` is how many started with a capital that was lowered because the sentence went on (not logged when the library's text is kept) |
| `whisper run footprint=…MB peak=…MB` | memory after the run |
| `guard gap=N at=i engine=whisper apple_words=A final_words=W unmatched=R written=C` | Whisper's text was refused (`reason=gap`): in a stretch of the text in hand (`apple_words`, or `live_words` when Apple's pass fell back), starting at word `i`, `R` words have no counterpart in Whisper's and Whisper wrote `C` there; `N = R - C` |
| `guard skipped reason=too-long cells=N …` | the guard was asked for and the texts were too long to align: Whisper's text was used without the check |
| `final pass dt=… outcome=ok\|fallback engine=whisper reason=… apple=N final=M rtf=…` | the result; `apple` and `final` are character counts, `rtf` is run time over recording time (only when the run finished) |
| `whisper release reason=…` / `whisper unloaded footprint=…MB` | the model was given back (the second line comes when it is really gone, later if a load or run was in progress) |
| `whisper unloaded +10s footprint=…MB peak=…MB state=…` | the same measure ten seconds after the unload: Core ML gives memory back late, if at all, so the first figure says little. `state` is the holder's state at that moment; anything but `unloaded` (a new load began) means the footprint includes it |
| `whisper memory warning state=…` | iOS asked for memory; a loaded or loading model is released |
| `whisper compute fallback next=cpuOnly after=…` | a Core ML error; the next load uses the CPU only |

With "Keep Audio" on, the clip JSON records `final_engine` (whose text went to
the cleanup: `whisper`, the Apple engine or `live`) and, when Whisper was chosen,
`whisper_text`, `whisper_outcome` and `whisper_seconds` next to Apple's
`final_pass_text`; `tools/asr-bench` shows them as `phone-whisper`. The schema
version is still 1: the fields are optional and older clips decode as before.

What was measured, on the simulator only (1 Nov 2026; CPU, Core ML cannot use the
Neural Engine there; synthetic voice; three runs with 4.2 to 5.1 s clips): the
first load after each install took 22 to 34 s (four loads; Core ML compiles the
model again), a later load 0.9 and 1.8 s (two loads); reading a clip took 3.2 to
5.2 times its length (`rtf`), with the first prediction included; the process
footprint (`phys_footprint`) peaked at 225 to 236 MB while the simulator
process's resident size (`ps rss`) reached 2.7 to 2.9 GB. The two do not agree,
and which one predicts the iPhone's memory kill is not known. None of this says
what the iPhone does: the Neural Engine, the memory limit of an app in the
background and the real `rtf` are measured only by a run on the device (the
first things to read there are `peak=` in `whisper load` and `whisper run` and
`available=` in `whisper plan run`). On those three clips Whisper wrote one
text exactly as in the reference and two with wrong words (`Rebiti` for `redditi`; `Vercell` and
`Senity` for the names Vercel and Sanity), which proves nothing about quality
either way.
