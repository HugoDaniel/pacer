// rt-corpus — the playback-runtime half of the determinism gate (plan 06
// A5). Walks the SAME corpus the text walk (corpus.test.js) covers and
// replays every clean case through the REAL pacer-rt.wasm, loaded from the
// REAL per-case pack the fixture generator produced this run (the ordinary
// `pacer pack` producer, the case's actual host registry join from
// parseHarness — never mined diagnostics, never a hand-written blob). The
// ordinary cases must re-derive the FROZEN golden text byte-for-byte
// through the ONE shared harness renderer; no golden is regenerated or
// altered here, and no eval-text fallback exists on the runtime.
//
// Categories follow the original domain split (src/parity_runner.zig is
// the native precedent, mirrored step for step below):
//   - clean non-pattern + clean pattern: pack → real loader → replay
//     (the classes only separate the summary counters);
//   - load-failing: the producer's refusal is asserted EXPLICITLY (exit 1,
//     named codes, no fixture bytes) — never a skip, never a mocked PACB;
//   - lifecycle scripts (reload / registry-mismatch steps) follow the
//     frozen per-path divergence contract of parity_runner's
//     replayLifecycleCase: the text leg is paired live and compared
//     byte-for-byte while both are live and equivalent; the text-only
//     steps state their binary truth explicitly instead of masking it.
//
// Fixtures are generated fresh every run (npm pretest hook / build.zig
// verify) into test/fixtures/ by tools/generate-rt-fixtures.js, which also
// writes fixtures/manifest.json — the producer identity + content digests
// this file verifies before every load, so a stale-but-compatible blob
// bites here instead of passing silently. Counts are derived from
// execution at run time, never copied; the required acceptance inventory
// is a literal name list independent of the counters.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { Pacer } from '../src/index.js';
import { PacerRt } from '../src/rt.js';
import { parseHarness, renderCase } from './harness.js';

/** Uppercase sha256, the manifest's digest spelling. */
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const corpusDir = fileURLToPath(new URL('../../../corpus/', import.meta.url));
const rtWasmPath = fileURLToPath(new URL('../../../zig-out/bin/pacer-rt.wasm', import.meta.url));
const controlWasmPath = fileURLToPath(new URL('../../../zig-out/bin/pacer.wasm', import.meta.url));
const manifestPath = fileURLToPath(new URL('./fixtures/manifest.json', import.meta.url));
const npmRtCopyPath = fileURLToPath(new URL('../pacer-rt.wasm', import.meta.url));

const rtWasmBytes = readFileSync(rtWasmPath);
const rtWasmModule = new WebAssembly.Module(rtWasmBytes);
const controlWasmModule = new WebAssembly.Module(readFileSync(controlWasmPath));

// The one inert import both drivers supply; instantiate explicitly (the
// corpus.test.js pattern) so lifecycle steps can reach the real exports
// for the test-only over-cap raw loads. No wrapper internals are read.
const IMPORTS = { env: { sjon_host_invoke_plugin: () => 0 } };

/** The same enumeration corpus.test.js walks — directories, sorted. */
const cases = readdirSync(corpusDir, { withFileTypes: true })
  .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
  .map((e) => e.name)
  .sort();
assert.ok(cases.length > 0, 'no corpus cases found');

// The generator runs FIRST in both gates (npm pretest hook, build.zig
// verify). A missing manifest is the loud "fixtures were never generated"
// failure — never an empty-list green.
if (!existsSync(manifestPath)) {
  throw new Error(
    `rt-corpus: ${manifestPath} is missing — run the fixture generator first ` +
      '(npm pretest / zig build verify); refusing to walk without real fixtures',
  );
}
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

const manifestCaseNames = Object.keys(manifest.cases).sort();
assert.deepEqual(
  manifestCaseNames,
  cases,
  'the fixture manifest and the corpus directory must name exactly the same cases',
);

// The fixtures were generated against THESE artifacts this run; a swap
// between generation and load fails here with both digests named.
assert.equal(
  manifest.producer.artifacts['zig-out/bin/pacer-rt.wasm'].sha256,
  sha256(rtWasmBytes),
  'the runtime artifact changed after fixture generation — regenerate the fixtures',
);

// Frozen refusal reasons (rt_entry.zig) asserted by the lifecycle anchors.
const REASON_VERSION = 1;
const REASON_REGISTRY_MISMATCH = 9;

// The plan 06 acceptance inventory — the four former parity skips — plus
// the all-features anchor this brief adds. A literal list, checked
// independently of the derived counters: removing one case must fail the
// run even while every remaining count stays healthy.
const REQUIRED_RT_REPLAYS = [
  'examples-starter',
  'pattern-basic',
  'pattern-env',
  'rig-studio',
  'all-features',
];

const f64FromBits = (bits) => {
  const dv = new DataView(new ArrayBuffer(8));
  dv.setBigUint64(0, bits);
  return dv.getFloat64(0);
};

/** The raw 'PACM' bytes a driver's instance currently serves. */
const metaBytes = (exports) => {
  const len = exports.prt_metaLen?.() ?? exports.drv_metaLen();
  const ptr = exports.prt_metaPtr?.() ?? exports.drv_metaPtr();
  return new Uint8Array(exports.memory.buffer, ptr, len).slice();
};

/** The case's fixture path (used for both presence and absence checks). */
const fixturePath = (name) => fileURLToPath(new URL(`./fixtures/${name}.pacb`, import.meta.url));

/** Load one packed fixture, verifying the manifest digest first. */
function loadFixture(name) {
  const entry = manifest.cases[name];
  assert.equal(entry.outcome, 'packed', `${name}: expected a packed fixture in the manifest`);
  const file = fixturePath(name);
  assert.ok(existsSync(file), `${name}: fixture ${file} is missing — regenerate the fixtures`);
  const bytes = readFileSync(file);
  assert.equal(
    sha256(bytes),
    entry.sha256,
    `${name}: fixture bytes do not match the manifest digest — the blob is stale or tampered`,
  );
  assert.equal(bytes.length, entry.bytes, `${name}: fixture size drift`);
  return bytes;
}

/** Regroup a mutated flat join into PacerRt's registry shape. */
function regroup(flat) {
  const registries = [];
  for (const t of flat) {
    while (registries.length <= t.registry) registries.push([]);
    registries[t.registry].push({ name: t.name, ncomp: t.ncomp });
  }
  return registries;
}

// Execution counters, derived at run time (the parity_runner Totals
// mirror). `skipped` is the retained skip class: nothing below can
// increment it, and the summary requires it to print 0.
const totals = {
  total: 0,
  cleanNonPattern: 0,
  cleanPattern: 0,
  loadFailing: 0,
  binaryReplayed: 0,
  skipped: 0,
  failed: 0,
};
const replayed = new Set();

/**
 * The lifecycle replay: the JS mirror of parity_runner's
 * replayLifecycleCase, over the REAL text and runtime drivers.
 * Both sessions start from the same valid score; the frozen per-path
 * table decides each step's truth. Frames are compared byte-for-byte
 * while both paths are live and equivalent; during the intentional
 * text-unloaded divergence the text eval must be exactly zero while the
 * binary keeps its live frame.
 */
async function replayLifecycle(name, doc, harness, pacb, golden) {
  // The text leg re-derives the golden (the corpus.test.js assertion,
  // repeated here so this file's pair proof is self-contained) on its own
  // driver instance; the runtime leg then walks the divergence contract.
  const textInstance = await WebAssembly.instantiate(controlWasmModule, IMPORTS);
  const renderDriver = new Pacer(textInstance, harness.registries);
  renderDriver.reload(doc);
  const renderContext = {
    rawLoad: () => textInstance.exports.drv_load(textInstance.exports.drv_docCap() + 1, 0),
  };
  const rendered = await renderCase(doc, harness, renderDriver, renderContext);
  assert.equal(rendered, golden, `${name}: the text leg must re-derive the frozen golden`);

  const rtInstance = await WebAssembly.instantiate(rtWasmModule, IMPORTS);
  const rt = new PacerRt(rtInstance, harness.registries);
  rt.load(pacb);
  assert.equal(rt.ok, true, `${name}: the runtime load must be accepted`);

  const textInstance2 = await WebAssembly.instantiate(controlWasmModule, IMPORTS);
  const text = new Pacer(textInstance2, harness.registries);
  text.reload(doc);
  assert.equal(text.ok, true, `${name}: the text load must be accepted`);

  let textLoaded = true;
  // Frames recorded since the last authored state change: a repeated
  // clock must reproduce each path's own bytes (the state oracle).
  const history = new Map();

  for (const step of harness.steps) {
    if (step.kind === 'eval') {
      const tBefore = text.exprFailures;
      const bBefore = rt.exprFailures;
      const tBytes = text.evalBytes(f64FromBits(step.bits));
      const bBytes = rt.evalBytes(f64FromBits(step.bits));

      if (!textLoaded) {
        assert.equal(tBytes, null, `${name}: unloaded text must eval zero`);
        assert.notEqual(bBytes, null, `${name}: the binary must stay live during the divergence`);
      } else {
        assert.equal(
          tBytes === null,
          bBytes === null,
          `${name}: frame presence mismatch at t=${step.bits}`,
        );
        if (tBytes !== null)
          assert.deepEqual(bBytes, tBytes, `${name}: frame bytes at t=${step.bits}`);
      }

      const record = history.get(step.bits);
      if (record) {
        if (textLoaded)
          assert.deepEqual(tBytes, record.text, `${name}: text repeat at t=${step.bits}`);
        assert.deepEqual(bBytes, record.rt, `${name}: binary repeat at t=${step.bits}`);
      } else {
        history.set(step.bits, { text: tBytes, rt: bBytes });
      }

      const tAfter = text.exprFailures;
      const bAfter = rt.exprFailures;
      assert.ok(tAfter >= tBefore && bAfter >= bBefore, `${name}: a counter decreased`);
      if (textLoaded) {
        assert.equal(
          tAfter - tBefore,
          bAfter - bBefore,
          `${name}: same-input expr-failure delta mismatch`,
        );
      } else {
        assert.equal(tAfter, tBefore, `${name}: the unloaded text counter moved`);
      }
    } else if (
      step.kind === 'set-control' ||
      step.kind === 'clear-control' ||
      step.kind === 'set-bpm' ||
      step.kind === 'register-control'
    ) {
      let tResult;
      let bResult;
      if (step.kind === 'set-control') {
        const value = step.bits.map((b) => {
          const dv = new DataView(new ArrayBuffer(4));
          dv.setUint32(0, b);
          return dv.getFloat32(0);
        });
        tResult = text.setControl(step.index, value);
        bResult = rt.setControl(step.index, value);
      } else if (step.kind === 'clear-control') {
        tResult = text.clearControl(step.index);
        bResult = rt.clearControl(step.index);
      } else if (step.kind === 'set-bpm') {
        tResult = text.setBpm(f64FromBits(step.bits));
        bResult = rt.setBpm(f64FromBits(step.bits));
      } else {
        tResult = text.registerControl(harness.flat[step.targetId].name);
        bResult = rt.registerControl(harness.flat[step.targetId].name);
      }
      if (textLoaded) {
        assert.deepEqual(bResult, tResult, `${name}: ${step.kind} acceptance mismatch`);
      } else if (step.kind === 'register-control') {
        assert.equal(tResult, null, `${name}: unloaded text registered a slot`);
      } else {
        assert.equal(tResult, false, `${name}: unloaded text accepted ${step.kind}`);
      }
      history.clear();
    } else if (step.kind === 'reload') {
      if (step.reloadKind === 'bad-call') {
        // Both paths: an over-cap length is validated BEFORE any teardown.
        // Status 2, outputs/state/reason preserved.
        const rtMeta = metaBytes(rtInstance.exports);
        const textMeta = textLoaded ? metaBytes(textInstance2.exports) : null;
        const bReason = rt.reason;
        const bCounter = rt.exprFailures;
        const tCounter = text.exprFailures;
        const bOk = rt.ok;
        const tOk = text.ok;
        const tStatus = textInstance2.exports.drv_load(textInstance2.exports.drv_docCap() + 1, 0);
        const bStatus = rtInstance.exports.prt_load(rtInstance.exports.prt_pacbCap() + 1, 0);
        assert.equal(tStatus, 2, `${name}: text bad-call status`);
        assert.equal(bStatus, 2, `${name}: binary bad-call status`);
        assert.equal(rt.reason, bReason, `${name}: bad-call changed the load-error word`);
        assert.equal(rt.exprFailures, bCounter, `${name}: bad-call moved the binary counter`);
        assert.equal(text.exprFailures, tCounter, `${name}: bad-call moved the text counter`);
        assert.equal(rt.ok, bOk, `${name}: bad-call changed the binary live state`);
        assert.equal(text.ok, tOk, `${name}: bad-call changed the text live state`);
        assert.deepEqual(metaBytes(rtInstance.exports), rtMeta, `${name}: bad-call moved the meta`);
        if (textLoaded) {
          assert.deepEqual(
            metaBytes(textInstance2.exports),
            textMeta,
            `${name}: bad-call moved text meta`,
          );
        }
      } else if (step.reloadKind === 'diagnostics') {
        // The text leg executes the fixed diagnostic source: status 1,
        // previous score unloaded. The binary arm is EXPLICITLY not
        // packed — no PACB is invented or loaded; its live state is
        // asserted unchanged instead (the frozen divergence contract).
        const rtMeta = metaBytes(rtInstance.exports);
        const bCounter = rt.exprFailures;
        const result = text.reload('(transport :bpm 0)\n');
        assert.equal(result.ok, false, `${name}: the diagnostic source compiled clean`);
        assert.equal(text.ok, false, `${name}: the text session must be unloaded`);
        assert.equal(text.meta, null, `${name}: unloaded text still serves meta`);
        textLoaded = false;
        assert.deepEqual(
          metaBytes(rtInstance.exports),
          rtMeta,
          `${name}: diagnostics moved the binary meta`,
        );
        assert.equal(rt.exprFailures, bCounter, `${name}: diagnostics moved the binary counter`);
      } else if (step.reloadKind === 'bad-version') {
        // Text is an explicit binary-only skip (no text call); the binary
        // refusal is independent of that state: corrupt version → status
        // 1, reason 1, the previous score still live.
        const rtMeta = metaBytes(rtInstance.exports);
        const bCounter = rt.exprFailures;
        const tCounter = text.exprFailures;
        const corrupt = Uint8Array.from(pacb);
        new DataView(corrupt.buffer).setUint32(4, 99, true);
        const result = rt.load(corrupt);
        assert.equal(result.ok, false, `${name}: the corrupt blob loaded`);
        assert.equal(rt.status, 1, `${name}: bad-version status`);
        assert.equal(rt.reason, REASON_VERSION, `${name}: bad-version reason`);
        assert.equal(rt.ok, true, `${name}: the old score must stay live`);
        assert.equal(rt.exprFailures, bCounter, `${name}: bad-version moved the binary counter`);
        assert.equal(text.exprFailures, tCounter, `${name}: bad-version moved the text counter`);
        assert.deepEqual(
          metaBytes(rtInstance.exports),
          rtMeta,
          `${name}: bad-version moved the meta`,
        );
      } else if (step.reloadKind === 'current') {
        // Successful reload of the ORIGINAL score on both paths: state,
        // counters and metadata reset.
        const tResult = text.reload(doc);
        assert.equal(tResult.ok, true, `${name}: the original document did not reload clean`);
        textLoaded = true;
        const bResult = rt.load(pacb);
        assert.equal(bResult.ok, true, `${name}: the original blob did not reload clean`);
        assert.equal(rt.status, 0, `${name}: current status`);
        assert.equal(text.exprFailures, 0, `${name}: text counter must reset`);
        assert.equal(rt.exprFailures, 0, `${name}: binary counter must reset`);
        assert.notEqual(text.meta, null, `${name}: text meta must be served after current`);
        assert.notEqual(rt.meta, null, `${name}: binary meta must be served after current`);
        history.clear();
      } else {
        throw new Error(`${name}: unknown reload kind ${step.reloadKind}`);
      }
    } else if (step.kind === 'registry-mismatch') {
      // Text is an explicit binary-only skip; the binary loads the SAME
      // blob against a VALID CANONICAL but mismatching host join (a
      // second runtime instance — the glue's ordinary public mechanism).
      // Malformed PACT would be status 2 and is never this case.
      const rtMeta = metaBytes(rtInstance.exports);
      const bCounter = rt.exprFailures;
      const tCounter = text.exprFailures;
      const mutated = harness.flat.map((t) => ({ ...t }));
      if (step.mode === 'structural') {
        assert.ok(mutated.length > 0, `${name}: structural mismatch needs a nonempty host join`);
        mutated[0].ncomp = mutated[0].ncomp < 4 ? mutated[0].ncomp + 1 : mutated[0].ncomp - 1;
      } else {
        const [a, b] = mutated;
        assert.ok(mutated.length >= 2, `${name}: name-swap needs two host targets`);
        assert.ok(
          a.name !== b.name &&
            a.ncomp === b.ncomp &&
            a.registry === b.registry &&
            a.name.length === b.name.length,
          `${name}: name-swap host join is not two distinct same-shaped names`,
        );
        [a.name, b.name] = [b.name, a.name];
      }
      const mismatched = await PacerRt.load(rtWasmModule, pacb, { registries: regroup(mutated) });
      assert.equal(mismatched.ok, false, `${name}: the mismatched join loaded`);
      assert.equal(mismatched.status, 1, `${name}: registry-mismatch status`);
      assert.equal(
        mismatched.reason,
        REASON_REGISTRY_MISMATCH,
        `${name}: registry-mismatch reason`,
      );
      assert.equal(
        rt.exprFailures,
        bCounter,
        `${name}: registry-mismatch moved the binary counter`,
      );
      assert.equal(
        text.exprFailures,
        tCounter,
        `${name}: registry-mismatch moved the text counter`,
      );
      assert.deepEqual(
        metaBytes(rtInstance.exports),
        rtMeta,
        `${name}: registry-mismatch moved the meta`,
      );
    } else {
      throw new Error(`${name}: unknown step kind ${step.kind}`);
    }
  }

  // Final truth is per path, never forced across the intentional
  // text-unloaded / binary-live divergence.
  if (textLoaded) {
    assert.equal(rt.exprFailures, text.exprFailures, `${name}: final counter mismatch`);
  } else {
    assert.equal(text.meta, null, `${name}: unloaded text meta must be null at the end`);
    assert.equal(text.exprFailures, 0, `${name}: unloaded text counter must be zero`);
    assert.notEqual(rt.meta, null, `${name}: the binary lost its live metadata`);
  }
}

for (const name of cases) {
  test(`rt corpus: ${name}`, async () => {
    totals.total += 1;
    try {
      const read = (file) => readFileSync(`${corpusDir}${name}/${file}`, 'utf8');
      const harness = parseHarness(read('times.sjon'));
      const doc = read('doc.sjon');
      const golden = read('expected.sjon');
      const loadRecord = golden.match(/\(load :ok (true|false)\)/);
      assert.ok(loadRecord, `${name}: the golden carries no initial (load …) record`);
      const goldenOk = loadRecord[1] === 'true';

      const entry = manifest.cases[name];
      assert.ok(entry, `${name}: no manifest entry (stale manifest) — regenerate the fixtures`);

      if (!goldenOk) {
        // Load-failing: the REAL producer's refusal, asserted explicitly.
        // No fixture bytes may exist, and none are invented.
        totals.loadFailing += 1;
        assert.equal(
          entry.outcome,
          'refused',
          `${name}: the golden compile fails — the producer must refuse`,
        );
        assert.equal(entry.exitStatus, 1, `${name}: refusal exit status`);
        assert.ok(entry.codes.length >= 1, `${name}: refusal recorded with no codes`);
        assert.equal(
          existsSync(fixturePath(name)),
          false,
          `${name}: a refused case must not leave fixture bytes`,
        );
        return;
      }

      // Clean: the binary replay. The class split is algorithmic — the
      // decoded PACM's own track-source tags, never names or substrings.
      assert.equal(
        entry.outcome,
        'packed',
        `${name}: the golden compile is clean — a pack must exist`,
      );
      const pacb = loadFixture(name);
      const instance = await WebAssembly.instantiate(rtWasmModule, IMPORTS);
      const rt = new PacerRt(instance, harness.registries);
      rt.load(pacb);
      assert.equal(rt.ok, true, `${name}: the runtime load must be accepted`);
      assert.equal(rt.status, 0, `${name}: the runtime load status`);
      assert.deepEqual(rt.diagnostics, [], `${name}: a clean pack must serve no diagnostics`);
      assert.notEqual(rt.meta, null, `${name}: meta must be served after a clean load`);
      const hasPattern = rt.meta.tracks.some((t) => t.source === 'pattern');

      const lifecycle = harness.steps.some(
        (s) => s.kind === 'reload' || s.kind === 'registry-mismatch',
      );
      if (lifecycle) {
        await replayLifecycle(name, doc, harness, pacb, golden);
      } else {
        const context = {
          rawLoad: () => instance.exports.prt_load(instance.exports.prt_pacbCap() + 1, 0),
        };
        const actual = await renderCase(doc, harness, rt, context);
        assert.equal(
          actual,
          golden,
          `${name}: the playback runtime's canonical rendering must equal the frozen golden`,
        );
      }

      // The class counter rides the decoded source tags; the replay
      // counts only after the whole case action succeeded.
      if (hasPattern) {
        totals.cleanPattern += 1;
      } else {
        totals.cleanNonPattern += 1;
      }
      totals.binaryReplayed += 1;
      replayed.add(name);
    } catch (error) {
      totals.failed += 1;
      throw error;
    }
  });
}

test('rt corpus: the shipped runtime copy is byte-identical to the fresh artifact', () => {
  assert.equal(
    sha256(readFileSync(npmRtCopyPath)),
    sha256(rtWasmBytes),
    'npm/pacer/pacer-rt.wasm must equal zig-out/bin/pacer-rt.wasm — the copy hook must run before the walk',
  );
});

test('rt corpus: summary identities — partition, zero skips, required inventory', () => {
  const missing = REQUIRED_RT_REPLAYS.filter((req) => !replayed.has(req));
  assert.deepEqual(
    missing,
    [],
    `required runtime-replay inventory did not execute the binary leg: ${missing.join(', ')}`,
  );
  assert.equal(totals.failed, 0, `${totals.failed} case(s) failed`);
  assert.equal(totals.total, cases.length, 'every enumerated case must be walked');
  assert.equal(
    totals.total,
    totals.cleanNonPattern + totals.cleanPattern + totals.loadFailing + totals.skipped,
    `class partition does not sum: total ${totals.total} != clean non-pattern ${totals.cleanNonPattern} + clean pattern ${totals.cleanPattern} + load-failing ${totals.loadFailing} + skipped ${totals.skipped}`,
  );
  assert.equal(
    totals.binaryReplayed,
    totals.cleanNonPattern + totals.cleanPattern,
    'the binary-replay counter must equal the clean classes it served',
  );
  assert.equal(totals.skipped, 0, 'the retained skip class must stay 0 — nothing increments it');
  assert.ok(
    totals.cleanPattern >= 1,
    'the walk must have replayed at least one pattern-carrying case through the runtime',
  );
});
