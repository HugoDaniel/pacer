// The reserved-kind bundle proof — the production path end to end, no
// mocks: a real `pacer pack` of an authored NAMED score (the fresh
// build-cache CLI, never the possibly-stale installed zig-out copy)
// rides pngine's RESERVED `PACB` payload kind through a real
// `pngine pack --add PACB=…` (deflate and `,raw` variants), is
// extracted with pngine's PUBLIC `payloadsOf` seam (`pngine/viewer`,
// the public surface that exports it — the node root stub does not),
// and the extracted cartridge arms a source-free `PacerRt`.
//
// The score text below is the ONE independent oracle: every
// expectation is a literal derived from it (name 'drop', window
// times, the f32 landing values), never from a result of the same
// pipeline. The bundle carries ONLY the cartridge — no co-carried
// 'PACR' text — and the corruption leg truncates REAL bundled bytes
// into the real public walker (never a fake decoder).
//
// Portability: `PACER_PNGINE` overrides the sibling resolver (default
// four levels up from this file). A valid path passes quietly; a bad
// override FAILS the run loudly (someone pointed us somewhere on
// purpose); a missing default SKIPs loudly — both print the resolved
// absolute path. Host constraints skip per-test (zig, or the OpenBSD
// pngine binary on Linux); a skip is never a completion state.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deflateSync, inflateRawSync, inflateSync } from 'node:zlib';
import { PacerRt } from '../src/rt.js';

const PACER_ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const PPC = 720720n;
const BEAT = PPC / 4n; // 4/4 meter, tick grid

// The authored score — the test's full independent oracle string.
const SCORE = [
  '; bundle-wave — the smallest honest NAMED score for the reserved-kind',
  '; bundle proof: one declared target, one scene, one keyed track.',
  '(target :name glow :arity 1 :registry 0)',
  '',
  '(transport :bpm 120 :meter [4 4] :dur 4bar :end loop)',
  '',
  '(scene :name drop :at 0b :dur 8b',
  '  (track :target glow',
  '    (key :at 0b :value 0.5)',
  '    (key :at 4b :value 0.9 :ease out-cubic)))',
  '',
].join('\n');

// The oracle literals, derived from SCORE by hand (not from any run):
const ORACLE = {
  sceneName: 'drop',
  sceneStartTick: 0n,
  sceneDurTicks: 8n * BEAT,
  transportDur: 16n * BEAT, // :dur 4bar
  bpm: 120,
  firstWrite: 0.5, // key :at 0b
  secondWrite: Math.fround(0.9), // key :at 4b, structural landing
  entriesPerFrame: 1, // one track, one lane
};

/** Lazy: the config-probe leg must run without any wasm present. */
let rtModuleMemo;
function rtModule() {
  rtModuleMemo ??= new WebAssembly.Module(
    readFileSync(fileURLToPath(new URL('../../../zig-out/bin/pacer-rt.wasm', import.meta.url))),
  );
  return rtModuleMemo;
}

/**
 * Resolve the pngine checkout: `PACER_PNGINE` override, else the
 * sibling four levels up. Quiet when valid; the verdict carries the
 * resolved ABSOLUTE path either way (B4). `defaultRoot` is injectable
 * for the negative config probe.
 */
function resolvePngine(env = process.env, defaultRoot = defaultPngineRoot()) {
  const override = env.PACER_PNGINE;
  const root = override !== undefined && override !== '' ? path.resolve(override) : defaultRoot;
  const marker = path.join(root, 'npm', 'pngine', 'dist', 'viewer.mjs');
  return { root, marker, usable: existsSync(marker), source: override ? 'env' : 'default' };
}

function defaultPngineRoot() {
  return fileURLToPath(new URL('../../../../pngine', import.meta.url));
}

/**
 * House guard over a resolvePngine verdict: valid passes quietly; a bad
 * override FAILS loudly (assert.fail throws); a missing default returns
 * a skip verdict the caller turns into t.skip from the test body
 * (node:test's t.skip marks the test but does not stop execution). Both
 * loud paths name the resolved absolute path.
 */
function requirePngine(resolved) {
  if (resolved.usable) {
    return { skipped: false, root: resolved.root, viewerUrl: pathToFileURL(resolved.marker) };
  }
  const detail = `resolved pngine root ${resolved.root} (marker ${resolved.marker} missing)`;
  if (resolved.source === 'env') {
    assert.fail(`PACER_PNGINE override is not a usable pngine checkout: ${detail}`);
  }
  return {
    skipped: true,
    message: `pngine checkout not found — ${detail}; set PACER_PNGINE or run on the wave host`,
  };
}

/**
 * PNG chunk framing: [len u32be][type][data][crc u32be]. CRC is PNG's
 * standard polynomial, hand-rolled so no zlib.crc32 version floor.
 */
function pngChunk(type, data) {
  const head = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  let crc = 0xffffffff;
  for (const byte of head) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE((crc ^ 0xffffffff) >>> 0, 0);
  return Buffer.concat([len, head, crcBuf]);
}

/** A fixed deterministic 1×1 transparent RGBA PNG (the pack carrier). */
function oneByOnePng() {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(1, 0); // width
  ihdr.writeUInt32BE(1, 4); // height
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  const raw = Buffer.from([0, 0, 0, 0, 0]); // filter byte + one RGBA pixel
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

// One shared producer run per file execution; each leg still holds its
// own guards, so hosts without zig/pngine skip per test, never crash
// the file at import time.
const setups = new Map();
async function bundleSetup(resolved) {
  const memoKey = resolved.root;
  const existing = setups.get(memoKey);
  if (existing) return existing;
  const setup = (async () => {
    // The public extraction seam: `pngine/viewer` is the public bundle
    // that exports payloadsOf (the node root stub does not — R6).
    const viewer = await import(resolved.viewerUrl.href);
    if (typeof viewer.payloadsOf !== 'function') {
      return { stage: 'fail', reason: `${resolved.viewerUrl.href} exports no payloadsOf` };
    }
    // O6 probe: the installed pngine binary may be an OpenBSD artifact
    // this host cannot exec — skip loudly naming host + resolved path.
    const pngineBin = path.join(resolved.root, 'zig-out', 'bin', 'pngine');
    if (!existsSync(pngineBin)) {
      return {
        stage: 'pngine-cli',
        reason: `no pngine CLI at ${pngineBin} (build it: zig build install)`,
      };
    }
    const cliProbe = spawnSync(pngineBin, ['version'], { encoding: 'utf8' });
    if (cliProbe.error) {
      return {
        stage: 'pngine-cli',
        reason: `pngine CLI at ${pngineBin} cannot exec on this host (${cliProbe.error.code}) — the bundle legs run on the wave host`,
      };
    }
    // The producer side needs the zig toolchain (rt.test.js's guard).
    const zigProbe = spawnSync('zig', ['version'], { encoding: 'utf8' });
    if (zigProbe.error) {
      return {
        stage: 'zig',
        reason: `zig toolchain unavailable on this host (${zigProbe.error.code ?? zigProbe.error.message}); the fresh-pack legs run on the wave host`,
      };
    }

    const dir = await mkdtemp(path.join(tmpdir(), 'pacer-bundle-'));
    const scorePath = path.join(dir, 'bundle-wave.score.sjon');
    const pacbPath = path.join(dir, 'bundle-wave.pacb');
    const basePngPath = path.join(dir, 'base-1x1.png');
    const bundledPath = path.join(dir, 'bundled.png');
    const bundledRawPath = path.join(dir, 'bundled-raw.png');
    try {
      await writeFile(scorePath, SCORE);
      await writeFile(basePngPath, oneByOnePng());
      // Real producer: the exact pretest/`build:rt-fixture` invocation —
      // the fresh build-cache CLI, never the stale installed copy.
      const packed = spawnSync(
        'zig',
        ['build', 'run', '--', 'pack', scorePath, '--out', pacbPath],
        {
          encoding: 'utf8',
          cwd: PACER_ROOT,
        },
      );
      assert.equal(packed.error, undefined, `pacer pack failed to run: ${packed.error}`);
      assert.equal(packed.status, 0, `pacer pack refused the score: ${packed.stderr}`);

      const add = (suffix = '') => [`--add`, `PACB=${pacbPath}${suffix}`];
      const deflated = spawnSync(pngineBin, ['pack', basePngPath, ...add(), '-o', bundledPath], {
        encoding: 'utf8',
      });
      assert.equal(deflated.status, 0, `pngine pack (deflate) failed: ${deflated.stderr}`);
      const raw = spawnSync(
        pngineBin,
        ['pack', basePngPath, ...add(',raw'), '-o', bundledRawPath],
        { encoding: 'utf8' },
      );
      assert.equal(raw.status, 0, `pngine pack (raw) failed: ${raw.stderr}`);

      return {
        stage: 'done',
        payloadsOf: viewer.payloadsOf,
        cartridge: readFileSync(pacbPath),
        bundled: readFileSync(bundledPath),
        bundledRaw: readFileSync(bundledRawPath),
      };
    } catch (error) {
      return { stage: 'fail', reason: error?.message ?? String(error) };
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  })();
  setups.set(memoKey, setup);
  return setup;
}

/** Verdict for the bundle legs: resolution + the shared producer run. */
async function bundleEnvVerdict() {
  const resolved = requirePngine(resolvePngine());
  if (resolved.skipped) return { skipped: true, message: resolved.message };
  const setup = await bundleSetup(resolved);
  if (setup.stage === 'zig' || setup.stage === 'pngine-cli') {
    return { skipped: true, message: setup.reason };
  }
  assert.equal(setup.stage, 'done', setup.reason);
  return { skipped: false, setup };
}

/** The independent oracle, asserted against a source-free driver. */
function assertRuntimeOracle(driver) {
  assert.equal(driver.ok, true, 'the extracted cartridge must arm the runtime');
  const meta = driver.meta;
  assert.equal(meta.transport.bpm, ORACLE.bpm);
  assert.equal(meta.transport.dur, ORACLE.transportDur);
  assert.equal(meta.scenes.length, 1);
  assert.equal(meta.scenes[0].name, ORACLE.sceneName); // the literal exact-name pin
  assert.equal(meta.scenes[0].startTick, ORACLE.sceneStartTick);
  assert.equal(meta.scenes[0].durTicks, ORACLE.sceneDurTicks);
  // PACW: 12-byte header + 20 bytes per write (docs/binary-score.md).
  assert.equal(driver.evalBytes(0)?.length, 12 + 20 * ORACLE.entriesPerFrame);
  // Live writes at the window times — f32 structural landings, literals.
  const atZero = driver.eval(0);
  assert.equal(atZero.length, ORACLE.entriesPerFrame);
  assert.deepEqual([atZero[0].targetId, atZero[0].registry, atZero[0].ncomp], [0, 0, 1]);
  assert.deepEqual(atZero[0].value, Float32Array.of(ORACLE.firstWrite, 0, 0, 0));
  const atTwo = driver.eval(2); // 2 s at 120 bpm 4/4 = 4 beats = the second key
  assert.deepEqual(atTwo[0].value, Float32Array.of(ORACLE.secondWrite, 0, 0, 0));
}

test('config: bad PACER_PNGINE fails loudly, missing default skips loudly — never a file crash', () => {
  // Broken override: an unusable verdict whose guard FAILS (throws)
  // with the resolved absolute path in the message — never a silent
  // skip when someone pointed us somewhere on purpose.
  const bogus = resolvePngine({ PACER_PNGINE: path.join(PACER_ROOT, 'does', 'not', 'exist') });
  assert.equal(bogus.usable, false);
  assert.equal(bogus.source, 'env');
  assert.ok(path.isAbsolute(bogus.root), `resolved absolute: ${bogus.root}`);
  assert.throws(() => requirePngine(bogus), /PACER_PNGINE.*does.not.exist/s);
  // Missing default: the same verdict shape, but the guard returns a
  // SKIP verdict carrying the resolved path — a per-test loud skip the
  // leg turns into t.skip, never a whole-file crash.
  const missingDefault = resolvePngine({}, '/nonexistent/sibling/pngine');
  assert.equal(missingDefault.usable, false);
  assert.equal(missingDefault.source, 'default');
  const skipVerdict = requirePngine(missingDefault);
  assert.equal(skipVerdict.skipped, true);
  assert.match(skipVerdict.message, /pngine checkout not found/);
  assert.match(skipVerdict.message, /\/nonexistent\/sibling\/pngine/);
  // The real default (when present) is usable and passes quietly.
  const real = resolvePngine({});
  if (real.usable) {
    const guard = requirePngine(real);
    assert.equal(guard.skipped, false);
    assert.equal(guard.root, real.root);
  }
});

test('bundle: pacer pack → pngine --add PACB → public payloadsOf → inflate → byte-identical → PacerRt', async (t) => {
  const env = await bundleEnvVerdict();
  if (env.skipped) return t.skip(env.message);
  const s = env.setup;
  const payloads = [...s.payloadsOf(s.bundled)];
  // ONLY the cartridge rides: one payload, kind PACB, no co-carried
  // PACR text, no skips.
  assert.equal(payloads.length, 1, JSON.stringify(payloads));
  const pacb = payloads[0];
  assert.equal(pacb.kind, 'PACB');
  assert.equal(pacb.version, 1);
  assert.equal(pacb.carrier, 'pNGx#1');
  // Stored bytes are raw DEFLATE (flag bit 0): plain inflate must
  // refuse, inflateRaw must reproduce the cartridge byte for byte.
  assert.equal(pacb.flags & 1, 1);
  assert.throws(() => inflateSync(pacb.body));
  const cartridge = inflateRawSync(pacb.body);
  assert.deepEqual(Buffer.from(cartridge), s.cartridge);
  assertRuntimeOracle(await PacerRt.load(rtModule(), cartridge));
});

test('bundle: the ,raw variant stores the cartridge verbatim (flags 0, no inflate)', async (t) => {
  const env = await bundleEnvVerdict();
  if (env.skipped) return t.skip(env.message);
  const s = env.setup;
  const payloads = [...s.payloadsOf(s.bundledRaw)];
  assert.equal(payloads.length, 1, JSON.stringify(payloads));
  const pacb = payloads[0];
  assert.equal(pacb.kind, 'PACB');
  assert.equal(pacb.flags & 1, 0);
  assert.deepEqual(Buffer.from(pacb.body), s.cartridge);
  assertRuntimeOracle(await PacerRt.load(rtModule(), pacb.body));
});

test('bundle: a truncated bundle dies loudly in the public walker — no fake decode', async (t) => {
  const env = await bundleEnvVerdict();
  if (env.skipped) return t.skip(env.message);
  const s = env.setup;
  // Real corruption: cut 60 bytes off the REAL bundled PNG — through
  // IEND and into the pNGx chunk body, so the chunk's declared length
  // reads past the buffer. pngine's own pinned contract: the public
  // walker throws on the first .next(), nothing yielded.
  const truncated = s.bundled.subarray(0, s.bundled.length - 60);
  assert.ok(truncated.length > 0);
  const gen = s.payloadsOf(truncated);
  assert.throws(() => gen.next());
});
