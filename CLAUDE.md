# Timecode Slate — working notes for agents

A film slate for iPhone that decodes LTC timecode, jams an internal clock to it,
then free-runs. `README.md` explains the product and the design reasoning; this
file is the commands plus the traps.

Private working notes — specific equipment, purchase decisions, running todo —
live in `NOTES.md`, which is gitignored. Read it if present; do not move its
contents into tracked files.

## Layout

```
SlateCore/          Swift package — all the real logic, platform-independent
  Sources/SlateCore/  decoder, encoder, timecode maths, clock, slate state
  Sources/ltcbench/   decoder characterisation harness
  Sources/ltcplay/    LTC signal generator — test without hardware
  Sources/ltclisten/  live capture from real hardware (macOS only)
  Tests/              51 tests
App/                SwiftUI app sources (synchronized folder group)
TimecodeSlate.xcodeproj
TimecodeSlate-Info.plist   partial plist; merged with generated keys
```

`App/` is a **synchronized folder group**, so adding a Swift file there needs no
project-file edit.

## Commands

Run these from the repo root unless stated. Note the Bash tool's cwd persists
between calls and `cd` into a relative path will fail if you are already inside
`SlateCore/` — use absolute paths.

```bash
# Tests (fast, do this after any SlateCore change)
cd SlateCore && swift test

# Decoder characterisation numbers
cd SlateCore && swift run -c release ltcbench

# Live decode from an attached interface (macOS). Runs the app's own
# LTCAudioInput, so a PASS here exercises the real capture path.
cd SlateCore && swift run -c release ltclisten --list
cd SlateCore && swift run -c release ltclisten --device Microphone --rate 24 --seconds 10

# Build for the phone
xcodebuild -project TimecodeSlate.xcodeproj -scheme TimecodeSlate \
  -destination 'id=<UDID>' -configuration Debug -allowProvisioningUpdates build

# Compile-check for device without signing (faster, no phone needed)
xcodebuild -project TimecodeSlate.xcodeproj -scheme TimecodeSlate \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

# Find the phone
xcrun devicectl list devices

# Install + launch on the phone
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/TimecodeSlate-*/Build/Products/Debug-iphoneos/TimecodeSlate.app
xcrun devicectl device process launch --device <UDID> --terminate-existing \
  com.masroor.TimecodeSlate
```

Simulator equivalents use `xcrun simctl install|launch <SIM-UDID>` against
`Build/Products/Debug-iphonesimulator/`.

**SourceKit will report `No such module 'SlateCore'`** for files in `App/` when
they are indexed standalone. It is noise — the real build resolves the package
fine. Trust `xcodebuild`, not the inline diagnostic.

## Testing without timecode hardware

There is no timecode source attached yet, so this is how everything gets
exercised:

```bash
cd SlateCore && swift build -c release --product ltcplay
.build/release/ltcplay --rate 24 --start 10:00:00:00 --minutes 20 --play
```

Play it out of the Mac's speakers and let the phone hear it acoustically. The
decoder cannot tell this from a hardware generator — it is the same
biphase-mark waveform. `--verify` decodes the written WAV back and checks the
frames come out contiguous (it expects to lose exactly one frame at each end;
that is correct, and the README explains why).

The **simulator uses the Mac's microphone**, so this works on the simulator too.

## Hardware status

**The USB path is proven on macOS.** Zoom F3 → TCA-1 → Tentacle TRS-to-USB-C
adapter decodes at 100% frame yield, zero drops, zero discontinuities, rate
correctly detected as `fps24`. Verified with `ltclisten`, which drives the app's
own `LTCAudioInput`. The adapter enumerates as a USB audio class device,
`Microphone` by *TTGK Technology*, 2 ch @ 48 kHz, **signal on channel 0**.

Two things about that signal that look like faults and are not:

- **It arrives hard-clipped at 0 dBFS**, ~60% of samples at full scale, because
  the TCA-1 is 35–40 dB hotter than a mic input. This is harmless. LTC is a
  square wave and the decoder times zero crossings; clipping a square wave makes
  it more square. Do not add a pad to "fix" this.
- **The waveform is rail-to-rail with single-sample edges.** That is what a
  correct capture looks like here, not a sign of something broken.

**On iOS the working chain is the analogue one.** End to end:

```
Zoom F3 → TCA-1 (3.5 mm TRS out)
        → Rode TRS→TRRS adapter
        → Apple 3.5 mm → USB-C adapter
        → iPhone
```

Verified on device: enumerated, jammed, synced. **This is the chain to keep
working.** Apple's dongle is a plain UAC 1.0 device, which is the most certain
audio input there is on an iPhone.

Note it works **without an attenuator**, despite §2 of `NOTES.md` calling one
mandatory. That analysis was about audio levels; LTC is not audio. The signal
clips hard and decodes fine, for the same reason as above. Do not add a pad
unless something actually fails.

**The Tentacle TRS-to-USB-C adapter does not work on iOS.** iOS never
enumerates it — `availableInputs` offers only `MicrophoneBuiltIn`, and Voice
Memos ignores it too, so this is upstream of this app and not a routing bug.
Its descriptors say why: **USB Audio Class 2.0 running at Full Speed**
(`bInterfaceProtocol` 0x20, `Device Speed` 1), an unusual combination that
macOS's permissive `usbaudiod` accepts and iOS's stricter driver declines.
Nothing in this codebase can change that. The adapter remains useful as the
**known-good reference input on the Mac**, which is what `ltclisten` uses.

Debugging any of this on the phone is awkward because a USB-C interface occupies
the only port, leaving no cable for a debugger. That is why the diagnostics sheet
is on-screen and copyable rather than logged — tap the input name in the header.
It is what identified the failure above, and it earns its keep the next time an
interface is swapped.

## Hard-won gotchas

Things that cost real debugging time. Do not undo them without reading why.

- **Never do audio-session work on the clap path.** `setCategory`/`setActive`
  are synchronous IPC to `mediaserverd` and blocked the main thread for
  *seconds*, stalling the display link so the slate froze on a stale running
  timecode. All of it lives in `ClapSound.prewarm()`, off the main thread.
- **The clap is armed half a second early** and the sound is scheduled against
  the audio clock (`AVAudioPlayerNode.scheduleBuffer(at:)`), not played on
  demand. `player.play()` landed ~3 frames late.
- **No implicit animation anywhere on the slate** (`.transaction { $0.animation
  = nil }`). SwiftUI cross-fades a colour change over ~250 ms, which smeared the
  white→yellow sync mark across six frames.
- **Render from `CADisplayLink.targetTimestamp`,** not `CACurrentMediaTime()`.
  The number must be correct for the moment the frame lights the panel.
- **`CADisableMinimumFrameDurationOnPhone`** must be in the plist or ProMotion
  caps third-party apps at 60 Hz. There is no `INFOPLIST_KEY_` for it, hence
  `TimecodeSlate-Info.plist`.
- **Guard every `@Published` write** — the display link runs at 120 Hz and an
  unguarded assignment redraws the slate 120×/sec to show identical digits.
- **The microphone only runs between arming a jam and getting one.** Deliberate,
  for privacy, and it is what makes the clap sound safe (no `.record` session to
  fight over).
- `ltcplay --play` spawns `afplay`; it installs signal handlers so Ctrl-C does
  not leave an orphan playing timecode into the room.
- **Never diagnose a live input with `ffmpeg -f avfoundation`.** It silently
  drops buffers — measured losing ~12% of a capture while reporting the full
  duration elapsed. The result looks exactly like a mangled analogue signal:
  frames failing to decode, dozens of discontinuities, a plausible-looking
  bimodal edge histogram. It cost a whole debugging pass. Use `ltclisten`, which
  checks `AVAudioTime.sampleTime` continuity and will tell you outright.
- **`installTap` coalesces to 4800-frame (100 ms) buffers on macOS** whatever
  `bufferSize` you pass. `AVAudioSinkNode` delivers the driver's true IO buffers
  — measured at 64 frames, 1.33 ms — and is the path to take if capture latency
  ever matters. Jam *accuracy* does not depend on either, because every frame is
  timestamped from its buffer's host time.
- **Input latency is not in the host time.** The driver reports device latency +
  safety offset (4.42 ms total on this adapter, ~0.1 frame at 24 fps) and a jam
  is late by exactly that unless it is subtracted. Host-time anchoring does not
  fix this; it is a separate correction and is **not yet applied**.
