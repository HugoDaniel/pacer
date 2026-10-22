// pacer examples — minimal PacerRt vertical smoke (plan 06 C7 / 04 P3).
//
// Mirrors the Meridian player's shape: fetch the packed score and the
// playback-only wasm, `PacerRt.load`, drive `eval(t)` from a host clock,
// and route the frame through the unchanged `route.js`. No compiler and no
// text path are reachable from this page. The parent's browser-tester runs
// the real browser pass; this file is the fixture/join/meta/binary-load
// surface that pass exercises.

import { PacerRt } from '../../npm/pacer/src/rt.js';
import { perfClock } from '../../npm/pacer/src/clock.js';
import { routeWrites, toUniforms } from '../../npm/pacer/src/route.js';

const PACB = './score.pacb';
const WASM = '../../npm/pacer/pacer-rt.wasm';

// The pack-time host join, in the same flat order. This is the registry
// join the score was packed against; a mismatch is refused with reason 9.
const JOIN = [[
  { name: 'beat', ncomp: 1 },
  { name: 'heroPos', ncomp: 2 },
  { name: 'heroTurn', ncomp: 1 },
  { name: 'heroTint', ncomp: 1 },
]];

const $ = (id) => document.getElementById(id);
const statusEl = $('status');
const canvas = $('stage');
const ctx = canvas.getContext('2d');

let pacb;
let wasmSource;
let driver;
let startedAt = 0;
let raf = 0;
let heldSpeed = 1;

function say(text, ok = true) {
  statusEl.textContent = text;
  statusEl.dataset.ok = String(ok);
}

function draw(uniforms) {
  const w = canvas.width;
  const h = canvas.height;
  ctx.clearRect(0, 0, w, h);
  ctx.fillStyle = '#1b1b1f';
  ctx.fillRect(0, 0, w, h);

  const pos = uniforms.heroPos ?? [0.5, 0.5];
  const turn = uniforms.heroTurn ?? 0;
  const tint = uniforms.heroTint ?? 0.5;
  const x = pos[0] * w;
  const y = (1 - pos[1]) * h;
  const r = 14 + 10 * Math.sin(turn * Math.PI);

  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(turn * Math.PI);
  ctx.fillStyle = `rgb(${Math.round(80 + 175 * tint)}, ${Math.round(120 + 80 * tint)}, 200)`;
  ctx.beginPath();
  ctx.ellipse(0, 0, r, r * 0.62, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  ctx.fillStyle = '#e8e8e8';
  ctx.font = '12px ui-monospace, monospace';
  ctx.fillText(`beat ${Number(uniforms.beat ?? 0).toFixed(2)}`, 12, 20);
}

function showFrame(entries) {
  const groups = routeWrites(entries ?? [], JOIN.length);
  const uniforms = toUniforms(groups[0] ?? [], 0);
  draw(uniforms);
  $('frame').textContent = JSON.stringify(uniforms, null, 2);
  return uniforms;
}

function showMeta() {
  const meta = driver?.meta;
  const tracks = (meta?.tracks ?? []).map((t) => `${t.name ?? '(declared)'} [${t.source}]`);
  const controls = (meta?.controls ?? []).map((c) => `${c.index}:${c.id}`);
  $('meta').textContent = `tracks:\n  ${tracks.join('\n  ')}\ncontrols:\n  ${controls.join('\n  ') || '(none)'}`;
}

function applyHeld() {
  if (!driver?.ok) return;
  driver.setControl('hero-speed', heldSpeed);
}

async function boot() {
  cancelAnimationFrame(raf);
  pacb ??= new Uint8Array(await (await fetch(PACB)).arrayBuffer());
  wasmSource ??= await (await fetch(WASM)).arrayBuffer();

  driver = await PacerRt.load(wasmSource, pacb, { registries: JOIN });
  if (!driver.ok) {
    say(`load refused: status ${driver.status} reason ${driver.reason}`, false);
    return;
  }
  applyHeld();

  // First frame is eval(0), before the clock starts: the READY state.
  const first = driver.eval(0);
  $('first-frame').textContent = JSON.stringify(first ?? [], null, 2);
  showFrame(first);
  showMeta();

  const clock = perfClock();
  startedAt = clock();
  say('playing — eval(t) from the host clock');
  const tick = () => {
    const t = clock() - startedAt;
    showFrame(driver.eval(t));
    raf = requestAnimationFrame(tick);
  };
  raf = requestAnimationFrame(tick);
}

async function restart() {
  if (!driver) return boot();
  cancelAnimationFrame(raf);
  const result = driver.load(pacb);
  if (!result.ok) {
    say(`reload refused: status ${driver.status} reason ${driver.reason}`, false);
    return;
  }
  // A successful load tears down controls; re-apply the held widget.
  applyHeld();
  showMeta();
  const first = driver.eval(0);
  $('first-frame').textContent = JSON.stringify(first ?? [], null, 2);
  showFrame(first);
  const clock = perfClock();
  startedAt = clock();
  say('restarted — state torn down, held control re-applied');
  const tick = () => {
    const t = clock() - startedAt;
    showFrame(driver.eval(t));
    raf = requestAnimationFrame(tick);
  };
  raf = requestAnimationFrame(tick);
}

$('restart').addEventListener('click', () => {
  restart().catch((err) => say(`restart failed: ${err.message}`, false));
});

$('speed').addEventListener('input', (event) => {
  heldSpeed = Number(event.target.value);
  applyHeld();
  if (driver?.ok) showFrame(driver.eval(0));
});

boot().catch((err) => say(`load failed: ${err.message}`, false));
