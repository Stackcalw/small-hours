# Small Hours

A sleep tracker for a phone lying on your mattress. It feels the bed move and
listens to how loud the room is, then gives you one score out of 100 in the
morning — with the reasons behind it, and nothing it cannot back up.

It comes in two forms:

- **`docs/`** — a web app. One static HTML file plus a manifest, a service worker
  and icons. No build step, no framework, no server code. Serve it over HTTPS
  (GitHub Pages can serve `main:/docs` as-is) and add it to your home screen.
- **`ios/`** — a native SwiftUI app with the same engine. It can keep sensing with
  the screen off, which a web page cannot.

> Not medical advice. Small Hours is a phone on a mattress, not a sleep lab. It
> cannot diagnose anything. If you think you have a sleep disorder, talk to a
> doctor.

## How it works

Put the phone flat on the mattress near your hip, plugged in, and tap **Start the
night**. Body movement reaches the phone as vibration through the mattress.

- **Movement** is reduced to one activity figure (mean and peak) per 30-second
  epoch.
- **Sound**, if you allow the microphone, is reduced to the loudness of each
  epoch (mean and peak dBFS) and the energy in the 60–500 Hz band where snoring
  sits. Sound is used only to flag likely snoring; it never decides whether you
  were asleep.
- The epochs go through a Cole–Kripke-shaped weighted window with a threshold set
  from the night itself, then Webster-style rescoring (stillness right after a
  long wake is not yet sleep). The result is a curve of **Awake / Restless /
  Settled** and a set of night metrics.
- An optional **wake window** (20, 30 or 45 minutes before your alarm time) lets
  the alarm go off at a restless moment instead of the deadline. It always rings
  by the time you set.
- In the morning you rate how rested you feel. That rating is shown **next to**
  the score, never blended into it — the gap between the two is the interesting
  part.

## What it scores

Six components, weights summing to 100. Every curve is written out in the code
(`Scorer` in `docs/index.html`, `Engine/Scorer.swift` on iOS).

| Component | Weight | What it measures |
|---|---:|---|
| How long you slept | 30 | Time asleep. Full marks from 7.5 to 9 hours; tapers above and below. |
| Time asleep vs time in bed | 18 | Sleep efficiency. Full marks at 92% and above. |
| Staying asleep | 17 | Minutes awake after first falling asleep, with an extra penalty for more than two separate wake-ups. |
| How settled the sleep was | 12 | Share of sleep that was very still. Best around 20–27%; both too little and implausibly much lose points. |
| Falling asleep | 11 | Time to fall asleep. Full marks for 8–18 minutes; very fast (a sign of sleep debt) and slow both lose points. |
| Same hours as usual | 12 | How far the middle of tonight's sleep was from your usual (a circular mean of past nights). Needs three scored nights first. |

A component that cannot be measured yet — regularity before night three, or
anything movement-based on a night without movement — **drops out and its
weight is shared among the rest**, so night one gets a real score instead of a
penalty for being night one.

Each score also carries a confidence label (*full read / partial read / thin
read*) from how complete the data was, and names the component that cost you the
most points.

## What it deliberately does not claim

- **No REM, no deep sleep, no stage percentages.** Movement alone cannot tell
  those stages apart: motion-only staging agrees with polysomnography at roughly
  chance level (Cohen's κ ≈ 0.084, Walch et al. 2019). "Settled" means *still*,
  not *deep*.
- **No score for a night it could not read.** Under ten minutes of data, under
  45 minutes of detected sleep, or a phone that felt essentially no movement all
  night (a phone on the nightstand looks exactly like perfect sleep) — these get
  a reason, not a number. Under three hours in bed is logged as a nap and not
  scored.
- **No movement at all** (a laptop, or motion access refused): the web app runs as
  a sleep log and alarm. Sleep time is estimated from time in bed, only length
  and regularity are scored, and the score is capped at 78 and labelled
  *estimated*.
- **No streaks, no day counts.** A missed night is just a missed night.
- Lying perfectly still while awake counts as asleep. If falling asleep felt
  longer than the app says, trust yourself.

## Privacy

Everything stays on the device. There are no accounts, no analytics and no
server. Checked in the code:

- **Audio is never recorded.** The web app connects the microphone only to a Web
  Audio `AnalyserNode` (never to the speakers, never to a `MediaRecorder`) and
  reads it four times a second; each read is reduced to a few numbers and
  discarded. The iOS app does the same inside the `AVAudioEngine` tap callback.
  No audio buffer is kept, written to disk or sent anywhere.
- **What is stored — web** (`localStorage`, keys starting with `smallhours:`):
  - `smallhours:meta/settings` — alarm time, wake window, the sensor check result;
  - `smallhours:nights/YYYY-MM-DD` — one record per night: bed and wake times,
    score and confidence, sleep time, efficiency, latency, wake-ups, minutes
    awake, share of settled sleep, middle-of-sleep time, data coverage, minutes
    of likely snoring, the per-epoch curve (Awake / Restless / Settled and a 0–1
    stillness value) and your "how rested" answer;
  - `smallhours:live` — while a night is running, the raw epochs (per 30 s:
    movement mean/peak, sound level mean/peak, 60–500 Hz band energy), so a
    reloaded page can finish the night. Deleted when the night ends; the epochs
    are not kept in the night record.
- **What is stored — iOS**: one JSON file per night in the app's Application
  Support directory with the same kind of night metrics and curve as the web app,
  plus `session.json`, which holds the raw epochs of a night in progress and is
  deleted when the night ends.
- **Network:** the iOS app makes no network requests. The web app makes no
  third-party requests at all: the page, its two fonts (Fraunces and IBM Plex
  Sans, self-hosted in `docs/fonts/` under the SIL Open Font License), its icons
  and its manifest all come from the same origin, and the service worker caches
  them so it opens offline.
- **Export / import:** "Your data" on the web app's home screen exports every
  night to a JSON file and imports one on another device (merging; a night
  already on the device wins). It also has *Delete everything*. Clearing the
  site's data in your browser deletes your nights, so export now and then if you
  want a backup.

## Web vs iOS

| | Web (`docs/`) | iOS (`ios/`) |
|---|---|---|
| Install | Open the URL, *Add to Home Screen* | Build with Xcode, sign with your own Apple ID |
| Screen during the night | Must stay on. Uses the Wake Lock API where available; otherwise set Auto-Lock to Never | Can turn off (background audio mode) |
| Motion | `DeviceMotionEvent`, high-pass filtered. iOS Safari asks for permission from a tap | CoreMotion `userAcceleration` (gravity already removed) |
| Alarm | Synthesised in the page; rings only if the page is still open and the ringer is up. **A nice alarm, never your only alarm** | Synthesised chime plus a scheduled notification backstop that survives the app being killed |
| Storage | `localStorage`, export/import JSON | JSON files in Application Support |
| Offline | Service worker caches the app shell | Native |

Whichever you use, set your phone's normal alarm ten minutes after as a backstop.

## Running it

**Web.** It is a static site; any HTTPS host works. Motion, microphone and Wake
Lock need a secure context (HTTPS, or `localhost` for development) and the page
opened top-level in the browser.

```bash
cd docs && python3 -m http.server 8000
# open http://localhost:8000
```

A desktop browser has no motion sensor, so the sensor check will say so and the
app runs as a sleep log — that is expected. To try the real thing, serve it over
HTTPS (for example GitHub Pages from `main:/docs`) and open it on a phone. On
iPhone, tap **Run the check** and allow Motion & Orientation and the microphone
when Safari asks.

When you change any file the service worker caches, bump `VERSION` in
`docs/sw.js`.

**iOS.** See [`ios/README.md`](ios/README.md).

**Tests.** The scoring engine check needs only Node 18+:

```bash
node test/scorer.check.mjs
```

It loads the engine straight out of `docs/index.html` and checks that a good
synthetic night outscores a broken one, that an unreadable and a too-short night
get no score, and that a times-only night is capped.

**Icons.** `python3 tools/make_icons.py` regenerates `docs/icons/` (needs Pillow).

## Bedtime, 30 seconds

1. Plug the phone in.
2. Ringer on, volume up. Tap **Test the alarm sound** and actually listen — that
   is exactly how loud it will be.
3. Web app: Settings → Display & Brightness → Auto-Lock → **Never** (unless the
   check says the screen can stay awake on its own).
4. Set your normal alarm ten minutes after, as a backstop.
5. Phone flat on the mattress near your hip, screen down. Tap **Start the night**.

In the morning: hold the button to get up, read the score and the one line under
*What cost you the most*, and tap how rested you actually feel.

## License

MIT — see [LICENSE](LICENSE).
