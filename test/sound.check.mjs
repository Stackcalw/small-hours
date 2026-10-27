// node test/sound.check.mjs [--esc50 /tmp/esc50]
// Runs the shipped sound code on real recordings: docs/sound-worklet.js (the
// per-frame maths the AudioWorklet does on the phone) and the SoundEvents
// detector sliced out of docs/index.html, so neither can drift from the app.
//
// Data: ESC-50 (K. J. Piczak, CC BY-NC 3.0) — NOT in this repo. Fetch it to
// /tmp/esc50 first (see README, "Testing the sound detector").
// The shipped model (SoundEvents.MODEL) was fitted on folds 1-3 only. Folds
// 4-5 are held out: that table is the honest number. Runs in worker threads
// (one per core); a few minutes over 720 clips.
import fs from "node:fs"; import vm from "node:vm"; import path from "node:path"; import os from "node:os";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";

const args = process.argv.slice(2);
const DIR = args.includes("--esc50") ? args[args.indexOf("--esc50") + 1] : (process.env.ESC50 || "/tmp/esc50");
const root = new URL("../docs/", import.meta.url);

// --- the shipped code ------------------------------------------------------
const ctx = { Math, Float32Array, Int16Array, Set, console };
ctx.globalThis = ctx;
vm.runInNewContext(fs.readFileSync(new URL("sound-worklet.js", root), "utf8"), ctx);
const html = fs.readFileSync(new URL("index.html", root), "utf8");
const block = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]).find((s) => s.includes("const SoundEvents"));
if (!block) throw new Error("SoundEvents block not found in docs/index.html");
vm.runInNewContext(block + "\n;globalThis.SoundEvents = SoundEvents;", ctx);
const { SoundDSP, SoundEvents } = ctx;

// --- data ------------------------------------------------------------------
const csv = path.join(DIR, "esc50.csv");
if (!fs.existsSync(csv)) { console.log(`ESC-50 not found at ${DIR} — skipping (see README to fetch it).`); process.exit(0); }
const rows = fs.readFileSync(csv, "utf8").trim().split("\n").slice(1).map((l) => { const c = l.split(","); return { file: c[0], fold: +c[1], cat: c[3] }; });
const POS = ["coughing", "snoring"];
const NEG = ["breathing", "sneezing", "laughing", "door_wood_knock", "footsteps", "clock_tick", "rain", "keyboard_typing", "car_horn", "dog", "door_wood_creaks", "clapping", "mouse_click", "drinking_sipping", "cat", "clock_alarm"];
const have = (r) => fs.existsSync(path.join(DIR, "audio", r.file));

function readWav(p) {
  const b = fs.readFileSync(p); let o = 12, fmt, data;
  while (o + 8 <= b.length) {
    const id = b.toString("ascii", o, o + 4), sz = b.readUInt32LE(o + 4);
    if (id === "fmt ") fmt = { ch: b.readUInt16LE(o + 10), sr: b.readUInt32LE(o + 12), bits: b.readUInt16LE(o + 22) };
    if (id === "data") { data = b.subarray(o + 8, o + 8 + sz); break; }
    o += 8 + sz + (sz & 1);
  }
  if (!fmt || fmt.bits !== 16) throw new Error("only 16-bit PCM WAV: " + p);
  const n = Math.floor(data.length / 2 / fmt.ch), x = new Float32Array(n);
  for (let i = 0; i < n; i++) { let s = 0; for (let c = 0; c < fmt.ch; c++) s += data.readInt16LE((i * fmt.ch + c) * 2) / 32768; x[i] = s / fmt.ch; }
  return { sr: fmt.sr, x };
}
/* every clip is resampled to 48 kHz — what a phone's AudioContext runs at */
const SR = 48000;
function resample(x, from) {
  if (from === SR) return x;
  const r = from / SR, n = Math.floor(x.length / r), y = new Float32Array(n);
  for (let i = 0; i < n; i++) { const p = i * r, k = Math.floor(p), f = p - k; y[i] = (x[k] || 0) * (1 - f) + (x[k + 1] || 0) * f; }
  return y;
}
const cache = new Map();
const clip = (r) => { if (!cache.has(r.file)) { const w = readWav(path.join(DIR, "audio", r.file)); cache.set(r.file, norm(resample(w.x, w.sr))); } return cache.get(r.file); };

let seed = 7;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
/* quiet-room bed: pink noise (Voss-McCartney/Kellet) at about -60 dBFS RMS */
function pink(n, db) {
  let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0; const o = new Float32Array(n); let s = 0;
  for (let i = 0; i < n; i++) {
    const w = rnd() * 2 - 1;
    b0 = .99886 * b0 + w * .0555179; b1 = .99332 * b1 + w * .0750759; b2 = .969 * b2 + w * .153852;
    b3 = .8665 * b3 + w * .3104856; b4 = .55 * b4 + w * .5329522; b5 = -.7616 * b5 - w * .016898;
    o[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * .5362; b6 = w * .115926; s += o[i] * o[i];
  }
  const g = 10 ** (db / 20) / Math.sqrt(s / n); for (let i = 0; i < n; i++) o[i] *= g; return o;
}
/* Level: each clip is scaled so its loudest 50 ms sits at -35 dBFS — a cough
   or snore a metre or so from a phone — over a -60 dBFS quiet room. */
function norm(x) {
  const N = 2400; let mx = 1e-12;
  for (let i = 0; i + N <= x.length; i += N / 2) { let q = 0; for (let k = i; k < i + N; k++) q += x[k] * x[k]; mx = Math.max(mx, q / N); }
  const g = 10 ** ((-35 - 10 * Math.log10(mx)) / 20), y = new Float32Array(x.length);
  for (let i = 0; i < x.length; i++) y[i] = x[i] * g;
  return y;
}

function run(signal, over) {
  const dsp = new SoundDSP(SR), det = SoundEvents.create(over), evs = [];
  let t = 0;
  for (let i = 0; i < signal.length; i += 128) {
    for (const f of dsp.process(signal.subarray(i, i + 128))) { evs.push(...SoundEvents.push(det, f, t)); t += SoundEvents.FRAME_MS; }
  }
  evs.push(...SoundEvents.flush(det));
  return evs;
}
/* One test case per clip. A cough is judged on the clip alone. A snore needs a
   rhythm, which one 5 s clip cannot show, so the snore test plays the clip
   four times in a row (as a stretch of snoring would sound) — and every
   negative class gets exactly the same treatment, so repetition alone earns
   nothing. */
function caseFor(r, reps) {
  const c = clip(r), lead = SR * 8, n = lead + c.length * reps + SR * 2;
  const s = pink(n, -60);
  for (let k = 0; k < reps; k++) for (let i = 0; i < c.length; i++) s[lead + k * c.length + i] += c[i];
  return s;
}

/* per clip: did a cough fire on the clip alone, did a snore fire on it x4 */
function judge(r) {
  return { file: r.file, c: run(caseFor(r, 1)).some((e) => e.type === "cough"), s: run(caseFor(r, 4)).some((e) => e.type === "snore") };
}

function table(set, res, label) {
  const lines = [], agg = { pos: {}, neg: { c: 0, s: 0, n: 0 } };
  lines.push(`\n${label}`);
  lines.push("class               clips   cough-detected   snore-detected");
  for (const cat of [...POS, ...NEG]) {
    const rs = set.filter((r) => r.cat === cat && res.has(r.file)); if (!rs.length) continue;
    const c = rs.filter((r) => res.get(r.file).c).length, s = rs.filter((r) => res.get(r.file).s).length;
    const pc = (v) => `${String(Math.round(100 * v / rs.length)).padStart(3)}%`;
    lines.push(`${cat.padEnd(18)} ${String(rs.length).padStart(5)}   ${pc(c).padStart(14)}   ${pc(s).padStart(14)}`);
    if (POS.includes(cat)) agg.pos[cat] = { c: c / rs.length, s: s / rs.length };
    else { agg.neg.c += c; agg.neg.s += s; agg.neg.n += rs.length; }
  }
  const fpC = agg.neg.c / agg.neg.n, fpS = agg.neg.s / agg.neg.n;
  lines.push(`-> cough recall ${Math.round(100 * agg.pos.coughing.c)}% (target 80) · snore recall ${Math.round(100 * agg.pos.snoring.s)}% (target 70) · false cough on negatives ${(100 * fpC).toFixed(1)}% · false snore on negatives ${(100 * fpS).toFixed(1)}% (target <=10 each)`);
  console.log(lines.join("\n"));
  return { cough: agg.pos.coughing.c, snore: agg.pos.snoring.s, fpC, fpS };
}

/* A simulated night: 40 minutes of quiet room with coughs, snore stretches
   and negatives dropped in at known times, all from held-out clips. */
function night(set) {
  const mins = 40, n = SR * 60 * mins, s = pink(n, -60), truth = [];
  const pick = (cat) => set.filter((r) => r.cat === cat && have(r));
  const put = (r, at) => { const c = clip(r); for (let i = 0; i < c.length && at + i < n; i++) s[at + i] += c[i]; };
  let at = SR * 30;
  const coughs = pick("coughing").slice(0, 8), snores = pick("snoring").slice(0, 4), negs = NEG.flatMap((c) => pick(c).slice(0, 1));
  for (const r of coughs) { put(r, at); truth.push({ type: "cough", t: at / SR }); at += SR * 50; }
  for (const r of snores) { const t0 = at; for (let k = 0; k < 6; k++) { put(r, at); at += SR * 5; } truth.push({ type: "snore", t: t0 / SR }); at += SR * 40; }
  for (const r of negs) { if (at > n - SR * 10) break; put(r, at); truth.push({ type: "other:" + r.cat, t: at / SR }); at += SR * 25; }
  const evs = run(s);
  const sum = SoundEvents.summarize(evs, 30000);
  console.log(`\nsimulated ${mins}-minute night (held-out clips over a -60 dBFS pink-noise room):`);
  console.log(`  planted: ${coughs.length} cough clips (some hold several coughs), ${snores.length} snore stretches of 30 s, ${negs.length} other sounds`);
  console.log(`  found:   ${sum.coughs} coughs in ${new Set(evs.filter((e) => e.type === "cough").map((e) => Math.floor(e.t / 50000))).size} of the ${coughs.length} cough slots, ${sum.fits} coughing fits, ${sum.snoreMin} snore minutes (truth ≈ ${(snores.length * 30 / 60).toFixed(1)}), ${sum.other} other events`);
  const falseC = evs.filter((e) => e.type === "cough" && e.t / 1000 > (30 + 50 * coughs.length) - 5).length;
  const falseS = evs.filter((e) => e.type === "snore" && truth.some((x) => x.type.startsWith("other") && Math.abs(x.t - e.t / 1000) < 10)).length;
  console.log(`  coughs called during the negative sounds: ${falseC} · snores called near negative sounds: ${falseS}`);
}

const all = rows.filter((r) => [...POS, ...NEG].includes(r.cat) && have(r));
if (!isMainThread) {
  parentPort.postMessage(all.filter((_, i) => i % workerData.n === workerData.k).map(judge));
} else {
  /* always: a silent room must produce nothing */
  const quiet = run(pink(SR * 60, -60));
  if (quiet.length) { console.log(`FAIL — ${quiet.length} events in a minute of quiet room`); process.exit(1); }
  console.log("ok — a minute of quiet room (-60 dBFS pink noise) produces no events");
  console.log(`ESC-50 at ${DIR}; ${all.length} clips; tuning folds 1-3, held-out folds 4-5; loudest 50 ms of each clip at -35 dBFS over a -60 dBFS room`);
  const n = Math.max(1, Math.min(os.cpus().length, 12));
  const parts = await Promise.all([...Array(n).keys()].map((k) => new Promise((ok, bad) => {
    const w = new Worker(new URL(import.meta.url), { workerData: { k, n }, argv: process.argv.slice(2) });
    w.once("message", ok); w.once("error", bad);
  })));
  const res = new Map(parts.flat().map((x) => [x.file, x]));
  table(all.filter((r) => r.fold <= 3), res, "TUNING folds 1-3 (the model was fitted on these)");
  const H = table(all.filter((r) => r.fold >= 4), res, "HELD-OUT folds 4-5 (never seen while fitting or tuning)");
  night(rows.filter((r) => r.fold >= 4));
  const hit = (v, t) => v >= t ? "met" : "MISSED";
  console.log(`\nheld-out vs targets: cough recall ${Math.round(100 * H.cough)}% (${hit(H.cough, 0.8)}), snore recall ${Math.round(100 * H.snore)}% (${hit(H.snore, 0.7)}), false cough ${(100 * H.fpC).toFixed(1)}% (${hit(-H.fpC, -0.1)}), false snore ${(100 * H.fpS).toFixed(1)}% (${hit(-H.fpS, -0.1)})`);
  /* regression guard (not the targets): fail only if the shipped code drifts well below what it scored when committed */
  const ok = H.cough >= 0.6 && H.snore >= 0.55 && H.fpC <= 0.15 && H.fpS <= 0.06;
  console.log(`${ok ? "ok" : "FAIL"} — shipped detector reproduces its held-out score`);
  if (!ok) process.exit(1);
}
