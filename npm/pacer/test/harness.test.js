// Focused parser/render tests for the shared corpus harness leaf.
//
// The corpus parity walk exercises the same parser/renderer against the
// real wasm artifact; these tests isolate the closed lifecycle grammar
// and the canonical lifecycle echoes so a drift names the leaf itself.
// No public JS API is added: `renderCase` keeps its three-argument form
// and accepts an OPTIONAL test-only raw-load context for the bad-call
// step (the step must call the real export with an over-cap length).

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseHarness, renderCase } from './harness.js';

const MINIMAL_META = {
  transport: { bpm: 120, beatsPerBar: 4, dur: null, end: null },
  tracks: [],
  controls: [],
  scenes: [],
  easePrograms: [],
  tempoMap: [],
};

/** A stub with exactly the surface `renderCase` reads. */
function fakeDriver({ ok = true, reload = null } = {}) {
  const driver = {
    ok,
    diagnostics: [],
    meta: MINIMAL_META,
    reloadCalls: [],
    evalBytes() {
      return null;
    },
    setControl() {
      return true;
    },
    clearControl() {
      return true;
    },
    setBpm() {
      return true;
    },
    registerControl() {
      return null;
    },
    reload(doc) {
      driver.reloadCalls.push(doc);
      if (reload) reload(driver, doc);
      return { ok: driver.ok, diagnostics: driver.diagnostics };
    },
  };
  return driver;
}

test('harness: lifecycle forms parse into explicit step variants', () => {
  const h = parseHarness(
    [
      '(target alpha :registry 0 :ncomp 1)',
      '(target bravo :registry 0 :ncomp 1)',
      '(times "0000000000000000")',
      '(reload :kind bad-call)',
      '(reload :kind diagnostics)',
      '(reload :kind bad-version)',
      '(reload :kind current)',
      '(registry-mismatch :mode structural)',
      '(registry-mismatch :mode name-swap)',
    ].join('\n'),
  );
  assert.deepEqual(
    h.steps.map((s) => [s.kind, s.reloadKind ?? s.mode]),
    [
      ['eval', undefined],
      ['reload', 'bad-call'],
      ['reload', 'diagnostics'],
      ['reload', 'bad-version'],
      ['reload', 'current'],
      ['registry-mismatch', 'structural'],
      ['registry-mismatch', 'name-swap'],
    ],
  );
});

test('harness: lifecycle kind/mode are closed; missing and extra keys throw', () => {
  for (const src of [
    '(reload :kind nope)',
    '(reload)',
    '(reload :kind current :extra 1)',
    '(registry-mismatch :mode nope)',
    '(registry-mismatch)',
    '(registry-mismatch :mode structural :extra 1)',
  ]) {
    assert.throws(() => parseHarness(`(times "0000000000000000")\n${src}`), undefined, src);
  }
});

test('harness: text lifecycle echoes follow the per-path table', async () => {
  let rawCalls = 0;
  const driver = fakeDriver({
    reload(d, doc) {
      // The diagnostic source is the fixed harness-only text; the
      // original document restores the text session.
      d.ok = doc !== '(transport :bpm 0)\n';
      d.meta = d.ok ? MINIMAL_META : null;
    },
  });
  const harness = parseHarness(
    [
      '(reload :kind bad-call)',
      '(reload :kind diagnostics)',
      '(times "3FE0000000000000")',
      '(reload :kind bad-version)',
      '(reload :kind current)',
      '(registry-mismatch :mode structural)',
      '(registry-mismatch :mode name-swap)',
      '(times "3FE0000000000000")',
    ].join('\n'),
  );
  const out = await renderCase('doc', harness, driver, {
    rawLoad() {
      rawCalls += 1;
      return 2;
    },
  });
  assert.equal(rawCalls, 1);
  assert.match(out, /\(reload :kind bad-call :status 2 :loaded true\)/);
  assert.match(out, /\(reload :kind diagnostics :status 1 :loaded false\)/);
  assert.match(out, /\(eval :t "3FE0000000000000" :unloaded true\)/);
  assert.match(out, /\(reload :kind bad-version :skipped binary-only\)/);
  assert.match(out, /\(reload :kind current :status 0 :loaded true\)/);
  assert.match(out, /\(registry-mismatch :mode structural :skipped binary-only\)/);
  assert.match(out, /\(registry-mismatch :mode name-swap :skipped binary-only\)/);
  assert.match(out, /\(eval :t "3FE0000000000000" :out-of-range true\)/);
});

test('harness: a bad-call step requires the test-only raw context', async () => {
  const driver = fakeDriver();
  const harness = parseHarness('(reload :kind bad-call)');
  await assert.rejects(() => renderCase('doc', harness, driver), /raw-load/);
});
