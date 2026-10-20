// G5 fixture builder — the reproducible authoring step, run on the
// wave host (both native CLIs are host-bound there; serialized, with
// the plan's ulimits applied by the caller):
//
//   cd pacer && npm run g5:prepare            # default webroot
//   node browser/prepare.mjs --root DIR       # or a configured root
//
// What it does (and nothing else):
//   1. probes the toolchain (zig, pngine CLI, public viewer bundle) —
//      loud failure with resolved absolute paths, never a guess;
//   2. rebuilds pacer-rt.wasm FRESH (`zig build wasm-rt` — never the
//      possibly-stale installed copy);
//   3. authors the two scores OFFLINE (the strings below are the only
//      oracle source; `expected.json` carries the hand literals) and
//      packs them with the fresh build-cache CLI (`zig build run --
//      pack`, the pretest-style invocation);
//   4. wraps the cartridges with the real pngine CLI — `--add PACB=…`
//      deflate for the G4 compressed pair + the hostile variant, `,raw`
//      for the raw variant;
//   5. truncates the REAL compressed bundle 60 bytes into the
//      malformed fixture (the G4 corruption contract: through IEND
//      into the pNGx body);
//   6. copies the public pngine viewer bundle, the PacerRt closure
//      (rt.js/meta.js/pact.js) and the page files into an ISOLATED
//      webroot (default .agent/artifacts/g5-web, gitignored);
//   7. pins every served byte in manifest.json (digests computed from
//      the bytes actually written) and records the toolchain (incl.
//      the pngine CLI sha256) for provenance.
//
// The webroot never contains score text (.sjon), no compiler wasm,
// no pacer.wasm, no Pack/Compile modules — the generator writes its
// intermediates to a temp dir outside the served root and removes it.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { cp, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';
import { defaultWebroot, ROUTES } from './server.mjs';

const BROWSER = fileURLToPath(new URL('./', import.meta.url));
const NPM_PACER = path.resolve(BROWSER, '..');
const REPO_ROOT = path.resolve(NPM_PACER, '..', '..');
// The sibling pngine checkout: four levels up from browser/ (B4 — the
// resolved absolute path is printed in every failure).
const DEFAULT_PNGINE = fileURLToPath(new URL('../../../../pngine', import.meta.url));

// ── The authored scores (the offline authoring step) ─────────────────

/** Byte-identical to the G4 probe's `g4-bundle-wave.score.sjon`. */
const DROP_SCORE = [
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

// A VALID score whose scene name is HTML-like ASCII: `<b>&<img/src=x>`
// would inject elements if a page ever rendered names as HTML. The
// proof renders names through textContent — the page spec asserts the
// literal glyphs and zero injected img/b elements. (SJON symbol bodies
// are ASCII-permissive: < > & / = are symbol bytes; whitespace and
// parens would terminate the symbol and are NOT valid in a name.)
const HOSTILE_SCORE = [
  '; hostile-names — a VALID score whose scene name is HTML-like ASCII',
  '; (G5 brief): <b>&<img/src=x> would inject elements if a page ever',
  '; rendered names as HTML; the proof renders names via textContent.',
  '(target :name glow :arity 1 :registry 0)',
  '',
  '(transport :bpm 120 :meter [4 4] :dur 4bar :end loop)',
  '',
  '(scene :name <b>&<img/src=x> :at 0b :dur 8b',
  '  (track :target glow',
  '    (key :at 0b :value 0.5)',
  '    (key :at 4b :value 0.9 :ease out-cubic)))',
  '',
].join('\n');

const VARIANTS = {
  compressed: {
    bundle: 'bundle/g4-bundle.png',
    score: DROP_SCORE,
    raw: false,
    flags: 1,
    names: ['drop'],
  },
  raw: {
    bundle: 'bundle/g4-bundle-raw.png',
    score: DROP_SCORE,
    raw: true,
    flags: 0,
    names: ['drop'],
  },
  hostile: {
    bundle: 'bundle/g5-hostile.png',
    score: HOSTILE_SCORE,
    raw: false,
    flags: 1,
    names: ['<b>&<img/src=x>'],
  },
};

// ── helpers ──────────────────────────────────────────────────────────

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const fail = (message) => {
  console.error(`g5:prepare: ${message}`);
  process.exit(1);
};

/** PNG chunk framing — the deterministic 1×1 carrier, as in G4's probe. */
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

function oneByOnePng() {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(1, 0);
  ihdr.writeUInt32BE(1, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const raw = Buffer.from([0, 0, 0, 0, 0]);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

// ── main ─────────────────────────────────────────────────────────────

async function main() {
  const argv = process.argv.slice(2);
  const opts = { root: defaultWebroot(), keepGen: false };
  for (let i = 0; i < argv.length; i++) {
    // L4: a flag with no value is a curated refusal — never a thrown
    // path resolve.
    if (argv[i] === '--root' || argv[i] === '--keep-gen') {
      if (argv[i] === '--root') {
        if (i + 1 >= argv.length) {
          fail('--root requires a value — usage: prepare.mjs [--root DIR] [--keep-gen]');
        }
        i++;
        opts.root = path.resolve(argv[i]);
      } else {
        opts.keepGen = true;
      }
    } else {
      fail(`unknown argument ${argv[i]} — usage: prepare.mjs [--root DIR] [--keep-gen]`);
    }
  }

  // 1. Toolchain probes — loud, with resolved absolute paths.
  const override = process.env.PACER_PNGINE;
  const pngineRoot = override ? path.resolve(override) : DEFAULT_PNGINE;
  const pngineCli = path.join(pngineRoot, 'zig-out', 'bin', 'pngine');
  const viewerSrc = path.join(pngineRoot, 'npm', 'pngine', 'dist', 'viewer.mjs');
  if (!existsSync(viewerSrc)) {
    fail(`pngine viewer bundle not found at ${viewerSrc} (set PACER_PNGINE or build pngine)`);
  }
  if (!existsSync(pngineCli))
    fail(`pngine CLI not found at ${pngineCli} (build it: zig build install)`);
  const cliVersion = spawnSync(pngineCli, ['version'], { encoding: 'utf8' });
  if (cliVersion.error || cliVersion.status !== 0) {
    fail(
      `pngine CLI at ${pngineCli} cannot exec on this host (${cliVersion.error?.code ?? cliVersion.status}) — the builder runs on the wave host`,
    );
  }
  const zigVersion = spawnSync('zig', ['version'], { encoding: 'utf8' });
  if (zigVersion.error)
    fail(
      `zig toolchain unavailable (${zigVersion.error.code}) — the builder runs on the wave host`,
    );
  const cliBytes = readFileSync(pngineCli);
  console.log(
    `toolchain: zig ${zigVersion.stdout.trim()} | pngine ${cliVersion.stdout.trim()} (${pngineCli})`,
  );

  await mkdir(opts.root, { recursive: true });
  await mkdir(path.join(opts.root, 'bundle'), { recursive: true });
  const gen = await mkdtemp(path.join(tmpdir(), 'pacer-g5-gen-'));

  try {
    // 2. Fresh runtime wasm — never the stale installed copy.
    const wasmBuild = spawnSync('zig', ['build', 'wasm-rt'], { cwd: REPO_ROOT, encoding: 'utf8' });
    if (wasmBuild.error || wasmBuild.status !== 0) {
      fail(
        `zig build wasm-rt failed in ${REPO_ROOT}: ${wasmBuild.stderr ?? wasmBuild.error?.code}`,
      );
    }
    const wasmSrc = path.join(REPO_ROOT, 'zig-out', 'bin', 'pacer-rt.wasm');
    const wasmBytes = readFileSync(wasmSrc);
    if (!WebAssembly.validate(wasmBytes))
      fail(`freshly built ${wasmSrc} does not validate as wasm`);

    // 3-4. Author offline, pack with the fresh build-cache CLI, wrap
    // with the real pngine CLI.
    const basePng = oneByOnePng();
    await writeFile(path.join(gen, 'base.png'), basePng);
    const cartridges = {};
    for (const [name, variant] of Object.entries(VARIANTS)) {
      const scorePath = path.join(gen, `${name}.score.sjon`);
      const pacbPath = path.join(gen, `${name}.pacb`);
      await writeFile(scorePath, variant.score);
      const packed = spawnSync(
        'zig',
        ['build', 'run', '--', 'pack', scorePath, '--out', pacbPath],
        { cwd: REPO_ROOT, encoding: 'utf8' },
      );
      if (packed.error || packed.status !== 0) {
        fail(`pacer pack refused ${name}: ${packed.stderr ?? packed.error?.code}`);
      }
      cartridges[name] = readFileSync(pacbPath);
      const suffix = variant.raw ? ',raw' : '';
      const bundledPath = path.join(opts.root, variant.bundle);
      const wrap = spawnSync(
        pngineCli,
        [
          'pack',
          path.join(gen, 'base.png'),
          '--add',
          `PACB=${pacbPath}${suffix}`,
          '-o',
          bundledPath,
        ],
        {
          encoding: 'utf8',
        },
      );
      if (wrap.error || wrap.status !== 0)
        fail(`pngine pack failed for ${name}: ${wrap.stderr ?? wrap.error?.code}`);
    }

    // 5. The malformed fixture: the REAL compressed bundle truncated.
    const bundled = readFileSync(path.join(opts.root, VARIANTS.compressed.bundle));
    const malformed = bundled.subarray(0, bundled.length - 60);
    if (malformed.length === 0) fail('truncation consumed the whole bundle — refusing');
    writeFileSync(path.join(opts.root, 'bundle', 'g5-malformed.png'), malformed);

    // 6. The isolated served tree: public viewer bundle, PacerRt
    // closure, freshly built wasm, page files — copies, byte-exact.
    const wasmDest = path.join(opts.root, 'pacer-rt.wasm');
    writeFileSync(wasmDest, wasmBytes);
    await cp(viewerSrc, path.join(opts.root, 'viewer.mjs'));
    for (const src of ['rt.js', 'meta.js', 'pact.js']) {
      await cp(path.join(NPM_PACER, 'src', src), path.join(opts.root, src));
    }
    for (const src of ['index.html', 'app.js', 'style.css']) {
      await cp(path.join(BROWSER, src), path.join(opts.root, src));
    }

    // 7. Manifest — digests over the bytes actually on disk. The
    // manifest excludes itself from its own inventory (that would be
    // circular); its digest is printed below and recorded in the wave
    // report — in the page it is the root of trust and is not
    // self-verified.
    const files = {};
    for (const [route, def] of Object.entries(ROUTES)) {
      if (!def.file || route === '/manifest.json') continue;
      const bytes = readFileSync(path.join(opts.root, def.file));
      files[route] = { path: def.file, bytes: bytes.length, sha256: sha256(bytes) };
    }
    const manifest = {
      generator: 'npm/pacer/browser/prepare.mjs',
      generatedAt: new Date().toISOString(),
      toolchain: {
        zig: zigVersion.stdout.trim(),
        pngine: cliVersion.stdout.trim(),
        pngineCliBytes: cliBytes.length,
        pngineCliSha256: sha256(cliBytes),
      },
      variants: Object.fromEntries(
        Object.entries(VARIANTS).map(([name, variant]) => [
          name,
          {
            bundle: `/${variant.bundle}`,
            bundleSha256: sha256(readFileSync(path.join(opts.root, variant.bundle))),
            flags: variant.flags,
            cartridgeSha256: sha256(cartridges[name]),
            cartridgeBytes: cartridges[name].length,
            names: variant.names,
          },
        ]),
      ),
      malformed: {
        bundle: '/bundle/g5-malformed.png',
        bundleSha256: sha256(readFileSync(path.join(opts.root, 'bundle', 'g5-malformed.png'))),
        truncatedFrom: `/${VARIANTS.compressed.bundle}`,
        truncatedBytes: 60,
      },
      files,
    };
    writeFileSync(path.join(opts.root, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);

    console.log(`webroot: ${opts.root}`);
    for (const [name, variant] of Object.entries(VARIANTS)) {
      console.log(
        `${name}: ${variant.bundle} ${manifest.variants[name].bundleSha256} (cartridge ${manifest.variants[name].cartridgeBytes} B)`,
      );
    }
    console.log(`manifest sha256: ${sha256(readFileSync(path.join(opts.root, 'manifest.json')))}`);
  } finally {
    if (opts.keepGen) console.log(`gen dir kept: ${gen}`);
    else await rm(gen, { recursive: true, force: true });
  }
}

main().catch((error) => fail(String(error?.stack ?? error)));
