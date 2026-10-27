/* Small Hours — sound worklet.
   Runs on the audio thread. Per 50 ms frame it reduces the microphone to a
   handful of numbers (loudness, a low band where snoring sits, a high band
   where a cough's burst sits, zero-crossing rate) and hands back a 8 kHz mono
   copy of the same 50 ms so the page can keep a few seconds in memory for an
   optional clip. Nothing here touches the network or the disk.

   SoundDSP is plain maths with no Web Audio dependency, so the test
   (test/sound.check.mjs) runs this exact file in node. */

/* RBJ audio-EQ-cookbook biquad, direct form I. */
class Biquad {
  constructor(type, f0, sr, q) {
    const w = 2 * Math.PI * f0 / sr, cs = Math.cos(w), al = Math.sin(w) / (2 * (q || Math.SQRT1_2));
    let b0, b1, b2;
    if (type === 'lp') { b0 = (1 - cs) / 2; b1 = 1 - cs; b2 = (1 - cs) / 2; }
    else { b0 = (1 + cs) / 2; b1 = -(1 + cs); b2 = (1 + cs) / 2; }   // 'hp'
    const a0 = 1 + al;
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0;
    this.a1 = -2 * cs / a0; this.a2 = (1 - al) / a0;
    this.x1 = 0; this.x2 = 0; this.y1 = 0; this.y2 = 0;
  }
  step(x) {
    const y = this.b0 * x + this.b1 * this.x1 + this.b2 * this.x2 - this.a1 * this.y1 - this.a2 * this.y2;
    this.x2 = this.x1; this.x1 = x; this.y2 = this.y1; this.y1 = y;
    return y;
  }
}

class SoundDSP {
  constructor(sr) {
    this.sr = sr;
    this.N = Math.round(sr * 0.05);                         // 50 ms frame
    /* band-pass = high-pass + low-pass biquad pair */
    this.loHP = new Biquad('hp', 60, sr); this.loLP = new Biquad('lp', 500, sr);
    this.hiHP = new Biquad('hp', 1000, sr); this.hiLP = new Biquad('lp', Math.min(4000, sr * 0.45), sr);
    /* a coarse six-band spectrum for the event classifier's shape features */
    this.EDGES = [60, 250, 500, 1000, 2000, 4000, Math.min(8000, sr * 0.45)];
    this.bands = [];
    for (let b = 0; b < 6; b++) this.bands.push([new Biquad('hp', this.EDGES[b], sr), new Biquad('lp', this.EDGES[b + 1], sr)]);
    this.bAcc = new Float64Array(6);
    /* anti-alias before dropping to 8 kHz */
    this.aa1 = new Biquad('lp', 3400, sr); this.aa2 = new Biquad('lp', 3400, sr);
    this.step = sr / 8000; this.pos = 0; this.prev = 0;
    this.n = 0; this.sq = 0; this.lo = 0; this.hi = 0; this.zc = 0; this.last = 0;
    this.pcm = []; this.frame = 0;
  }
  /* block: Float32Array of mono samples. Returns completed frames, each
     { i, db, lo, hi, zcr, pcm: Int16Array (8 kHz, this frame's 50 ms) }. */
  process(block) {
    const out = [];
    for (let k = 0; k < block.length; k++) {
      const x = block[k];
      this.sq += x * x;
      const l = this.loLP.step(this.loHP.step(x)); this.lo += l * l;
      const h = this.hiLP.step(this.hiHP.step(x)); this.hi += h * h;
      for (let b = 0; b < 6; b++) { const y = this.bands[b][1].step(this.bands[b][0].step(x)); this.bAcc[b] += y * y; }
      if ((x >= 0) !== (this.last >= 0)) this.zc++;
      this.last = x;
      const a = this.aa2.step(this.aa1.step(x));
      this.pos += 1;
      while (this.pos >= this.step) {                      // linear-interpolated decimation
        this.pos -= this.step;
        const f = 1 - this.pos;                             // fraction between prev and a
        const v = this.prev + (a - this.prev) * Math.min(1, Math.max(0, f));
        this.pcm.push(Math.max(-32768, Math.min(32767, Math.round(v * 32767))));
      }
      this.prev = a;
      if (++this.n >= this.N) {
        const N = this.n, db = v => +(10 * Math.log10(Math.max(v / N, 1e-14))).toFixed(1);
        const pcm = Int16Array.from(this.pcm);
        out.push({ i: this.frame++, db: db(this.sq), lo: db(this.lo), hi: db(this.hi), zcr: +(this.zc / N).toFixed(3), vo: SoundDSP.voicing(pcm), b: Array.from(this.bAcc, db), pcm });
        this.bAcc.fill(0); this.n = 0; this.sq = 0; this.lo = 0; this.hi = 0; this.zc = 0; this.pcm = [];
      }
    }
    return out;
  }
  /* Voicing: the best normalised autocorrelation at a pitch lag of 80-800 Hz
     on the 8 kHz copy. Near 1 for a voice, a bark or a laugh (a pitch); low
     for the noisy burst of a cough or the rattle of a snore. */
  static voicing(p) {
    const n = p.length; if (n < 120) return 0;
    let best = 0;
    for (let lag = 10; lag <= 100; lag++) {
      let r = 0, e1 = 0, e2 = 0;
      for (let i = 0; i + lag < n; i++) { const a = p[i], b = p[i + lag]; r += a * b; e1 += a * a; e2 += b * b; }
      const v = e1 && e2 ? r / Math.sqrt(e1 * e2) : 0;
      if (v > best) best = v;
    }
    return +best.toFixed(2);
  }
}

if (typeof registerProcessor === 'function') {
  class SmallHoursSound extends AudioWorkletProcessor {
    constructor() {
      super();
      this.dsp = new SoundDSP(sampleRate);
      this.port.postMessage({ hello: true, sr: sampleRate });
    }
    process(inputs, outputs) {
      const inp = inputs[0];
      if (inp && inp.length && inp[0]) {
        let mono = inp[0];
        if (inp.length > 1) { mono = new Float32Array(inp[0].length); for (const ch of inp) for (let i = 0; i < ch.length; i++) mono[i] += ch[i] / inp.length; }
        for (const f of this.dsp.process(mono)) this.port.postMessage(f, [f.pcm.buffer]);
      }
      /* output stays silent; it exists only so the node is pulled */
      const o = outputs[0]; if (o) for (const ch of o) ch.fill(0);
      return true;
    }
  }
  registerProcessor('small-hours-sound', SmallHoursSound);
}
if (typeof globalThis !== 'undefined' && typeof registerProcessor !== 'function') globalThis.SoundDSP = SoundDSP;
