// Node spec for the G5 fixture builder (browser/prepare.mjs).
//
// Like server-spec.mjs this file is named `*-spec.mjs` so NEITHER
// `npm test` (node --test autodiscovery) NOR playwright's default
// testMatch ever picks it up. Run it explicitly:
//
//   node --test browser/g5/prepare-spec.mjs
//
// The builder authors the hostile-name score offline, packs it and the
// G4 `drop` score through the REAL fresh CLIs (`zig build run -- pack`
// — never the stale installed copy — and the pngine CLI), wraps them
// with `pngine pack --add PACB=…`, truncates a real bundle into the
// malformed fixture, copies the public viewer bundle + the PacerRt
// closure + the freshly built pacer-rt.wasm into an ISOLATED webroot,
// and pins every served byte in a manifest. Host constraints skip
// loudly with resolved paths (mirroring test/bundle.test.js); a skip
// is never a completion state — the wave host runs this for real.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { inflateRawSync, inflateSync } from 'node:zlib';
import { PacerRt } from '../../src/rt.js';
import { ROUTES } from '../server.mjs';
import expected from './expected.json' with { type: 'json' };

const NPM_PACER = fileURLToPath(new URL('../../', import.meta.url));
const REPO_ROOT = fileURLToPath(new URL('../../../../', import.meta.url));
// Five levels up from browser/g5/: g5 → browser → npm/pacer → npm →
// repo root → the animader-init parent that holds the sibling checkout
// (B4: print the resolved absolute path in every skip/failure).
const DEFAULT_PNGINE = fileURLToPath(new URL('../../../../../pngine', import.meta.url));

// Independent provenance pins from the G4 report of record §4 — these
// are hand-recorded values from the reviewed wave, NOT outputs of this
// spec's own run. A mismatch is a loud regeneration drift, never a
// silent acceptance.
const G4_PINS = {
  bundle: {
    sha256: '5b158d22ff0303b49979f5fd68e80ca2c180ecbbaad16ccba7e5499f3cab2b33',
    bytes: 357,
  },
  bundleRaw: {
    sha256: '9dfd06140a72f33d01b3c797585712030d057d070a5d6cb6013e3ca09462e8b2',
    bytes: 3680,
  },
  cartridge: {
    sha256: 'ab743d3676872035204a577aa7baa8588ea7e43fd11d9fb5e6d04096c4980972',
    bytes: 3592,
  },
};

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

/** Resolve + probe the toolchain; null legs mean loud-skip. */
function toolchain() {
  const override = process.env.PACER_PNGINE;
  const pngineRoot = override ? path.resolve(override) : DEFAULT_PNGINE;
  const cli = path.join(pngineRoot, 'zig-out', 'bin', 'pngine');
  const viewer = path.join(pngineRoot, 'npm', 'pngine', 'dist', 'viewer.mjs');
  const zig = spawnSync('zig', ['version'], { encoding: 'utf8' });
  const cliProbe = existsSync(cli) ? spawnSync(cli, ['version'], { encoding: 'utf8' }) : null;
  return {
    pngineRoot,
    cli,
    viewer,
    usable: Boolean(!zig.error && cliProbe && cliProbe.status === 0 && existsSync(viewer)),
    detail: `zig=${zig.error ? zig.error.code : zig.stdout.trim()} pngineCli=${cli} viewer=${viewer}`,
  };
}

const tools = toolchain();

function runPrepare(root) {
  return spawnSync(
    process.execPath,
    [path.join(NPM_PACER, 'browser', 'prepare.mjs'), '--root', root],
    {
      encoding: 'utf8',
      cwd: NPM_PACER,
      timeout: 10 * 60_000,
    },
  );
}

test('config: a bad PACER_PNGINE override fails loudly with the resolved path', () => {
  const bogus = spawnSync(
    process.execPath,
    [path.join(NPM_PACER, 'browser', 'prepare.mjs'), '--root', path.join(tmpdir(), 'pacer-g5-x')],
    {
      encoding: 'utf8',
      cwd: NPM_PACER,
      env: { ...process.env, PACER_PNGINE: path.join(REPO_ROOT, 'does', 'not', 'exist') },
      timeout: 60_000,
    },
  );
  assert.notEqual(bogus.status, 0, 'a pointed-to missing checkout must fail the run');
  assert.match(bogus.stderr + bogus.stdout, /does.not.exist/s);
});

test('config: --root with no value refuses with usage — never a path TypeError', () => {
  const probe = spawnSync(
    process.execPath,
    [path.join(NPM_PACER, 'browser', 'prepare.mjs'), '--root'],
    { encoding: 'utf8', cwd: NPM_PACER, timeout: 60_000 },
  );
  assert.notEqual(probe.status, 0, '--root with no value must fail');
  const output = probe.stderr + probe.stdout;
  assert.match(output, /--root requires a value/, 'the refusal names the flag');
  assert.match(output, /usage/i, 'the refusal prints the usage line');
  assert.equal(output.includes('TypeError'), false, 'no raw path TypeError escapes');
});

test('prepare: fresh CLIs build an isolated webroot whose manifest pins every served byte', async (t) => {
  if (!tools.usable) {
    return t.skip(
      `toolchain unavailable on this host (${tools.detail}); the builder legs run on the wave host`,
    );
  }
  const base = await mkdtemp(path.join(tmpdir(), 'pacer-g5-prepare-'));
  const root = path.join(base, 'g5-web');
  try {
    const run = runPrepare(root);
    assert.equal(run.status, 0, `prepare failed: ${run.stderr}\n${run.stdout}`);
    const manifest = JSON.parse(readFileSync(path.join(root, 'manifest.json'), 'utf8'));

    // Inventory equality: the manifest pins exactly the copied
    // artifact routes (the manifest excludes itself — circular pin);
    // the WALKED inventory must still be exactly the served files,
    // manifest.json included — nothing extra, nothing missing.
    const servedRoutes = Object.keys(ROUTES).filter(
      (r) => ROUTES[r].file && r !== '/manifest.json',
    );
    assert.deepEqual(
      Object.keys(manifest.files).sort(),
      servedRoutes.sort(),
      'manifest must pin exactly the copied artifact routes',
    );
    const walked = [];
    for (const entry of await readdir(root, { recursive: true, withFileTypes: true })) {
      if (entry.isFile()) walked.push(path.relative(root, path.join(entry.parentPath, entry.name)));
    }
    const expectedFiles = Object.values(ROUTES)
      .filter((r) => r.file)
      .map((r) => r.file)
      .sort();
    assert.deepEqual(
      walked.sort(),
      expectedFiles,
      'webroot holds exactly the fixture files — nothing else',
    );
    for (const name of walked) {
      assert.equal(name.endsWith('.sjon'), false, `no source text may be served: ${name}`);
      assert.equal(name.includes('compiler'), false, `no compiler artifact may be served: ${name}`);
      if (name.endsWith('.wasm')) {
        assert.equal(name, 'pacer-rt.wasm', `the only served wasm is pacer-rt.wasm: ${name}`);
      }
    }

    // Every pinned digest matches the actual bytes.
    for (const [route, pin] of Object.entries(manifest.files)) {
      const bytes = readFileSync(path.join(root, ROUTES[route].file));
      assert.equal(pin.bytes, bytes.length, `${route} byte length`);
      assert.equal(pin.sha256, sha256(bytes), `${route} digest`);
    }

    // G4 provenance: the regenerated `drop` artifacts are byte-identical
    // to the reviewed G4 wave (report §4 pins), and the frozen probe
    // copies under .agent/artifacts (when present) match too.
    const bundled = readFileSync(path.join(root, 'bundle', 'g4-bundle.png'));
    const bundledRaw = readFileSync(path.join(root, 'bundle', 'g4-bundle-raw.png'));
    assert.equal(sha256(bundled), G4_PINS.bundle.sha256);
    assert.equal(bundled.length, G4_PINS.bundle.bytes);
    assert.equal(sha256(bundledRaw), G4_PINS.bundleRaw.sha256);
    assert.equal(bundledRaw.length, G4_PINS.bundleRaw.bytes);
    assert.equal(manifest.variants.compressed.cartridgeSha256, G4_PINS.cartridge.sha256);
    assert.equal(manifest.variants.compressed.cartridgeBytes, G4_PINS.cartridge.bytes);
    for (const [frozenName, preparedName] of [
      ['g4-bundle.png', 'bundle/g4-bundle.png'],
      ['g4-bundle-raw.png', 'bundle/g4-bundle-raw.png'],
    ]) {
      const frozenPath = path.join(REPO_ROOT, '.agent', 'artifacts', frozenName);
      if (existsSync(frozenPath)) {
        assert.deepEqual(
          readFileSync(frozenPath),
          readFileSync(path.join(root, preparedName)),
          `${frozenName} must be byte-identical to the frozen G4 probe artifact`,
        );
      }
    }

    // Copied runtime closure is unmutated: served bytes === sources.
    for (const [served, source] of [
      ['rt.js', path.join(NPM_PACER, 'src', 'rt.js')],
      ['meta.js', path.join(NPM_PACER, 'src', 'meta.js')],
      ['pact.js', path.join(NPM_PACER, 'src', 'pact.js')],
      ['viewer.mjs', tools.viewer],
      ['pacer-rt.wasm', path.join(REPO_ROOT, 'zig-out', 'bin', 'pacer-rt.wasm')],
    ]) {
      assert.deepEqual(
        readFileSync(path.join(root, served)),
        readFileSync(source),
        `${served} copy drift`,
      );
    }

    // Malformed fixture: the REAL compressed bundle truncated 60 bytes
    // (through IEND into the pNGx body — the G4 corruption contract).
    assert.equal(manifest.malformed.truncatedBytes, 60);
    const malformed = readFileSync(path.join(root, 'bundle', 'g5-malformed.png'));
    assert.deepEqual([...malformed], [...bundled.subarray(0, bundled.length - 60)]);

    // Manifest authoring names match the hand oracle for all variants.
    for (const variant of Object.keys(expected.variants)) {
      assert.deepEqual(manifest.variants[variant].names, expected.variants[variant].names);
    }
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test('runtime oracle over the PREPARED webroot — names/ticks/writes from the hand literals', async (t) => {
  if (!tools.usable) {
    return t.skip(
      `toolchain unavailable on this host (${tools.detail}); the builder legs run on the wave host`,
    );
  }
  const base = await mkdtemp(path.join(tmpdir(), 'pacer-g5-oracle-'));
  const root = path.join(base, 'g5-web');
  try {
    const run = runPrepare(root);
    assert.equal(run.status, 0, `prepare failed: ${run.stderr}\n${run.stdout}`);
    const manifest = JSON.parse(readFileSync(path.join(root, 'manifest.json'), 'utf8'));
    // The extraction seam is the PUBLIC viewer bundle exactly as served.
    const viewer = await import(pathToFileURL(path.join(root, 'viewer.mjs')).href);
    const wasmBytes = readFileSync(path.join(root, 'pacer-rt.wasm'));
    const module = new WebAssembly.Module(wasmBytes);

    for (const [variant, want] of Object.entries(expected.variants)) {
      const bundle = readFileSync(path.join(root, manifest.variants[variant].bundle.slice(1)));
      assert.equal(
        sha256(bundle),
        manifest.variants[variant].bundleSha256,
        `${variant} bundle digest`,
      );
      const payloads = [...viewer.payloadsOf(bundle)];
      assert.equal(payloads.length, 1, `${variant}: only the cartridge rides`);
      assert.equal(payloads[0].kind, 'PACB');
      assert.equal(payloads[0].version, 1);
      const flags = payloads[0].flags;
      assert.equal(flags & 1, manifest.variants[variant].flags);
      if (flags & 1) {
        assert.throws(
          () => inflateSync(payloads[0].body),
          `${variant}: raw DEFLATE refuses zlib inflate`,
        );
      }
      const cartridge = flags & 1 ? inflateRawSync(payloads[0].body) : payloads[0].body;
      assert.equal(
        sha256(cartridge),
        manifest.variants[variant].cartridgeSha256,
        `${variant} cartridge digest`,
      );

      const driver = await PacerRt.load(module, cartridge);
      assert.equal(driver.ok, true);
      const meta = driver.meta;
      const scenes = meta.scenes.map((s) => s.name);
      assert.deepEqual(scenes, want.names, `${variant} names`);
      assert.equal(meta.transport.bpm, want.transport.bpm);
      assert.equal(meta.transport.dur, BigInt(want.transport.dur));
      assert.equal(meta.transport.end, want.transport.end);
      assert.equal(meta.transport.beatsPerBar, want.transport.beatsPerBar);
      assert.equal(meta.scenes[0].startTick, BigInt(want.scene.startTick));
      assert.equal(meta.scenes[0].durTicks, BigInt(want.scene.durTicks));
      assert.equal(driver.evalBytes(0)?.length, 12 + 20 * want.entriesPerEval);
      for (const [tStr, values] of Object.entries(want.writes)) {
        const entries = driver.eval(Number(tStr));
        assert.equal(entries.length, want.entriesPerEval, `${variant} t=${tStr} entry count`);
        for (const [i, v] of values.entries()) {
          assert.equal(entries[0].value[i], v, `${variant} write f32 literal at t=${tStr}[${i}]`);
        }
      }
    }

    // Malformed: the public walker throws on the first .next() — the
    // error the page must surface, never a fabricated callback.
    const malformed = readFileSync(path.join(root, 'bundle', 'g5-malformed.png'));
    assert.throws(() => viewer.payloadsOf(malformed).next());
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
