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

## The one thing that is still unproven

Everything above the analogue input stage is verified. What is *not* verified is
whether a hardware timecode signal physically reaches iOS at a usable level —
levels, mic bias, whether a USB-C interface enumerates. That needs an interface
and a real generator. `NOTES.md` has the specifics.

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
