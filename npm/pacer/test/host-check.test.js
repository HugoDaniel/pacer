// The AudioTargetHost conformance kit (plan it/02): an executable
// statement of what a correct host IS, so the next engine (batida, the
// audzio graph) is written against the contract, not against the
// studio's incidental shape. Pure — usable inside any consumer's suite.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { clockOnlyHost, sointuHost } from '../src/audio.js';
import { checkAudioTargetHost } from '../src/host-check.js';

/** A minimal conformant host: params, total setParam, null clock. */
function conformantHost() {
  return {
    params: () => [
      { name: 'gain', min: 0, max: 1, default: 0.8 },
      { name: 'pan', ncomp: 2 },
    ],
    setParam: () => {},
    clock: () => null,
  };
}

const codesOf = (findings) => findings.map((f) => f.code);

test('a minimal conformant fake yields no findings', () => {
  assert.deepEqual(checkAudioTargetHost(conformantHost()), []);
});

test('every finding is a {code, message} record', () => {
  const findings = checkAudioTargetHost({});
  assert.ok(findings.length > 0);
  for (const f of findings) {
    assert.equal(typeof f.code, 'string');
    assert.equal(typeof f.message, 'string');
    assert.ok(f.message.length > 0);
  }
});

test('bad ncomp: non-integer or outside 1..4', () => {
  for (const ncomp of [0, 5, 1.5, Number.NaN]) {
    const host = { ...conformantHost(), params: () => [{ name: 'x', ncomp }] };
    assert.ok(codesOf(checkAudioTargetHost(host)).includes('param-ncomp'), `ncomp ${ncomp}`);
  }
});

test('duplicate param names are a finding', () => {
  const host = { ...conformantHost(), params: () => [{ name: 'gain' }, { name: 'gain' }] };
  assert.ok(codesOf(checkAudioTargetHost(host)).includes('param-duplicate'));
});

test('an empty or non-string param name is a finding', () => {
  for (const name of ['', 7, undefined]) {
    const host = { ...conformantHost(), params: () => [{ name }] };
    assert.ok(codesOf(checkAudioTargetHost(host)).includes('param-name'), `name ${String(name)}`);
  }
});

test('non-finite or disordered bounds are a finding', () => {
  const cases = [
    [{ name: 'x', default: Number.NaN }],
    [{ name: 'x', min: Number.NEGATIVE_INFINITY }],
    [{ name: 'x', min: 0, max: 1, default: 2 }], // default above max
    [{ name: 'x', min: 1, max: 0 }], // min above max
  ];
  for (const params of cases) {
    const host = { ...conformantHost(), params: () => params };
    assert.ok(codesOf(checkAudioTargetHost(host)).includes('param-bounds'), JSON.stringify(params));
  }
});

test('totality: setParam must not throw on unknown names or non-finite values', () => {
  const throwing = {
    ...conformantHost(),
    setParam: (name, value) => {
      if (name === 'gain' && !Number.isFinite(value)) throw new Error('bad value');
      if (name !== 'gain' && name !== 'pan') throw new Error(`unknown ${name}`);
    },
  };
  const codes = codesOf(checkAudioTargetHost(throwing));
  assert.ok(codes.includes('set-param-throws'));
  // The kit itself survived the throw — findings, not exceptions.
});

test('clock shape: neither null nor {seconds: finite, playing: boolean} is a finding', () => {
  const cases = [
    () => ({}),
    () => ({ seconds: Number.NaN, playing: true }),
    () => ({ seconds: 1 }),
    () => ({ seconds: 1, playing: 'yes' }),
    () => 42,
  ];
  for (const clock of cases) {
    const host = { ...conformantHost(), clock };
    assert.ok(codesOf(checkAudioTargetHost(host)).includes('clock-shape'), String(clock()));
  }
});

test('expectClock: a null clock becomes a finding only when demanded', () => {
  const host = conformantHost(); // clock() → null
  assert.deepEqual(checkAudioTargetHost(host), []);
  assert.ok(codesOf(checkAudioTargetHost(host, { expectClock: true })).includes('clock-missing'));
});

test('idempotence: two params() calls must agree', () => {
  let flip = false;
  const host = {
    ...conformantHost(),
    params: () => {
      flip = !flip;
      return flip ? [{ name: 'gain' }] : [{ name: 'gain' }, { name: 'extra' }];
    },
  };
  assert.ok(codesOf(checkAudioTargetHost(host)).includes('params-unstable'));
});

test('the kit never throws on a hostile host', () => {
  const hostile = [
    {},
    { params: null, setParam: null, clock: null },
    {
      params: () => {
        throw new Error('no');
      },
      setParam: () => {
        throw new Error('no');
      },
      clock: () => {
        throw new Error('no');
      },
    },
    { params: () => 'nope', setParam: () => {}, clock: () => null },
  ];
  for (const host of hostile) {
    const findings = checkAudioTargetHost(host);
    assert.ok(Array.isArray(findings));
    assert.ok(findings.length > 0, JSON.stringify(host));
  }
});

test('clockOnlyHost is the canonical name; sointuHost stays a same-function alias', () => {
  assert.equal(clockOnlyHost, sointuHost);
});

test('clockOnlyHost(fakePlayer) passes the kit with expectClock', () => {
  const player = { currentTime: 1.25, playing: true };
  const host = clockOnlyHost(player);
  assert.deepEqual(checkAudioTargetHost(host, { expectClock: true }), []);
  assert.deepEqual(host.clock(), { seconds: 1.25, playing: true });
});
