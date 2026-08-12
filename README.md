# Timecode Slate

A film slate for iPhone that decodes SMPTE linear timecode (LTC) from audio,
jams an internal clock to it, and then free-runs — so the cable can be unplugged
and the slate keeps correct time for the rest of the shoot.

Landscape slate showing timecode, scene/shot/take/roll, drawn clapper sticks,
and a synthesised clap.

## Why timecode slates work this way

On a set, picture and sound are recorded on separate devices. A timecode slate
solves the problem of putting them back together: it displays the same clock the
sound recorder is running, so an editor can read a frame of the slate and know
exactly where in the audio it belongs.

The catch is that a *running* timecode display photographs as an unreadable
smear at the exact moment you need to read it. That is why the clap freezes the
display: the frozen frame is the legible one.

## What it does

- **Decodes LTC** from any audio input — SMPTE 12M biphase-mark, all twelve
  standard rates including 29.97/59.94 drop-frame.
- **Jams** an internal clock to the decoded timecode, anchored to the audio
  buffer's host time rather than to callback arrival, so accuracy does not
  depend on buffer size or scheduling jitter.
- **Free-runs** afterwards with drift compensation. This is the point: the
  timecode source only has to be connected once.
- **Clap → freeze → user bits → resume.** The clap sequence is timed for a
  camera rather than for a person; see below.
- **Take log** with automatic take and shot-letter advance, exportable as CSV.

## The clap, in detail

This is the part with the least obvious engineering, and most of it exists
because of frame-by-frame review of recorded footage.

Pressing CLAP does not clap. It arms one half a second ahead. The slate keeps
running as if nothing happened; only the button changes. Then, on a single
display frame:

- the sticks snap shut,
- the timecode freezes,
- the display goes white → yellow,
- and the crack sounds.

Those must be the *same* frame, because that frame is the sync point. Three
things were needed to make that true:

1. **The press is not the moment.** A touch lands at an arbitrary point inside a
   refresh interval, so a timecode captured there belongs to a frame that is not
   yet on screen. The clap is taken on a display frame instead, stamped with
   `CADisplayLink.targetTimestamp` — the instant the frame lights the panel.
2. **The sound is scheduled, not played.** `AVAudioPlayer.play()` means "start
   as soon as you can", which is a promise about the main thread, not about
   time; it measured about three frames late. Knowing the target half a second
   ahead means the buffer can be handed to `AVAudioPlayerNode.scheduleBuffer(at:)`
   with an absolute host time and rendered by the audio thread at it, with
   output latency subtracted.
3. **Nothing animates.** SwiftUI cross-fades a colour change over ~250 ms, which
   at 24 fps smears the sync mark across six frames and lands it *after* the
   freeze it is meant to mark.

The freeze then holds the timecode for **four frames of the clapped rate** —
long enough to guarantee several completely clean exposures whatever the
camera's shutter phase — before showing user bits for half a second.

The clapper sticks are drawn with `Canvas`, no image assets. Stripes lean one
way on the hinged arm and the other on the fixed bar, so the closed position
forms chevrons; that mismatch is what makes a single frame unmistakably "shut".
The closing move is deliberately not animated.

## Display timing

The slate is driven by `CADisplayLink` at up to 120 Hz and renders from
`targetTimestamp`, so the number on screen is correct for the moment the camera
photographs it. A 30 Hz timer — the obvious first implementation — is not merely
coarse but wrong: sampling 24 fps timecode at 30 Hz shows values up to 33 ms
stale and irregularly repeats or skips frame numbers.

ProMotion requires `CADisableMinimumFrameDurationOnPhone` in Info.plist, or iOS
caps third-party apps at 60 Hz. There is no `INFOPLIST_KEY_` build setting for
it, which is why `TimecodeSlate-Info.plist` exists.

What none of this fixes: with a 180° shutter the camera's exposure covers about
half the frame period, so roughly half of camera frames will contain a digit
change and show a doubled frames digit. Nothing short of genlocking the camera
avoids it, and only the frames digit is affected. This is exactly why the freeze
exists.

## Privacy

The microphone is off at rest. It runs only between arming a jam and getting
one, with a timeout and a cancel, and shuts off the instant the clock is jammed.
A slate has no business listening to a set all day.

## Layout

```
SlateCore/            Swift package — all the logic, platform-independent
  Sources/SlateCore/    decoder, encoder, timecode maths, clock, slate state
  Sources/ltcbench/     decoder characterisation harness
  Sources/ltcplay/      LTC signal generator
  Tests/                51 tests
App/                  SwiftUI app
```

Keeping the logic in a platform-independent package is what makes the decoder
testable and characterisable from the command line, without a simulator.

## Building

Requires Xcode 26 or later.

```bash
# Tests
cd SlateCore && swift test

# Compile-check for device without signing
xcodebuild -project TimecodeSlate.xcodeproj -scheme TimecodeSlate \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

To run on a device, open `TimecodeSlate.xcodeproj`, select a signing team under
Signing & Capabilities, and enable Developer Mode on the phone.

## Testing without timecode hardware

`ltcplay` generates real LTC, so the whole chain — capture, decode, jam, free
run — can be exercised with nothing attached. Play it out of the Mac's speakers
and let the phone hear it acoustically; the decoder cannot tell it from a
hardware generator, because it is the same waveform.

```bash
cd SlateCore
swift build -c release --product ltcplay
.build/release/ltcplay --rate 24 --start 10:00:00:00 --minutes 20 --play
```

`--verify` decodes the written file back and checks the frames come out
contiguous and in order. It expects to lose exactly one frame at each end: a
frame is only resolvable once the sync words either side of it have been seen,
so a stream that begins and ends mid-air gives up its first and last. Real
hardware behaves the same way.

The iOS Simulator uses the Mac's microphone, so this works there too.

`ltcbench` characterises the decoder against deliberately degraded signals —
additive noise, low level, hard clipping, band limiting, capture-clock error —
and reports jam timing precision and throughput.

## Testing *with* timecode hardware

`ltclisten` decodes a live input on macOS, through the same `LTCAudioInput` the
app uses, so a pass exercises the real capture path rather than a stand-in.

```bash
cd SlateCore
swift run -c release ltclisten --list
swift run -c release ltclisten --device Microphone --rate 24 --seconds 10
```

It reports the driver's input latency budget, then per-second decode progress,
then a verdict. The number to watch is **DROPS**: capture that silently loses
buffers produces failed frames and discontinuities that are indistinguishable
from a bad analogue signal, and conflating the two wastes a lot of time. This
checks `AVAudioTime.sampleTime` continuity so it can tell you which one you have.

## Status

The decoder, clock, slate logic and UI are implemented and tested, and the app
runs on device.

The **input path is verified against real timecode hardware, on the phone**. A
Zoom F3 with a TCA-1, through a TRS→TRRS adapter into Apple's 3.5 mm → USB-C
dongle, enumerates on iOS and jams the clock correctly. The same signal decodes
on macOS at 100% frame yield with no dropped capture and no discontinuities,
measured with `ltclisten`, which drives the same `LTCAudioInput` the phone uses.

Worth recording, because it is counter-intuitive: the signal arrives **clipped
hard against both rails** and decodes perfectly anyway. LTC is not audio. It is a
square wave, and the decoder times zero crossings rather than amplitude, so
overdriving the input costs nothing. The attenuator that a level calculation says
is mandatory turns out not to be.

Not every interface works. A USB-C adapter presenting **USB Audio Class 2.0 at
Full Speed** was accepted by macOS and silently refused by iOS, which is stricter
about what it will bind an audio driver to. Since a USB-C interface occupies the
phone's only port and leaves nothing for a debugger, the app carries an on-screen
input diagnostics sheet that distinguishes "iOS never enumerated it" from "iOS
enumerated it and we failed to select it".

Also not done: take-log export UI, settings persistence.
