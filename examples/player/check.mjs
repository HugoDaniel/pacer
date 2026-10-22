#!/usr/bin/env node
// examples/player/check.mjs — the C7 fixture/join/meta/binary-load proof
// that does NOT need a browser. It loads the SAME score.pacb and
// pacer-rt.wasm the page fetches, through the same PacerRt class and the
// same unchanged route.js, and asserts the registry join, meta audit
// inputs, eval(0), a live control, and the reload/reset/re-apply contract.
//
// Run from the repo root: `node examples/player/check.mjs`.
import { readFileSync } from 'node:fs';
import { PacerRt } from '../../npm/pacer/src/rt.js';
import { routeWrites, toUniforms } from '../../npm/pacer/src/route.js';

const JOIN = [[
  { name: 'beat', ncomp: 1 },
  { name: 'heroPos', ncomp: 2 },
  { name: 'heroTurn', ncomp: 1 },
  { name: 'heroTint', ncomp: 1 },
]];

const pacb = readFileSync(new URL('./score.pacb', import.meta.url));
const wasm = readFileSync(new URL('../../npm/pacer/pacer-rt.wasm', import.meta.url));

const fail = (msg) => {
  console.error(`C7-FAIL ${msg}`);
  process.exit(1);
};
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

const driver = await PacerRt.load(wasm, pacb, { registries: JOIN });
if (!driver.ok) fail(`load status ${driver.status} reason ${driver.reason}`);

const meta = driver.meta;
const tracks = (meta?.tracks ?? []).map((t) => t.name);
for (const name of ['beat', 'heroPos', 'heroTurn', 'heroTint']) {
  if (!tracks.includes(name)) fail(`meta track ${name} missing; got ${tracks.join(',')}`);
}
const control = (meta?.controls ?? []).find((c) => c.id === 'hero-speed');
if (!control) fail(`meta control hero-speed missing; got ${JSON.stringify(meta?.controls)}`);

const eval0 = driver.eval(0);
const groups = routeWrites(eval0 ?? [], JOIN.length);
const uniforms = toUniforms(groups[0] ?? [], 0);
if (!near(uniforms.beat, 0)) fail(`eval(0) beat ${uniforms.beat} != 0`);
if (!near(uniforms.heroPos[0], 0.1) || !near(uniforms.heroPos[1], 0.6)) {
  fail(`eval(0) heroPos ${uniforms.heroPos} != [0.1,0.6]`);
}
if (!near(uniforms.heroTurn, 0)) fail(`eval(0) heroTurn ${uniforms.heroTurn} != 0`);
if (!near(uniforms.heroTint, 0.5)) fail(`eval(0) heroTint ${uniforms.heroTint} != 0.5`);

if (!driver.setControl('hero-speed', 2)) fail('setControl(hero-speed,2) rejected');
if (!near(toUniforms(routeWrites(driver.eval(0) ?? [], 1)[0] ?? [], 0).heroTint, 1)) {
  fail('live control did not reach the heroTint expression');
}

// A successful reload resets held state; re-applying restores it. This is
// the page's Restart contract, without a browser.
const reload = driver.load(pacb);
if (!reload.ok) fail(`reload status ${driver.status} reason ${driver.reason}`);
if (!near(toUniforms(routeWrites(driver.eval(0) ?? [], 1)[0] ?? [], 0).heroTint, 0.5)) {
  fail('reload did not reset the held control');
}
if (!driver.setControl('hero-speed', 2)) fail('re-apply after reload rejected');
if (!near(toUniforms(routeWrites(driver.eval(0) ?? [], 1)[0] ?? [], 0).heroTint, 1)) {
  fail('re-applied control did not take effect after reload');
}

// Scene seek: 4 bars at 82 bpm = 11.707317 s, the "two" window opens.
const seek = toUniforms(routeWrites(driver.eval(11.707317) ?? [], 1)[0] ?? [], 0);
if (!near(seek.heroTurn, 0.7, 1e-4)) fail(`scene-seek heroTurn ${seek.heroTurn} != 0.7`);

console.log(
  `C7 PASS: load=0 tracks=${tracks.join(',')} controls=${meta.controls.map((c) => c.id).join(',')} ` +
    `eval(0)=${eval0.length} entries heroTint=${uniforms.heroTint} scene-seek=${seek.heroTurn.toFixed(4)}`,
);
