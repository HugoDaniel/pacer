// Smoke tests against the real pacer.wasm artifact (built by the
// pretest hook: `zig build wasm`). Golden values mirror the Zig-side
// Eval tests; key-tick values are compared bit-exactly via Math.fround
// (the structural-landing guarantee survives the WASM boundary).

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { applyParams, paramRegistry, sointuHost } from '../src/audio.js';
import { masterClock } from '../src/clock.js';
import { Pacer } from '../src/index.js';
import { routeWrites, toUniforms } from '../src/route.js';

const wasmPath = fileURLToPath(new URL('../../../zig-out/bin/pacer.wasm', import.meta.url));
const wasmModule = new WebAssembly.Module(readFileSync(wasmPath));

const REGISTRIES = [[{ name: 'radius' }, { name: 'tint', ncomp: 3 }], [{ name: 'cutoff' }]];

const SCORE = `(transport :bpm 120 :meter [4 4])
(track :target radius
  (key :at 0b :value 0.2)
  (key :at 4b :value 0.8))
(track :target tint
  (key :at 0b :value [1 0 0])
  (key :at 2b :value [0 1 0] :ease in-out-quad))
(track :target cutoff
  (key :at 0b :value 200)
  (key :at 8b :value 8000))`;

const TICKS_PER_BEAT = 180180n; // PPC 720720 / 4 beats per bar

test('clean load: ok, no diagnostics, golden eval values', async () => {
  const driver = await Pacer.load(wasmModule, SCORE, { registries: REGISTRIES });
  assert.equal(driver.ok, true);
  assert.deepEqual(driver.diagnostics, []);

  // Key ticks land bit-exactly on the f32 key values.
  const atStart = driver.eval(0);
  assert.equal(atStart.length, 3);
  assert.equal(atStart[0].value[0], Math.fround(0.2));
  assert.equal(driver.eval(2.0)[0].value[0], Math.fround(0.8)); // 4 beats

  // Mid-segment linear: 0.2 + 0.6·0.5 = 0.5 (2 beats of 4).
  assert.equal(driver.eval(1.0)[0].value[0], 0.5);

  // Vector lanes: in-out-quad(0.5) = 0.5 at 1 beat of 2.
  const tint = driver.eval(0.5)[1];
  assert.equal(tint.ncomp, 3);
  assert.ok(Math.abs(tint.value[0] - 0.5) < 1e-6);
  assert.ok(Math.abs(tint.value[1] - 0.5) < 1e-6);
  assert.equal(tint.value[3], 0);
});

test('evalTicks is the tick-domain twin of eval', async () => {
  const driver = await Pacer.load(wasmModule, SCORE, { registries: REGISTRIES });
  assert.equal(driver.evalTicks(0n)[0].value[0], Math.fround(0.2));
  assert.equal(driver.evalTicks(4n * TICKS_PER_BEAT)[0].value[0], Math.fround(0.8));
  // 1.0 s at 120 bpm 4/4 is exactly 2 beats — same bytes both ways.
  const bySeconds = driver.eval(1.0)[0].value[0];
  assert.equal(driver.evalTicks(2n * TICKS_PER_BEAT)[0].value[0], bySeconds);
});

test('routing: registry split and pngine-style uniforms', async () => {
  const driver = await Pacer.load(wasmModule, SCORE, { registries: REGISTRIES });
  const entries = driver.eval(1.0);

  const [visual, audio] = routeWrites(entries, 2);
  assert.deepEqual(
    visual.map((e) => e.name),
    ['radius', 'tint'],
  );
  assert.deepEqual(
    audio.map((e) => e.name),
    ['cutoff'],
  );

  const uniforms = toUniforms(entries, 0);
  assert.equal(typeof uniforms.radius, 'number');
  assert.equal(uniforms.tint.length, 3);
  assert.equal(uniforms.cutoff, undefined);
  const params = toUniforms(entries, 1);
  assert.equal(typeof params.cutoff, 'number');
});

test('trigger writes: meta source and toUniforms lane routing', async () => {
  // A periodic ncomp-4 target (all four lanes) on the visual bus and an
  // explicit ncomp-1 target (phase only) on the audio bus.
  const score = `(transport :bpm 120 :meter [4 4])
(trigger :target pulse :every 1b :offset 1b)
(trigger :target hit :at [2b 4b])`;
  const driver = await Pacer.load(wasmModule, score, {
    registries: [[{ name: 'pulse', ncomp: 4 }], [{ name: 'hit' }]],
  });
  assert.equal(driver.ok, true);

  // The meta mirror names the new source byte (2 → 'trigger'); triggers
  // carry no keyframes.
  assert.deepEqual(
    driver.meta.tracks.map((t) => t.source),
    ['trigger', 'trigger'],
  );
  assert.deepEqual(driver.meta.tracks[0].keys, []);

  // Before the first event the write is omitted — the lane never appears.
  assert.equal(toUniforms(driver.eval(0), 0).pulse, undefined);

  // On the exact event tick (beat 1 = 0.5 s) all four lanes flow through
  // as an array: phase 0, count 0, gate 1, beats-since 0.
  assert.deepEqual(toUniforms(driver.eval(0.5), 0).pulse, [0, 0, 1, 0]);

  // The explicit ncomp-1 hit writes phase only, on its own (audio) bus:
  // silent before its first event (2b), then phase 0 landing exactly on it
  // (span = 4b − 2b, so this first-of-two event is not the held-1.0 last).
  assert.equal(toUniforms(driver.eval(0.5), 1).hit, undefined);
  assert.equal(toUniforms(driver.eval(1.0), 1).hit, 0);
});

test('diagnostics: pacer + SJON codes with user-coordinate spans', async () => {
  const badTarget = `(transport :bpm 120)
(track :target nonexistent (key :at 0b :value 1))`;
  const driver = await Pacer.load(wasmModule, badTarget, { registries: REGISTRIES });
  assert.equal(driver.ok, false);
  assert.equal(driver.eval(0), null);
  assert.equal(driver.diagnostics.length, 1);
  const diag = driver.diagnostics[0];
  assert.equal(diag.source, 'pacer');
  assert.equal(diag.severity, 'error');
  assert.equal(badTarget.slice(diag.start, diag.end), 'nonexistent');
  assert.match(diag.message, /nonexistent/);

  // SJON validation diagnostics ride the same blob: bare position number.
  const bareNumber = `(transport :bpm 120)
(track :target radius (key :at 4 :value 1))`;
  const { ok, diagnostics } = driver.reload(bareNumber);
  assert.equal(ok, false);
  const sjonDiag = diagnostics.find((d) => d.source === 'sjon');
  assert.ok(sjonDiag);
  assert.equal(bareNumber.slice(sjonDiag.start, sjonDiag.start + 1), '4');
});

test('reload recovers from a broken score', async () => {
  const driver = await Pacer.load(wasmModule, '(broken', { registries: REGISTRIES });
  assert.equal(driver.ok, false);
  assert.equal(driver.eval(0), null);

  const { ok } = driver.reload(SCORE);
  assert.equal(ok, true);
  assert.equal(driver.eval(1.0)[0].value[0], 0.5);
});

test('expr tracks evaluate through the boundary', async () => {
  const score = `(transport :bpm 120 :meter [4 4])
(track :target radius :expr (+ 0.25 (* 0.25 beat)))
(track :target tint :expr [phase phase phase])`;
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  assert.equal(driver.ok, true);

  // beat = 2·seconds at 120 bpm; phase = beat/4 — all dyadic-exact.
  assert.equal(driver.eval(0)[0].value[0], 0.25);
  const at1s = driver.eval(1.0);
  assert.equal(at1s[0].value[0], 0.75);
  assert.equal(at1s[1].ncomp, 3);
  assert.equal(at1s[1].value[0], 0.5);
  assert.equal(at1s[1].value[3], 0);
});

test('expr runtime failure omits the write (count 0 ≠ not loaded)', async () => {
  // Dry-run at beat 0 passes (1/2); beat 2 (t=1s) divides by zero —
  // the write is omitted for that frame and the host holds its last
  // value. An empty frame is [] (count-0 'PACW'), never null.
  const score = `(transport :bpm 120)
(track :target radius :expr (/ 1 (- 2 beat)))`;
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  assert.equal(driver.eval(0).length, 1);
  assert.deepEqual(driver.eval(1.0), []);
  assert.equal(driver.eval(1.5).length, 1);
});

test('determinism: two instances produce byte-identical writes', async () => {
  const score = `(transport :bpm 97 :meter [7 8] :dur 4bar :end loop)
(track :target radius
  (key :at 0b :value 0.1)
  (key :at 3b :value 0.9 :ease (spring :damping 0.4 :periods 3)))
(track :target tint
  (key :at 0b :value [0 0 0])
  (key :at 2bar :value [1 1 1] :ease in-out-expo))
(track :target cutoff
  :expr (+ 200 (* 100 (sin (* (tau) phase)))))`;
  const a = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  const b = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  for (const t of [0, 0.123456789, 1.5, 7.25, -2.5, 1e-9, 60.0]) {
    assert.deepEqual(a.evalBytes(t), b.evalBytes(t), `divergence at t=${t}`);
  }
});

test('controls: document value writes, live override, clear restores', async () => {
  const score = `(transport :bpm 120)
(control :id knob :target radius :value 0.4)
(track :target radius
  (key :at 0b :value 0.0)
  (key :at 4b :value 1.0))`;
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  assert.equal(driver.ok, true);

  // Track write first, control write last — toUniforms folds in order,
  // so the pin outranks the score on the same target.
  const entries = driver.eval(1.0);
  assert.equal(entries.length, 2);
  assert.equal(entries[0].value[0], 0.5);
  assert.equal(toUniforms(entries, 0).radius, Math.fround(0.4));

  assert.equal(driver.setControl('knob', 0.9), true);
  assert.equal(toUniforms(driver.eval(1.0), 0).radius, Math.fround(0.9));
  assert.equal(driver.clearControl('knob'), true);
  assert.equal(toUniforms(driver.eval(1.0), 0).radius, Math.fround(0.4));
});

test('controls steer expressions live', async () => {
  const score = `(transport :bpm 120)
(control :id sway :value 0.5)
(track :target radius :expr (* sway 2))`;
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  assert.equal(driver.eval(0)[0].value[0], 1);
  assert.equal(driver.setControl('sway', 0.25), true);
  assert.equal(driver.eval(0)[0].value[0], 0.5);
});

test('meta: transport, key ticks, and the commit-to-text anchors', async () => {
  const score = `(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
(control :id knob :target radius :min 0 :max 1 :value 0.4)
(track :target radius
  (key :at 0b :value 0.0)
  (key :at 4b :value 1.0))
(track :target cutoff :expr (* knob 8000))`;
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  const meta = driver.meta;

  assert.equal(meta.transport.bpm, 120);
  assert.equal(meta.transport.end, 'loop');
  assert.equal(meta.transport.dur, 2n * 4n * TICKS_PER_BEAT);

  const track = meta.tracks[0];
  assert.equal(track.name, 'radius');
  assert.equal(track.source, 'keys');
  assert.equal(track.keys.length, 2);
  assert.equal(track.keys[1].at, 4n * TICKS_PER_BEAT);
  assert.equal(
    score.slice(track.keys[1].span.start, track.keys[1].span.end),
    '(key :at 4b :value 1.0)',
  );
  assert.equal(meta.tracks[1].source, 'expr');
  assert.equal(meta.tracks[1].keys.length, 0);

  const knob = meta.controls.find((c) => c.id === 'knob');
  assert.equal(knob.name, 'radius');
  assert.equal(knob.type, 'slider');
  assert.deepEqual([knob.min[0], knob.max[0]], [0, 1]);
  assert.equal(score.slice(knob.valueSpan.start, knob.valueSpan.end), '0.4');
});

test('meta.scenes: named windows decode from the SCEN section', async () => {
  const score = `(transport :bpm 120 :meter [4 4])
(scene :name intro :at 0b :dur 4b
  (track :target radius (key :at 0b :value 0.1)))
(scene :name drop :at 8b :dur 4b
  (track :target radius (key :at 0b :value 0.9)))`;
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  const scenes = driver.meta.scenes;

  assert.equal(scenes.length, 2);
  assert.equal(scenes[0].name, 'intro');
  assert.equal(scenes[0].startTick, 0n);
  assert.equal(scenes[0].durTicks, 4n * TICKS_PER_BEAT);
  assert.equal(scenes[1].name, 'drop');
  assert.equal(scenes[1].startTick, 8n * TICKS_PER_BEAT);
  assert.equal(scenes[1].durTicks, 4n * TICKS_PER_BEAT);
  // The name span is a commit-to-text anchor in the score's own coordinates.
  assert.equal(score.slice(scenes[1].nameSpan.start, scenes[1].nameSpan.end), 'drop');
});

test('meta.scenes: a score with no scenes yields an empty array', async () => {
  const driver = await Pacer.load(wasmModule, SCORE, { registries: REGISTRIES });
  assert.deepEqual(driver.meta.scenes, []);
});

test('registerControl drives an unpinned target while held', async () => {
  const driver = await Pacer.load(wasmModule, SCORE, { registries: REGISTRIES });
  const slot = driver.registerControl('cutoff');
  assert.notEqual(slot, null);

  const before = toUniforms(driver.eval(1.0), 1).cutoff;
  assert.equal(driver.setControl(slot, 500), true);
  assert.equal(toUniforms(driver.eval(1.0), 1).cutoff, 500);
  assert.equal(driver.clearControl(slot), true);
  assert.equal(toUniforms(driver.eval(1.0), 1).cutoff, before);
});

test('setBpm rescales seconds; tick positions stand still', async () => {
  const driver = await Pacer.load(wasmModule, SCORE, { registries: REGISTRIES });
  assert.equal(driver.eval(1.0)[0].value[0], 0.5); // 2 of 4 beats
  assert.equal(driver.setBpm(60), true);
  assert.equal(driver.eval(1.0)[0].value[0], Math.fround(0.35)); // 1 of 4 beats
  assert.equal(driver.evalTicks(2n * TICKS_PER_BEAT)[0].value[0], 0.5);
  assert.equal(driver.setBpm(0), false);
});

// --- boundary hardening (chunk 1) -----------------------------------------

/** Hand-encode a single-target 'PACT' blob (magic, count, then one record). */
function encodePactSingle(name, ncomp, registry) {
  const nameBytes = new TextEncoder().encode(name);
  const blob = new Uint8Array(8 + 4 + nameBytes.length);
  const dv = new DataView(blob.buffer);
  dv.setUint32(0, 0x54434150, true); // 'PACT'
  dv.setUint32(4, 1, true); // count
  dv.setUint8(8, ncomp);
  dv.setUint8(9, registry);
  dv.setUint16(10, nameBytes.length, true);
  blob.set(nameBytes, 12);
  return blob;
}

test('encodeTargets rejects a registry list past MAX_TARGETS', async () => {
  const registries = [Array.from({ length: 1025 }, (_, i) => ({ name: `t${i}` }))];
  await assert.rejects(Pacer.load(wasmModule, '(transport :bpm 120)', { registries }), /1024/);
});

test('encodeTargets rejects an empty or over-long target name', async () => {
  await assert.rejects(
    Pacer.load(wasmModule, '(transport :bpm 120)', { registries: [[{ name: '' }]] }),
    /name/,
  );
  await assert.rejects(
    Pacer.load(wasmModule, '(transport :bpm 120)', {
      registries: [[{ name: 'x'.repeat(65536) }]],
    }),
    /name/,
  );
});

test('constructor rejects a targets blob larger than drv_targetsCap', async () => {
  // One target under the count + name-length caps, but its 'PACT' blob
  // (8 + 4 + 65535 = 65547 bytes) overruns the 64 KiB targets zone —
  // the constructor must reject before reload() scribbles wasm memory.
  await assert.rejects(
    Pacer.load(wasmModule, '(transport :bpm 120)', {
      registries: [[{ name: 'x'.repeat(65535) }]],
    }),
    /drv_targetsCap/,
  );
});

test('drv_load validates before teardown: a bad call is a no-op', async () => {
  const inst = await WebAssembly.instantiate(wasmModule, {
    env: { sjon_host_invoke_plugin: () => 0 },
  });
  const e = inst.exports;
  assert.equal(e.drv_abiVersion(), 1);

  const doc = new TextEncoder().encode(
    '(transport :bpm 120)\n(track :target r (key :at 0b :value 1))',
  );
  const pact = encodePactSingle('r', 1, 0);
  new Uint8Array(e.memory.buffer).set(pact, e.drv_targetsPtr());
  new Uint8Array(e.memory.buffer).set(doc, e.drv_docPtr());
  assert.equal(e.drv_load(doc.length, pact.length), 0); // ok

  const goodLen = e.drv_eval(0);
  assert.ok(goodLen > 0, 'a loaded score evaluates');

  // Malformed lengths must change nothing — the live table survives.
  assert.equal(e.drv_load(0xffffffff, 0), 2); // bad_call
  assert.equal(e.drv_eval(0), goodLen, 'the previous table stays live after a bad load');
});

test('setControl / clearControl return false for an unknown id (no throw)', async () => {
  const driver = await Pacer.load(wasmModule, SCORE, { registries: REGISTRIES });
  assert.equal(driver.setControl('nope', 1), false);
  assert.equal(driver.clearControl('nope'), false);
});

test('exprFailures counts omitted expr writes and resets on reload', async () => {
  const score = `(transport :bpm 120)
(track :target radius :expr (/ 1 (- 2 beat)))`;
  const driver = await Pacer.load(wasmModule, score, { registries: REGISTRIES });
  assert.equal(driver.exprFailures, 0);
  driver.eval(0); // beat 0 → 1/2, no failure
  assert.equal(driver.exprFailures, 0);
  driver.eval(1.0); // beat 2 → divide by zero, write omitted
  assert.equal(driver.exprFailures, 1);
  driver.reload(score); // fresh evaluator
  assert.equal(driver.exprFailures, 0);
});

test('exprFailures is 0 while nothing is loaded', async () => {
  const driver = await Pacer.load(wasmModule, '(broken', { registries: REGISTRIES });
  assert.equal(driver.ok, false);
  assert.equal(driver.exprFailures, 0);
});

test('masterClock: audio masters when playing, falls back otherwise', () => {
  let playing = false;
  const audio = { clock: () => ({ seconds: 42, playing }) };
  const clock = masterClock(audio, () => 7);
  assert.equal(clock(), 7);
  playing = true;
  assert.equal(clock(), 42);
  const noAudio = masterClock(null, () => 7);
  assert.equal(noAudio(), 7);
});

test('masterClock: the playing→stopped handoff is continuous', () => {
  let f = 100; // scripted fallback clock
  let playing = false;
  let seconds = 0;
  const audio = { clock: () => ({ seconds, playing }) };
  const clock = masterClock(audio, () => f);

  assert.equal(clock(), 100); // never mastered: raw fallback

  playing = true;
  seconds = 4.0;
  assert.equal(clock(), 4.0); // play: snap to the song position
  seconds = 4.5;
  assert.equal(clock(), 4.5);

  playing = false;
  f = 200; // the fallback timebase is unrelated —
  assert.equal(clock(), 4.5); // — pause does not jump
  f = 200.25;
  assert.equal(clock(), 4.75); // free-run advances on the fallback

  playing = true;
  seconds = 4.5;
  assert.equal(clock(), 4.5); // resume: audio is authoritative again
});

test('sointuHost adapts the Sointu player surface', () => {
  const player = { currentTime: 1.25, playing: true };
  const host = sointuHost(player);
  assert.deepEqual(host.params(), []);
  assert.deepEqual(host.clock(), { seconds: 1.25, playing: true });
  player.playing = false;
  player.currentTime = 0.5;
  assert.deepEqual(host.clock(), { seconds: 0.5, playing: false });
  host.setParam('anything', 1); // pre-rendered song: accepted, ignored
});

test('audio bus: paramRegistry joins the score, applyParams routes writes', async () => {
  const calls = [];
  const host = {
    params: () => [{ name: 'cutoff', min: 0, max: 8000, default: 200 }],
    setParam: (name, value) => calls.push([name, value]),
    clock: () => null,
  };
  const driver = await Pacer.load(wasmModule, SCORE, {
    registries: [[{ name: 'radius' }, { name: 'tint', ncomp: 3 }], paramRegistry(host)],
  });
  assert.equal(driver.ok, true);

  // 1.0 s = 2 of 8 beats: 200 + 0.25·7800 = 2150. Only the audio bus
  // reaches setParam — radius and tint stay on registry 0.
  applyParams(driver.eval(1.0), host);
  assert.deepEqual(calls, [['cutoff', 2150]]);
});

test('applyParams: registry filter and scalar/vector arity', () => {
  const calls = [];
  const host = { params: () => [], setParam: (n, v) => calls.push([n, v]), clock: () => null };
  applyParams(
    [
      { name: 'radius', registry: 0, ncomp: 1, value: Float32Array.of(9, 0, 0, 0) },
      { name: 'gain', registry: 1, ncomp: 1, value: Float32Array.of(0.5, 0, 0, 0) },
      { name: 'pan', registry: 1, ncomp: 2, value: Float32Array.of(0.25, 0.75, 0, 0) },
    ],
    host,
  );
  assert.deepEqual(calls, [
    ['gain', 0.5],
    ['pan', [0.25, 0.75]],
  ]);
});
