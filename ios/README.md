# Small Hours — iOS

The native build. This is where mattress sensing works best: real background
recording with the screen off, an alarm that does not depend on the page staying
open, and no Auto-Lock workaround.

Requires Xcode 16 or later and an iPhone running iOS 17 or later. There are no
third-party dependencies.

## Build and run

1. Install **Xcode** from the Mac App Store, then point the command-line tools at
   it (once):

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

2. Open `ios/SmallHours.xcodeproj`.
3. Select the **SmallHours** target → **Signing & Capabilities**:
   - set **Team** to your own Apple ID (a free personal team works — Xcode offers
     to create one);
   - change the **Bundle Identifier** from `com.example.smallhours` to something
     unique to you, e.g. `com.yourname.smallhours`.
4. Plug in your iPhone, choose it as the run destination and press **⌘R**.
5. First run only, on the phone: **Settings → General → VPN & Device Management**
   → trust your developer certificate. Newer iOS versions also ask you to turn on
   **Developer Mode** (Settings → Privacy & Security).

Builds signed with a free Apple ID expire after **7 days**; re-run ⌘R to refresh.
A paid Apple Developer account extends that to a year.

To check that it compiles without a device or signing:

```bash
xcodebuild -project ios/SmallHours.xcodeproj -target SmallHours \
  -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

## First night

On first launch the app asks for motion, microphone and notification access
(notifications are the backstop alarm). Grant all three.

Then: plug the phone in, ringer on, tap **Test the alarm sound** and actually
listen, set a normal Clock alarm ten minutes later as a backstop, put the phone
flat on the mattress near your hip, and tap **Start the night**.

The screen can go off. That is the point of this build.

## How it works

`UIBackgroundModes: audio` keeps the app alive overnight: an app capturing
microphone input keeps running in the background, and CoreMotion keeps
delivering while it does. If microphone access is denied, nothing keeps the app
alive once the screen locks, so it holds the screen on instead (black screen,
face down).

Three independent alarm layers, because a silent alarm is the one unforgivable bug:

1. the in-app synthesised chime, escalating over 90 seconds;
2. a scheduled local notification at the hard deadline, which survives the app
   being killed;
3. your own Clock alarm, which is why the checklist asks for it every night.

The alarm releases the microphone *before* it makes a sound. A live capture holds
the iOS audio session in play-and-record, which routes playback to the earpiece
receiver — an alarm at conversational volume, into a mattress. That failure is
invisible when you test it holding the phone.

A night in progress is checkpointed every two minutes, so if the app is killed
overnight you can finish and score it from the resume screen the next time you
open it.

## Layout

```
SmallHours/
  Engine/
    SleepEngine.swift   epochs → settledness curve + night metrics
    Scorer.swift        metrics + baseline → 0-100 with per-component reasons
  Recorder.swift        CoreMotion + AVAudioEngine → 30 s epochs
  AlarmEngine.swift     wake window, synthesised chime, backstop notification
  Storage.swift         one JSON file per night
  SmallHoursApp.swift   app entry + state machine
  Views.swift           bedtime / tracking / alarm / resume
  MorningView.swift     the score, the night curve, history
```

`Engine/` is pure Foundation — no UIKit, no SwiftUI — and is a port of the engine
in the web app (`docs/index.html`). Both should produce the same score from the
same epochs. If you change the maths in one, port it to the other; the web
engine is covered by `node test/scorer.check.mjs`.

## What it will not tell you

No REM. No deep-sleep minutes. No stage percentages.

Motion-only sleep staging agrees with polysomnography at Cohen's κ ≈ 0.084
(Walch et al. 2019) — statistically indistinguishable from chance. This app shows
Awake / Restless / Settled, which is what movement can support, and refuses to
score a night it could not read rather than inventing one.

## Privacy

Audio never leaves the tap callback in `Recorder.swift`. Each buffer is reduced
immediately to a level in dBFS, a peak and a 60–500 Hz band energy; no audio is
retained, written or transmitted. Nights are plain JSON files in the app's
Application Support directory (`SmallHours/`), on the device only. The app makes
no network requests.
