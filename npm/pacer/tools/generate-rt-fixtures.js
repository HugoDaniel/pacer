// A5 fixture producer — the shared corpus→PACB generator (plan 06 A5).
//
// For EVERY corpus case this packs the case's real document through the
// REAL freshly-built CLI (`zig-out/bin/pacer pack`, the ordinary offline
// producer) against the case's ACTUAL host registry join taken from
// parseHarness — the same join the corpus walk and the runtime load use.
// Clean cases land a real `test/fixtures/<case>.pacb`; load-failing cases
// are recorded as explicit refusals (exit 1 + the producer's own
// diagnostic codes) and never get fixture bytes. The manifest this writes
// (fixtures/manifest.json) ties every fixture to the producer CLI's and
// the wasm artifacts' content digests, so test/rt-corpus.test.js can bite
// on stale or tampered blobs instead of passing silently.
//
// Invocation is wired, never a manual one-off: the npm `pretest` hook and
// `zig build verify` (build.zig) both run this file before the node suite.
// It spawns the host-native CLI, so it runs where zig build ran (the wave
// host); elsewhere it fails loudly naming the missing binary — a missing
// producer is never a silent skip.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseHarness } from '../test/harness.js';

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const repoRoot = fileURLToPath(new URL('../../../', import.meta.url));
const corpusDir = path.join(repoRoot, 'corpus');
const fixturesDir = fileURLToPath(new URL('../test/fixtures/', import.meta.url));
const manifestPath = fileURLToPath(new URL('../test/fixtures/manifest.json', import.meta.url));
const cliPath = path.join(repoRoot, 'zig-out', 'bin', 'pacer');

/** The same enumeration corpus.test.js and rt-corpus.test.js walk. */
const cases = readdirSync(corpusDir, { withFileTypes: true })
  .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
  .map((e) => e.name)
  .sort();
if (cases.length === 0) {
  throw new Error(`generate-rt-fixtures: no corpus cases under ${corpusDir}`);
}

if (!existsSync(cliPath)) {
  throw new Error(
    `generate-rt-fixtures: the pack producer ${cliPath} is missing — run \`zig build cli\` first ` +
      '(the npm pretest hook and zig build verify both do)',
  );
}

mkdirSync(fixturesDir, { recursive: true });

/** Digest record for one artifact the fixture set is tied to. */
const artifactRecord = (absolutePath) => {
  const bytes = readFileSync(absolutePath);
  return { bytes: bytes.length, sha256: sha256(bytes) };
};

const manifest = {
  generator: 'npm/pacer/tools/generate-rt-fixtures.js',
  purpose: 'A5 rt-corpus playback fixtures — real pacer pack output, one entry per corpus case',
  producer: {
    cli: { path: 'zig-out/bin/pacer', ...artifactRecord(cliPath) },
    artifacts: {
      'zig-out/bin/pacer-rt.wasm': artifactRecord(
        path.join(repoRoot, 'zig-out', 'bin', 'pacer-rt.wasm'),
      ),
      'zig-out/bin/pacer.wasm': artifactRecord(path.join(repoRoot, 'zig-out', 'bin', 'pacer.wasm')),
    },
  },
  cases: {},
};

const packed = [];
const refused = [];

for (const name of cases) {
  const times = readFileSync(path.join(corpusDir, name, 'times.sjon'), 'utf8');
  const harness = parseHarness(times);
  // The host join from parseHarness only: flat order IS the target_id
  // space, spelled `NAME[:ncomp[:registry]]` (the CLI's --target grammar,
  // defaults 1/0). Never mined from unknown-target diagnostics.
  const join = harness.flat.map((t) =>
    t.ncomp === 1 && t.registry === 0
      ? t.name
      : t.registry === 0
        ? `${t.name}:${t.ncomp}`
        : `${t.name}:${t.ncomp}:${t.registry}`,
  );

  const fixtureRel = path.join('npm', 'pacer', 'test', 'fixtures', `${name}.pacb`);
  const pack = spawnSync(
    cliPath,
    [
      'pack',
      path.join('corpus', name, 'doc.sjon'),
      ...join.flatMap((t) => ['--target', t]),
      '--out',
      fixtureRel,
    ],
    { cwd: repoRoot, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, timeout: 120_000 },
  );

  if (pack.error !== undefined) {
    throw new Error(`generate-rt-fixtures: ${name}: the producer failed to run: ${pack.error}`);
  }
  let envelope;
  try {
    envelope = JSON.parse(pack.stdout);
  } catch {
    throw new Error(
      `generate-rt-fixtures: ${name}: the producer printed no JSON envelope (exit ${pack.status})\n` +
        pack.stdout.slice(0, 400),
    );
  }

  if (pack.status === 0) {
    if (envelope.pack === null || typeof envelope.pack !== 'object') {
      throw new Error(
        `generate-rt-fixtures: ${name}: exit 0 but the envelope carries no packed blob`,
      );
    }
    const bytes = readFileSync(path.join(repoRoot, fixtureRel));
    if (bytes.length === 0) {
      throw new Error(`generate-rt-fixtures: ${name}: the producer wrote an empty blob`);
    }
    manifest.cases[name] = {
      outcome: 'packed',
      file: fixtureRel,
      join,
      ...artifactRecord(path.join(repoRoot, fixtureRel)),
    };
    packed.push(name);
  } else if (pack.status === 1) {
    if (envelope.pack !== null) {
      throw new Error(
        `generate-rt-fixtures: ${name}: exit 1 but the envelope carries a packed blob`,
      );
    }
    const codes = (envelope.diagnostics ?? []).map((d) => d.code);
    if (codes.length === 0) {
      throw new Error(`generate-rt-fixtures: ${name}: refused without a single diagnostic code`);
    }
    // A previously clean case that now refuses must not leave a stale
    // blob behind for the walk to trip over.
    rmSync(path.join(repoRoot, fixtureRel), { force: true });
    manifest.cases[name] = { outcome: 'refused', exitStatus: 1, codes, join };
    refused.push(name);
  } else {
    throw new Error(
      `generate-rt-fixtures: ${name}: unexpected producer exit ${pack.status}` +
        (pack.signal ? ` (signal ${pack.signal})` : ''),
    );
  }
}

// Exact directory hygiene: any *.pacb the walk could enumerate that this
// run did not produce is removed, so a stale file can never satisfy a
// later run. The manifest is replaced atomically.
const live = new Set(packed.map((n) => `${n}.pacb`));
for (const file of readdirSync(fixturesDir)) {
  if (file.endsWith('.pacb') && !live.has(file)) {
    rmSync(path.join(fixturesDir, file), { force: true });
  }
}
const manifestTmp = `${manifestPath}.tmp`;
writeFileSync(manifestTmp, `${JSON.stringify(manifest, null, 2)}\n`);
renameSync(manifestTmp, manifestPath);

console.log(
  `generate-rt-fixtures: ${cases.length} case(s) — ${packed.length} packed, ${refused.length} refused; ` +
    `manifest ${path.relative(repoRoot, manifestPath)}`,
);
