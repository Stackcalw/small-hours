// node test/scorer.check.mjs
// Slices the shipped <script> blocks out of docs/index.html (so the check cannot
// drift from the app) and runs the real engine — Stager.analyze + Scorer.compute,
// through Scorer.scoreNight, the path every saved night takes — on three
// synthetic nights: a good one, a broken one, and two that must get no score.
// No dependencies.
import fs from "node:fs"; import vm from "node:vm"; import assert from "node:assert/strict";

const html = fs.readFileSync(new URL("../docs/index.html", import.meta.url), "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
assert.ok(scripts.length >= 4, "expected the app's inline <script> blocks");
// Every block except the last (screens + boot); top-level const/let stay in one scope.
const src = scripts.slice(0, -1).join("\n;\n") + "\n;globalThis.__engine = { Stager, Scorer, EPOCH_MS };";

const el = () => ({ textContent: "", innerHTML: "", style: {}, dataset: {}, addEventListener(){}, querySelectorAll: () => [] });
const store = new Map();
const ctx = {
  window: { addEventListener(){}, matchMedia: () => ({ matches: false }) },
  document: { getElementById: el, createElement: el, addEventListener(){}, documentElement: el(), body: { classList: { add(){}, remove(){} } } },
  navigator: {},
  localStorage: { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k), key: () => null, length: 0 },
  getComputedStyle: () => ({ getPropertyValue: () => "" }),
  setTimeout, clearTimeout, setInterval, clearInterval, console, Date, Math, JSON,
};
ctx.globalThis = ctx;
vm.runInNewContext(src, ctx);
const { Scorer, EPOCH_MS } = ctx.__engine;

// --- synthetic nights ------------------------------------------------------
// Deterministic PRNG so the check is stable run to run.
let seed = 42;
const rand = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
const START = new Date(2026, 0, 10, 23, 0, 0).getTime();   // 23:00 local
const EPM = 60000 / EPOCH_MS;                                // epochs per minute

/* segments: [minutes, level] — level = mean bed motion for that stretch */
function night(segments, { audio = true } = {}) {
  const epochs = []; let t = START;
  for (const [mins, level] of segments) {
    for (let i = 0; i < mins * EPM; i++) {
      const m = Math.max(0.05, level * (0.75 + 0.5 * rand()));
      epochs.push({ t, m: +m.toFixed(2), mp: +(m * 2.5).toFixed(2),
        a: audio ? -62 + Math.round(4 * rand()) : null, ap: audio ? -55 : null, ab: audio ? 40 : null });
      t += EPOCH_MS;
    }
  }
  return { epochs, startAt: START, endAt: t };
}
const AWAKE = 22, TOSS = 6, STILL = 0.35;

// Good: 10 minutes to drop off, ~8h of mostly still sleep with the brief
// turnovers every sleeper has, then a short wake at the end.
const goodSegs = [[10, AWAKE]];
for (let c = 0; c < 6; c++) goodSegs.push([75, STILL], [3, TOSS]);
goodSegs.push([5, AWAKE]);
const good = night(goodSegs);

// Broken: 50 minutes to drop off, then sleep chopped by eight long wake-ups,
// ~6h of actual sleep over 8.5h in bed.
const brokenSegs = [[50, AWAKE]];
for (let c = 0; c < 8; c++) brokenSegs.push([45, STILL + 0.3], [14, AWAKE]);
brokenSegs.push([5, AWAKE]);
const broken = night(brokenSegs);

// Unreadable: the phone was on the nightstand — eight hours of a flat sensor
// noise floor, nothing reaching it. A still phone must never be scored as
// perfect sleep.
const nightstand = night([[480, 0.2]]);
for (const e of nightstand.epochs) { e.m = +(0.2 + 0.01 * rand()).toFixed(3); e.mp = +(e.m * 1.2).toFixed(3); }
// Too short: five minutes of data.
const tooShort = night([[5, AWAKE]]);

// --- run --------------------------------------------------------------------
const base = Scorer.baseline([]);
// Sleep-log mode (no motion sensor): a capped, labelled estimate — never above 78.
const logOnly = night([[480, 0]]); for (const e of logOnly.epochs) { e.m = null; e.mp = null; }
const run = (n) => Scorer.scoreNight(n.epochs, n.startAt, n.endAt, base);
const g = run(good), b = run(broken), u = run(nightstand), s = run(tooShort), l = run(logOnly);

const fmt = (r) => `score ${r.score}  ok ${r.a.ok}  asleep ${(r.a.asleepMs / 3.6e6).toFixed(1)}h  eff ${r.a.efficiency == null ? "-" : r.a.efficiency.toFixed(2)}  wakes ${r.a.awakenings}  latency ${r.a.latencyMs == null ? "-" : Math.round(r.a.latencyMs / 60000) + "m"}`;
console.log("good      ", fmt(g));
console.log("broken    ", fmt(b));
console.log("nightstand", `score ${u.score}  ok ${u.a.ok}  "${u.a.reason}"`);
console.log("log only  ", `score ${l.score}  ok ${l.a.ok}  estimated ${l.a.estimated}`);
console.log("too short ", `score ${s.score}  ok ${s.a.ok}  "${s.a.reason}"`);

assert.equal(g.a.ok, true, "the good night should be readable: " + g.a.reason);
assert.equal(b.a.ok, true, "the broken night should still be readable: " + b.a.reason);
assert.equal(typeof g.score, "number");
assert.equal(typeof b.score, "number");
assert.ok(g.score > b.score, `good (${g.score}) should outscore broken (${b.score})`);
assert.ok(g.score >= 70, `a clean 8h night should score well, got ${g.score}`);
assert.ok(g.score - b.score >= 15, `the gap between good and broken should be clear, got ${g.score - b.score}`);
assert.ok(b.a.awakenings > g.a.awakenings, "broken should show more wake-ups");

assert.equal(u.a.ok, false, "a night with no movement reaching the phone must be unreadable");
assert.equal(u.score, null, "an unreadable night must get no score");
assert.equal(s.a.ok, false, "five minutes of data must be unreadable");
assert.equal(s.score, null, "a too-short night must get no score");

assert.equal(l.a.estimated, true);
assert.ok(typeof l.score === "number" && l.score <= 78, `a times-only night is capped at 78, got ${l.score}`);

// No REM / deep-sleep staging is ever produced.
for (const r of [g, b]) assert.ok(r.a.states.every((x) => ["awake", "restless", "settled"].includes(x)));

console.log(`ok — good ${g.score} > broken ${b.score}; unreadable and too-short nights get no score`);
