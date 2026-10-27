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
- **Sound**, if you allow the microphone, goes two ways. An analyser gives each
  epoch's loudness (mean and peak dBFS) and 60–500 Hz band energy. An
  `AudioWorklet` (`docs/sound-worklet.js`) reduces every 50 ms to a few numbers
  (loudness, low/high band, six-band spectrum, zero crossings, voicing), and
  `SoundEvents` turns those into **coughs, snores and other noise**: an adaptive
  floor (the quiet 10th percentile of the last minute), events that rise 10 dB
  over it, and two small classifiers (60 boosted decision stumps each, fitted
  on ESC-50 folds 1–3). Coughs are counted, and two or more within 10 s make a
  coughing fit. A snore
  must also *repeat at breathing pace* — one snore-like sound alone is not
  called a snore. Sound never decides whether you were asleep.
- **Patterns** (on the history screen, from five nights) — bedtime and wake-time
  regularity, weekday vs weekend shift, snoring and cough trends, the hour sounds
  cluster in, and score vs bedtime. Descriptive only; not a diagnosis.
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

- **Audio is analysed on the phone; nothing is ever uploaded.** The page has no
  network code at all. The microphone feeds a Web Audio analyser and an
  `AudioWorklet`, both reduced to a few numbers per moment and discarded. The
  graph ends in a gain of 0 (Safari only runs a graph that reaches the
  speakers, but nothing is audible) and there is no `MediaRecorder`.
- **If, and only if, the clip switch is on** ("Save short clips of snores and
  coughs — kept on this phone only", off by default), short clips of detected
  events (0.5 s before to 1 s after, at most 4 s, 8 kHz mono WAV) are stored on
  the phone in this browser's IndexedDB (`smallhours-audio`) and **auto-deleted
  after 7 nights**. At most 10 coughs, 10 snores and 5 other noises a night
  (the loudest kept). Clips are never in the JSON export. Delete one from the
  morning screen; *Delete everything* deletes them all. The iOS app keeps no
  audio.
- **What is stored — web** (`localStorage`, keys starting with `smallhours:`):
  - `smallhours:meta/settings` — alarm time, wake window, the sensor check result;
  - `smallhours:nights/YYYY-MM-DD` — one record per night: bed and wake times,
    score and confidence, sleep time, efficiency, latency, wake-ups, minutes
    awake, share of settled sleep, middle-of-sleep time, data coverage, minutes
    of likely snoring, cough/snore/noise counts with their times (no audio),
    the per-epoch curve (Awake / Restless / Settled and a 0–1
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

**Testing the sound detector.** `test/sound.check.mjs` runs the shipped worklet
DSP (`docs/sound-worklet.js`) and the `SoundEvents` block sliced out of
`docs/index.html` on real recordings from
[ESC-50](https://github.com/karolpiczak/ESC-50) (CC BY-NC 3.0, **not** in this
repo): coughing and snoring against 16 other classes (breathing, sneezing,
laughing, dog, footsteps, doors, rain, clocks, typing…). Each clip is scaled so
its loudest 50 ms sits at −35 dBFS over a −60 dBFS pink-noise room at 48 kHz;
the snore test plays each clip four times in a row (a snore must repeat), and
every negative class gets the same treatment. It also plants held-out clips in
a simulated 40-minute night.

```bash
mkdir -p /tmp/esc50/audio && cd /tmp/esc50
curl -sLO https://raw.githubusercontent.com/karolpiczak/ESC-50/master/meta/esc50.csv
# the 18 classes the test uses (40 clips each) into audio/:
awk -F, 'NR>1 && $4 ~ /^(coughing|snoring|breathing|sneezing|laughing|door_wood_knock|footsteps|clock_tick|rain|keyboard_typing|car_horn|dog|door_wood_creaks|clapping|mouse_click|drinking_sipping|cat|clock_alarm)$/ {print $1}' esc50.csv \
  | xargs -P 8 -I{} curl -sSfL -o audio/{} https://raw.githubusercontent.com/karolpiczak/ESC-50/master/audio/{}
cd - && node test/sound.check.mjs   # a few minutes, one worker per core
```

The model was fitted on folds 1–3 only; folds 4–5 were never used for fitting
or tuning. **Held-out (folds 4–5, 16 clips per class):** coughs caught in
**69%** of cough clips (target 80% — missed), snores in **63%** of snore clips
(target 70% — missed); of the 16 other classes, **13.3%** of clips fire a false
cough (target ≤10% — missed; sneezes, laughs, barks and car horns are the usual
culprits) and **1.6%** a false snore (met). Treat the counts as a trend across
nights, not a per-event truth — the clips, if you save them, let you check, and
"not a snore / not a cough" corrects the night.

**Microphone on phones.** The app asks for a raw track (no echo cancelling,
noise suppression or gain control, which would erase snoring). If that track
carries only digital zeros for four seconds — some devices do this — it reopens
the microphone with the browser's defaults; the Sound check on the setup screen
does the same and remembers which worked. On iPhone the graph shares the
alarm's `AudioContext`, is resumed after interruptions, and is pulled through a
silent gain so WebKit actually runs it.

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
