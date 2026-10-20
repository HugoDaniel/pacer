// PacerRt — the playback-runtime glue against the REAL pacer-rt.wasm
// artifact (built by pretest / `zig build verify`) and the REAL packed
// fixture (packed by the pretest hook and by verify from
// tools/testdata/pacb/full-small.score.sjon). No mocks: every assertion
// crosses the wasm boundary.
//
// The binary score carries no source text, yet it is not nameless: scene
// names ride the blob's 'SNAM' section and decode exactly, while spans
// stay the original compile-time source coordinates. Declared-only target
// names are still null because 'DECL' carries registry/ncomp only (names
// never cross the wire for targets). Pre-SNAM cartridges keep the
// source-free '' name with the span as the authoritative anchor — the
// compat tests pin both reader generations.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Pacer } from '../src/index.js';
import { PacerRt } from '../src/rt.js';
import { parseHarness, renderCase } from './harness.js';

const PPC = 720720n;
const BEAT = PPC / 4n; // 4/4 meter, tick grid
const BAR = 4n * BEAT;

const rtWasmPath = fileURLToPath(new URL('../../../zig-out/bin/pacer-rt.wasm', import.meta.url));
const rtWasmModule = new WebAssembly.Module(readFileSync(rtWasmPath));
const controlWasmModule = new WebAssembly.Module(
  readFileSync(fileURLToPath(new URL('../../../zig-out/bin/pacer.wasm', import.meta.url))),
);
const fixture = readFileSync(fileURLToPath(new URL('./rt-fixture.pacb', import.meta.url)));
const keysOnly = readFileSync(
  fileURLToPath(new URL('../../../tools/testdata/pacb/keys-only.pacb', import.meta.url)),
);
const fullSmallBytes = readFileSync(
  fileURLToPath(new URL('../../../tools/testdata/pacb/full-small.score.sjon', import.meta.url)),
);
const fullSmallDoc = fullSmallBytes.toString('utf8');
/** PACM spans are UTF-8 BYTE offsets; slice the byte authority. */
const sourceAt = (span) => fullSmallBytes.subarray(span.start, span.end).toString('utf8');

test('load: the real full-small pack is armed; metadata is exact', async () => {
  const driver = await PacerRt.load(rtWasmModule, fixture);
  assert.equal(driver.ok, true);
  assert.deepEqual(driver.diagnostics, []);
  assert.equal(driver.status, 0);

  const meta = driver.meta;
  assert.equal(meta.transport.bpm, 120);
  assert.equal(meta.transport.beatsPerBar, 4);
  assert.equal(meta.transport.dur, 4n * BAR);
  assert.equal(meta.transport.end, 'loop');
  assert.deepEqual(meta.tempoMap, [
    { tick: 0n, bpm: 120 },
    { tick: 8n * BEAT, bpm: 160 },
  ]);

  // Pack order is the compile order: the two top-level key tracks, the
  // expr track, the scened key track, then the trigger.
  assert.deepEqual(
    meta.tracks.map((t) => [t.targetId, t.registry, t.ncomp, t.source]),
    [
      [0, 0, 1, 'keys'],
      [1, 0, 4, 'keys'],
      [3, 1, 1, 'expr'],
      [0, 0, 1, 'keys'],
      [2, 0, 4, 'trigger'],
    ],
  );
  // Declared-only targets have no host name and 'DECL' never carries
  // names — both drivers report null here rather than inventing one.
  assert.deepEqual(
    meta.tracks.map((t) => t.name),
    [null, null, null, null, null],
  );

  assert.equal(meta.tracks[0].keys.length, 3);
  assert.equal(meta.tracks[0].keys[1].at, 4n * BEAT);
  assert.equal(meta.tracks[0].keys[1].easeRef, 1);
  assert.deepEqual(meta.tracks[0].keys[1].value, [Math.fround(0.9), 0, 0, 0]);
  // Spans are preserved in the ORIGINAL source's byte coordinates even
  // though the runtime has no source. Slice the authority fixture.
  assert.equal(sourceAt(meta.tracks[0].keys[1].span), '(key :at 4b :value 0.9 :ease out-cubic)');

  assert.equal(meta.controls.length, 1);
  assert.deepEqual(
    {
      index: meta.controls[0].index,
      id: meta.controls[0].id,
      targetId: meta.controls[0].targetId,
      registry: meta.controls[0].registry,
      ncomp: meta.controls[0].ncomp,
      type: meta.controls[0].type,
      value: meta.controls[0].value,
      min: meta.controls[0].min,
      max: meta.controls[0].max,
    },
    {
      index: 0,
      id: 'depth',
      targetId: 4,
      registry: 1,
      ncomp: 1,
      type: 'slider',
      value: [0.25, 0, 0, 0],
      min: [0, 0, 0, 0],
      max: [1, 0, 0, 0],
    },
  );
  assert.equal(sourceAt(meta.controls[0].valueSpan), '0.25');

  assert.equal(meta.scenes.length, 1);
  assert.equal(meta.scenes[0].startTick, 8n * BEAT);
  assert.equal(meta.scenes[0].durTicks, 8n * BEAT);
  // The name travels IN the blob ('SNAM', source-free) and decodes
  // exactly; the span keeps its provenance as the commit anchor.
  assert.equal(sourceAt(meta.scenes[0].nameSpan), 'drop');
  assert.equal(meta.scenes[0].name, 'drop');

  assert.deepEqual(
    meta.easePrograms.map((p) => p.stages[0].ops[0].code),
    ['linear', 'out_cubic', 'in_out_quad'],
  );

  // The frame path is the real binary evaluator, not a text fallback.
  assert.equal(driver.evalBytes(0.5)?.length, 152);
  const entries = driver.eval(0.5);
  assert.equal(entries.length, 7);
  assert.equal(entries[0].targetId, 5); // beat emit lane
  assert.equal(entries[1].targetId, 6); // bar emit lane
  const glow = entries.find((e) => e.targetId === 0 && e.registry === 0 && e.ncomp === 1);
  assert.equal(glow.value[0], 0.5625);
  assert.equal(glow.name, null);
});

test('parity: text Pacer and binary PacerRt run the same harness byte-for-byte', async () => {
  // The shared harness: evals, a numeric control pin/clear, and a bpm
  // nudge (false on full-small because its score carries a tempo map —
  // both drivers must refuse identically).
  const harness = parseHarness(`(times "0000000000000000" "3FE0000000000000" "4010000000000000")
(set-control :index 0 :value ["3F666666" "00000000" "00000000" "00000000"])
(clear-control :index 0)
(set-bpm :bpm "406E000000000000")`);
  const text = await Pacer.load(controlWasmModule, fullSmallDoc, {
    registries: harness.registries,
  });
  const rt = await PacerRt.load(rtWasmModule, fixture, { registries: harness.registries });
  assert.equal(text.ok, true);
  assert.equal(rt.ok, true);

  // The eval stream is the determinism claim: compare raw 'PACW' bytes
  // at a time sweep, including negative and out-of-range clocks.
  for (const seconds of [0, 0.125, 0.5, 1, 4, -2.5, 60]) {
    assert.deepEqual(rt.evalBytes(seconds), text.evalBytes(seconds), `t=${seconds}`);
  }

  // The same script through the ONE shared renderer — compared EXACTLY.
  // Raw eval bytes are the determinism claim above; here everything —
  // load, diagnostics, meta, every write, control acceptance, bpm
  // acceptance, and the scene-name line — is identical, because 'SNAM'
  // carries the name in the blob. The former name-line diff exemption
  // is retired: the owner-decided exact-parity requirement is met by
  // the source-free metadata itself.
  const textRendered = await renderCase(fullSmallDoc, harness, text);
  const rtRendered = await renderCase(fullSmallDoc, harness, rt);
  assert.equal(rtRendered, textRendered);
});

test('SNAM carries exact 300-byte and 66000-byte names from a real CLI pack', async (t) => {
  // The wire name length is u32 on purpose (R4): a 66,000-byte name is
  // one byte past what any u16 length could express. The names come from
  // an ACTUAL fresh compile + pack — the exact pretest/`build:rt-fixture`
  // invocation (`zig build run -- pack … --out …`, the freshly built
  // CLI, not the possibly-stale installed zig-out copy) — not from a
  // synthetic wire blob. zig is host-native: present on the wave host,
  // absent elsewhere, where this test skips loudly (never silently).
  const probe = spawnSync('zig', ['version'], { encoding: 'utf8' });
  if (probe.error) {
    return t.skip(
      `zig toolchain unavailable on this host (${probe.error.code ?? probe.error.message}); the real-CLI pack legs run on the wave host`,
    );
  }
  const name300 = 'a'.repeat(300);
  const name66000 = 'b'.repeat(66000);
  const dir = await mkdtemp(path.join(tmpdir(), 'pacer-snam-long-'));
  try {
    const scorePath = path.join(dir, 'long-names.score.sjon');
    const pacbPath = path.join(dir, 'long-names.pacb');
    await writeFile(
      scorePath,
      [
        '(target :name glow :arity 1 :registry 0)',
        '(transport :bpm 120 :meter [4 4] :dur 4bar :end loop)',
        `(scene :name ${name300} :at 0b :dur 8b`,
        '  (track :target glow (key :at 0b :value 0.5)))',
        `(scene :name ${name66000} :at 8b :dur 8b`,
        '  (track :target glow (key :at 8b :value 0.8)))',
        '',
      ].join('\n'),
    );
    const packed = spawnSync('zig', ['build', 'run', '--', 'pack', scorePath, '--out', pacbPath], {
      encoding: 'utf8',
      cwd: fileURLToPath(new URL('../../../', import.meta.url)),
    });
    assert.equal(packed.error, undefined, `pacer pack failed to run: ${packed.error}`);
    assert.equal(packed.status, 0, `pacer pack refused the score: ${packed.stderr}`);

    const driver = await PacerRt.load(rtWasmModule, readFileSync(pacbPath));
    assert.equal(driver.ok, true);
    const meta = driver.meta;
    assert.equal(meta.scenes.length, 2);
    // Exact: no truncation, no drop, no degrade — at either length.
    assert.equal(meta.scenes[0].name, name300);
    assert.equal(meta.scenes[1].name, name66000);
    // nameSpan provenance unchanged: the spans anchor the source symbols.
    assert.equal(meta.scenes[0].nameSpan.end - meta.scenes[0].nameSpan.start, 300);
    assert.equal(meta.scenes[1].nameSpan.end - meta.scenes[1].nameSpan.start, 66000);
    // The runtime stays fully live over the big-name score.
    assert.ok((driver.evalBytes(0.5)?.length ?? 0) > 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('registry mismatch: status 1 + reason 9, never a fabricated diagnostic', async () => {
  // full-small's pack-time join is empty (all targets declared). A host
  // that registers a non-empty join is a different canonical 'PACT', so
  // the runtime refuses with the frozen registry_mismatch reason.
  const driver = await PacerRt.load(rtWasmModule, fixture, {
    registries: [[{ name: 'glow' }]],
  });
  assert.equal(driver.ok, false);
  assert.equal(driver.status, 1);
  assert.equal(driver.reason, 9);
  // PACB carries no 'PACD' blob. A binary refusal has no compiler
  // message to relay, so the diagnostics array stays empty — status and
  // reason are the honest report.
  assert.deepEqual(driver.diagnostics, []);
  assert.equal(driver.eval(0), null);
});

test('refused reload is transactional: old score, control and bpm state stay live', async () => {
  const corrupt = Uint8Array.from(fixture);
  corrupt.fill(0x58, 0, 8); // 'XXXX…' — bad magic, a status-1 refusal

  // Control state: full-small has a document control at slot 0.
  const full = await PacerRt.load(rtWasmModule, fixture);
  assert.equal(full.setControl('depth', 0.9), true);
  const controlFrame = full.evalBytes(0.5);
  assert.equal(full.exprFailures, 0);
  const refusedControl = full.load(corrupt);
  assert.equal(refusedControl.ok, false);
  assert.equal(full.status, 1);
  assert.equal(full.reason, 0); // bad_magic
  // The old score is STILL the armed one: driver.ok stays true (the
  // runtime is "live, eval armed"), while the load's own result is false.
  assert.equal(full.ok, true);
  assert.deepEqual(full.evalBytes(0.5), controlFrame);
  const held = full.eval(0.5).find((e) => e.targetId === 4);
  assert.equal(held.value[0], Math.fround(0.9));
  assert.equal(full.exprFailures, 0);

  // BPM state: keys-only has no tempo map, so the nudge is accepted.
  const keys = await PacerRt.load(rtWasmModule, keysOnly);
  assert.equal(keys.setBpm(240), true);
  const nudgedFrame = keys.evalBytes(1);
  assert.notDeepEqual(nudgedFrame, null);
  const refusedBpm = keys.load(corrupt);
  assert.equal(refusedBpm.ok, false);
  assert.equal(keys.status, 1);
  assert.equal(keys.ok, true);
  assert.deepEqual(keys.evalBytes(1), nudgedFrame);
  // Still nudgeable (the evaluator, not a fresh one, is live).
  assert.equal(keys.setBpm(180), true);
});

test('a second successful load re-takes the meta views (keys-only replaces full-small)', async () => {
  const driver = await PacerRt.load(rtWasmModule, fixture);
  const first = driver.meta;
  assert.equal(first.scenes.length, 1);
  assert.deepEqual(first.tempoMap, [
    { tick: 0n, bpm: 120 },
    { tick: 8n * BEAT, bpm: 160 },
  ]);

  const result = driver.load(keysOnly);
  assert.equal(result.ok, true);
  assert.equal(driver.ok, true);
  assert.equal(driver.status, 0);

  const second = driver.meta;
  assert.notEqual(second, first, 'the cached meta object must not survive a successful load');
  // keys-only: 2bar at a constant 120 bpm, no tempo/section extras.
  assert.equal(second.transport.dur, 2n * BAR);
  assert.deepEqual(second.tempoMap, []);
  assert.deepEqual(second.scenes, []);
  assert.deepEqual(second.controls, []);
  assert.equal(
    second.easePrograms.map((p) => p.stages[0].ops[0].code).join(','),
    'linear,out_cubic',
  );
  assert.deepEqual(
    second.tracks.map((t) => [t.targetId, t.registry, t.ncomp, t.source, t.keys.length]),
    [
      [0, 0, 1, 'keys', 2],
      [1, 0, 3, 'keys', 2],
    ],
  );
  assert.deepEqual(
    second.tracks[0].keys.map((k) => [k.at, k.value[0]]),
    [
      [0n, Math.fround(0.2)],
      [4n * BEAT, Math.fround(0.8)],
    ],
  );
  // The frame path is the NEW score, not a stale view of the old one.
  const entries = driver.eval(0);
  assert.equal(entries.length, 2);
  assert.deepEqual(
    entries.map((e) => [e.targetId, e.value[0]]),
    [
      [0, Math.fround(0.2)],
      [1, 1],
    ],
  );
  assert.deepEqual(entries[1].value, Float32Array.of(1, 0, 0, 0));
});

test('no public reload(text): the binary load is the only load verb', () => {
  assert.equal(PacerRt.prototype.reload, undefined);
  assert.equal(Object.hasOwn(PacerRt.prototype, 'reload'), false);
  assert.equal(typeof PacerRt.prototype.load, 'function');
});

test('evalTicks + the control surface mirror Pacer (declared names unavailable)', async () => {
  const driver = await PacerRt.load(rtWasmModule, fixture);
  // Tick-domain twin: 2 beats at 120 bpm is exactly 1 second.
  assert.deepEqual(driver.evalTicks(2n * BEAT), driver.eval(1));
  assert.equal(driver.evalTicks(0n).length, driver.eval(0).length);
  // Out-of-range tick mirrors the seconds path: null, not a throw.
  assert.equal(driver.evalTicks(1n << 60n), null);
  assert.equal(driver.evalTicks(-(1n << 60n)), null);

  // Declared-only target names never cross the wire ('DECL' is
  // registry/ncomp only), so a name lookup cannot resolve them even
  // though the target exists at id 0. Text Pacer with an empty host join
  // behaves identically; hosts route these writes by registry.
  assert.equal(driver.registerControl('glow'), null);
  assert.equal(driver.registerControl('not-a-target'), null);
  assert.equal(driver.setControl('depth', 0.5), true);
  assert.equal(driver.clearControl('depth'), true);
  assert.equal(driver.setControl('unknown-control', 1), false);
  assert.equal(driver.clearControl('unknown-control'), false);
});

test('robust load: typed bytes, zone overflow and bad calls stay honest', async () => {
  // A Uint8Array and an ArrayBuffer are both accepted without copying.
  const typed = await PacerRt.load(rtWasmModule, new Uint8Array(fixture));
  assert.equal(typed.ok, true);
  const fromBuffer = await PacerRt.load(rtWasmModule, new Uint8Array(fixture).buffer);
  assert.equal(fromBuffer.ok, true);

  // Malformed bytes are a status-1 refusal: no throw, and no fabricated
  // compiler diagnostic (PACB carries no 'PACD'; status/reason are the
  // honest report).
  const bad = await PacerRt.load(rtWasmModule, Uint8Array.of(0x58, 0x58, 0x58, 0x58));
  assert.equal(bad.ok, false);
  assert.equal(bad.status, 1);
  assert.equal(bad.reason, 0);
  assert.deepEqual(bad.diagnostics, []);
  assert.equal(bad.eval(0), null);

  // Zone overflow is rejected before the wasm zone is touched: the live
  // score, its frame, and the status word are all unchanged.
  const driver = await PacerRt.load(rtWasmModule, fixture);
  const frame = driver.evalBytes(0.5);
  const inst = await WebAssembly.instantiate(rtWasmModule, {
    env: { sjon_host_invoke_plugin: () => 0 },
  });
  const cap = inst.exports.prt_pacbCap();
  assert.throws(
    () => driver.load(new Uint8Array(cap + 1)),
    /pacer-rt: PACB is .* over prt_pacbCap/,
  );
  assert.equal(driver.status, 0);
  assert.deepEqual(driver.evalBytes(0.5), frame);

  // The underlying export's bad-call classes (length and malformed
  // 'PACT') are true no-ops, exactly as rt_entry.zig documents. This is
  // the binary equivalent of "no fake compile errors".
  const e = inst.exports;
  const pact = Uint8Array.of(0x50, 0x41, 0x43, 0x54, 0, 0, 0, 0);
  new Uint8Array(e.memory.buffer).set(pact, e.prt_targetsPtr());
  new Uint8Array(e.memory.buffer).set(fixture, e.prt_pacbPtr());
  assert.equal(e.prt_load(fixture.length, pact.length), 0);
  const liveFrame = (() => {
    const n = e.prt_eval(0.5);
    return new Uint8Array(e.memory.buffer).slice(e.prt_writesPtr(), e.prt_writesPtr() + n);
  })();
  const reasonBefore = e.prt_loadError();
  assert.equal(e.prt_load(cap + 1, pact.length), 2);
  assert.equal(e.prt_load(fixture.length, 64 * 1024 + 1), 2);
  // A malformed 'PACT' is the same status-2 class, not a compile error.
  new Uint8Array(e.memory.buffer).fill(0, e.prt_targetsPtr(), e.prt_targetsPtr() + pact.length);
  assert.equal(e.prt_load(fixture.length, pact.length), 2);
  const liveAgain = (() => {
    const n = e.prt_eval(0.5);
    return new Uint8Array(e.memory.buffer).slice(e.prt_writesPtr(), e.prt_writesPtr() + n);
  })();
  assert.deepEqual(liveAgain, liveFrame);
  assert.equal(e.prt_loadError(), reasonBefore);
});
