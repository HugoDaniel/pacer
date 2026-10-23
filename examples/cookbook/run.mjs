#!/usr/bin/env node
// examples/cookbook/run.mjs - build once, pack every case, load it through
// the real npm glue, evaluate the configured clocks, and compare the whole
// observation against the committed expected.json.
//
//   node examples/cookbook/run.mjs [--update] [--case <id>] [--json] [--no-build]
//
// `--update` rewrites ONLY cases whose expectation is new or differs, and
// prints the changed lines. A second run without `--update` must be a
// byte-for-byte no-op; that is the determinism check the cookbook claims.
//
// This file is deliberately boring: it owns no score semantics. Every value
// comes from `pacer pack`, `Pacer` (text) or `PacerRt` (PACB); the runner
// only normalizes what those public surfaces return. If a case disagrees with
// expected.json, the implementation is the oracle - inspect the case's
// notes.md before changing the pin.

import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { Pacer } from '../../npm/pacer/src/index.js';
import { PacerRt } from '../../npm/pacer/src/rt.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const CASES_DIR = join(HERE, 'cases');
const BIN = join(ROOT, 'zig-out/bin/pacer');
const WASM_TEXT = join(ROOT, 'zig-out/bin/pacer.wasm');
const WASM_RT = join(ROOT, 'zig-out/bin/pacer-rt.wasm');
const TMP = join(ROOT, '.zig-cache/cookbook');

const MAX_BUFFER = 64 * 1024 * 1024;

const REASONS = [
  'bad_magic',
  'unsupported_version',
  'unsupported_features',
  'directory_malformed',
  'count_mismatch',
  'record_invalid',
  'cap_exceeded',
  'non_finite',
  'payload_malformed',
  'registry_mismatch',
  'meta_malformed',
  'dry_run_failed',
];

function usage() {
  console.log(
    [
      'usage: node examples/cookbook/run.mjs [--update] [--case <id>] [--json] [--no-build]',
      '',
      '  --update    rewrite failing/new expected.json and print changed lines',
      '  --case id   run one case (exact id)',
      '  --json      print one JSON object per case, no human summary',
      '  --no-build  use the existing zig-out/bin artifacts',
    ].join('\n'),
  );
}

function parseArgs(argv) {
  const opts = { update: false, json: false, caseId: null, build: true, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--update') opts.update = true;
    else if (a === '--json') opts.json = true;
    else if (a === '--no-build') opts.build = false;
    else if (a === '-h' || a === '--help') opts.help = true;
    else if (a === '--case') {
      const v = argv[++i];
      if (!v) throw new Error('--case requires an id');
      opts.caseId = v;
    } else throw new Error(`unknown argument: ${a}`);
  }
  return opts;
}

function run(cmd, args, label) {
  const r = spawnSync(cmd, args, {
    cwd: ROOT,
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (r.error) throw new Error(`${label}: ${r.error.message}`);
  if (r.status !== 0) {
    throw new Error(
      `${label} failed (exit ${r.status})\n--- stdout ---\n${r.stdout}\n--- stderr ---\n${r.stderr}`,
    );
  }
  return r;
}

function buildOnce() {
  run('zig', ['build', 'cli', 'wasm', 'wasm-rt', '-Doptimize=ReleaseSmall'], 'zig build');
  for (const path of [BIN, WASM_TEXT, WASM_RT]) {
    if (!existsSync(path)) throw new Error(`build did not produce ${relative(ROOT, path)}`);
  }
}

// A case's `registries` is the flat PACT order: entries are grouped by their
// optional `:registry` (default 0), registries ascending, arrival order kept
// inside each. The flat index IS the target_id space, so this is also the
// order of the `--target` flags passed to `pacer pack`.
function registryGroups(specs = []) {
  const max = specs.reduce((m, s) => Math.max(m, s.registry ?? 0), -1);
  const groups = Array.from({ length: Math.max(0, max + 1) }, () => []);
  for (const spec of specs) {
    const r = spec.registry ?? 0;
    groups[r].push({ name: spec.name, ncomp: spec.arity ?? spec.ncomp ?? 1 });
  }
  return groups;
}

function flatTargets(groups) {
  return groups.flatMap((targets, registry) =>
    targets.map((t) => ({ name: t.name, ncomp: t.ncomp, registry })),
  );
}

function packTargetArgs(groups) {
  const args = [];
  for (const t of flatTargets(groups)) {
    args.push('--target', `${t.name}:${t.ncomp}:${t.registry}`);
  }
  return args;
}

function packStatus(exit) {
  if (exit === 0) return 'ok';
  if (exit === 1) return 'diagnostics';
  if (exit === 2) return 'usage';
  if (exit === 3) return 'internal';
  return `exit-${exit}`;
}

function diagFromPack(d) {
  return {
    source: d.producer === 'pacer' ? 'pacer' : 'sjon',
    severity: d.severity === 'err' ? 'error' : d.severity,
    code: d.code_id,
    start: d.span?.start ?? 0,
    end: d.span?.end ?? 0,
    message: d.message,
  };
}

function diagFromDriver(d) {
  return {
    source: d.source,
    severity: d.severity,
    code: d.code,
    start: d.start,
    end: d.end,
    message: d.message,
  };
}

function packScore(scorePath, groups, outPath) {
  const args = ['pack', scorePath, '--out', outPath, ...packTargetArgs(groups)];
  const r = spawnSync(BIN, args, {
    cwd: ROOT,
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (r.error) throw new Error(`pack ${scorePath}: ${r.error.message}`);
  if (r.status === 2 || r.status === 3) {
    throw new Error(
      `pack ${scorePath} failed (exit ${r.status})\n--- stdout ---\n${r.stdout}\n--- stderr ---\n${r.stderr}`,
    );
  }
  let report;
  try {
    report = JSON.parse(r.stdout);
  } catch (err) {
    throw new Error(
      `pack ${scorePath}: stdout is not JSON (${err.message})\n--- stdout ---\n${r.stdout}\n--- stderr ---\n${r.stderr}`,
    );
  }
  const bytes = r.status === 0 && existsSync(outPath) ? readFileSync(outPath) : null;
  if (r.status === 0 && !bytes) throw new Error(`pack ${scorePath}: exit 0 but no blob at ${outPath}`);
  return {
    exit: r.status,
    report,
    bytes,
    expectation: {
      exit: r.status,
      status: packStatus(r.status),
      reason: null,
      diagnostics: (report.diagnostics ?? []).map(diagFromPack),
    },
  };
}

function deriveBytes(bytes, derives = []) {
  let out = bytes;
  const labels = [];
  for (const d of derives) {
    if (d.kind !== 'truncate') throw new Error(`unsupported derive kind: ${d.kind}`);
    const at = Number(d.at);
    if (!Number.isInteger(at) || at < 0) throw new Error(`bad truncate position: ${d.at}`);
    out = out.subarray(0, Math.min(at, out.length));
    labels.push(`truncate@${at}`);
  }
  return { bytes: out, label: labels.join('+') || 'derived' };
}

// `ok` is the LAST LOAD's acceptance; `live` is whether a score is armed.
// They differ exactly on a refused reload, where the runtime keeps the old
// score evaluable (the transactional contract this cookbook pins).
function loadInfoRt(driver) {
  const refused = driver.status === 1;
  const info = {
    ok: driver.status === 0,
    live: driver.ok,
    status: driver.status,
    // prt_loadError is written only on a status-1 refusal; on success it
    // retains the previous refusal word. Keep the stale word visible under
    // its own name instead of reporting it as this load's reason.
    reason: refused ? driver.reason : null,
    reasonName: refused ? (REASONS[driver.reason] ?? `reason-${driver.reason}`) : null,
    diagnostics: driver.diagnostics.map(diagFromDriver),
  };
  if (!refused && driver.reason !== 0) info.retainedReason = driver.reason;
  return info;
}

function loadInfoText(driver) {
  return {
    ok: driver.ok,
    diagnostics: driver.diagnostics.map(diagFromDriver),
  };
}

// Big-endian f32 bit pattern as a string. The conversion goes through an
// explicit DataView so the hex is the IEEE pattern, not host memory order.
const F32_SCRATCH = new DataView(new ArrayBuffer(4));
function f32BitsOfOne(value) {
  F32_SCRATCH.setFloat32(0, value, false);
  return `0x${F32_SCRATCH.getUint32(0, false).toString(16).padStart(8, '0')}`;
}

function f32Bits(values, ncomp) {
  const bits = [];
  for (let i = 0; i < ncomp; i++) bits.push(f32BitsOfOne(values[i]));
  return bits;
}

function metaOf(driver) {
  const m = driver.meta;
  if (!m) return null;
  return {
    bpm: m.transport.bpm,
    beatsPerBar: m.transport.beatsPerBar,
    dur: m.transport.dur === null ? null : String(m.transport.dur),
    end: m.transport.end,
    tempoMap: m.tempoMap.map((s) => ({ tick: String(s.tick), bpm: s.bpm })),
    scenes: m.scenes.map((s) => ({
      name: s.name,
      startTick: String(s.startTick),
      durTicks: String(s.durTicks),
    })),
    controls: m.controls.map((c) => ({
      index: c.index,
      id: c.id,
      target: c.name,
      registry: c.registry,
      ncomp: c.ncomp,
      type: c.type,
      value: Array.from(c.value).slice(0, c.ncomp),
      min: c.min === null ? null : Array.from(c.min).slice(0, c.ncomp),
      max: c.max === null ? null : Array.from(c.max).slice(0, c.ncomp),
    })),
    trackCount: m.tracks.length,
    tracks: m.tracks.map((t) => ({
      targetId: t.targetId,
      name: t.name,
      registry: t.registry,
      ncomp: t.ncomp,
      source: t.source,
      keys: t.keys.map((k) => ({
        at: String(k.at),
        bits: f32Bits(k.value, t.ncomp),
        easeRef: k.easeRef,
      })),
    })),
  };
}

function decimal(v) {
  // JSON.stringify(-0) is "0"; the sign is the point of the negative-zero
  // case. Pin the decimal spelling here and the bits in `bitsOf` below.
  return Object.is(v, -0) ? '-0' : v;
}

function writeTuple(entry) {
  const values = [];
  const bits = [];
  for (let i = 0; i < entry.ncomp; i++) {
    values.push(decimal(entry.value[i]));
    bits.push(f32BitsOfOne(entry.value[i]));
  }
  return [entry.name, values, bits];
}

function compareTarget(a, b) {
  const x = a === null ? '' : String(a);
  const y = b === null ? '' : String(b);
  return x < y ? -1 : x > y ? 1 : 0;
}

function frameOf(entries, time) {
  if (entries === null) return { time, order: null, writes: null };
  // Copy before the driver's next eval: WriteEntry and its Float32Array are
  // reused frame to frame (the hot-path contract in index.js).
  const order = entries.map((e) => e.name);
  const writes = entries.map(writeTuple);
  writes.sort((a, b) => compareTarget(a[0], b[0]));
  return { time, order, writes };
}

function framesFor(driver, times) {
  return times.map((t) => frameOf(driver.eval(t), t));
}

function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

async function computeText(c, groups, scorePath, times) {
  const source = readFileSync(scorePath, 'utf8');
  const driver = await Pacer.load(readFileSync(WASM_TEXT), source, { registries: groups });
  return {
    load: { driver: 'text', ...loadInfoText(driver) },
    meta: metaOf(driver),
    frames: driver.ok ? framesFor(driver, times) : times.map((t) => frameOf(null, t)),
  };
}

async function computeBinary(c, groups, bytes, times) {
  const driver = await PacerRt.load(readFileSync(WASM_RT), bytes, { registries: groups });
  return {
    load: { driver: 'runtime', ...loadInfoRt(driver) },
    meta: metaOf(driver),
    frames: driver.ok ? framesFor(driver, times) : times.map((t) => frameOf(null, t)),
  };
}

async function computeDerivedBinary(c, groups, bytes, times) {
  const derived = deriveBytes(bytes, c.derives);
  const derivedDriver = await PacerRt.load(readFileSync(WASM_RT), derived.bytes, {
    registries: groups,
  });
  const canonical = await PacerRt.load(readFileSync(WASM_RT), bytes, { registries: groups });
  if (!canonical.ok) throw new Error(`canonical PACB refused: ${JSON.stringify(loadInfoRt(canonical))}`);
  return {
    load: {
      driver: 'runtime',
      derived: { name: derived.label, ...loadInfoRt(derivedDriver) },
      canonical: loadInfoRt(canonical),
    },
    meta: metaOf(canonical),
    frames: framesFor(canonical, times),
  };
}

async function computeVariants(c, groups, bytes, times) {
  const canonical = await PacerRt.load(readFileSync(WASM_RT), bytes, { registries: groups });
  if (!canonical.ok) throw new Error(`canonical PACB refused: ${JSON.stringify(loadInfoRt(canonical))}`);
  const variants = [];
  for (const v of c.variants ?? []) {
    const vg = registryGroups(v.registries);
    const driver = await PacerRt.load(readFileSync(WASM_RT), bytes, { registries: vg });
    variants.push({ name: v.name, ...loadInfoRt(driver) });
  }
  return {
    load: { driver: 'runtime', variants, canonical: loadInfoRt(canonical) },
    meta: metaOf(canonical),
    frames: framesFor(canonical, times),
  };
}

async function computeBoth(c, groups, bytes, scorePath, times) {
  const source = readFileSync(scorePath, 'utf8');
  const text = await Pacer.load(readFileSync(WASM_TEXT), source, { registries: groups });
  const bin = await PacerRt.load(readFileSync(WASM_RT), bytes, { registries: groups });
  if (!text.ok) throw new Error(`text load refused: ${JSON.stringify(loadInfoText(text))}`);
  if (!bin.ok) throw new Error(`binary load refused: ${JSON.stringify(loadInfoRt(bin))}`);
  const textFrames = framesFor(text, times);
  const binFrames = framesFor(bin, times);
  if (!sameJson(textFrames, binFrames)) {
    throw new Error(
      `parity mismatch\n--- text ---\n${JSON.stringify(textFrames, null, 2)}\n` +
        `--- binary ---\n${JSON.stringify(binFrames, null, 2)}`,
    );
  }
  return {
    load: {
      driver: 'both',
      text: loadInfoText(text),
      binary: loadInfoRt(bin),
      parity: true,
    },
    meta: metaOf(text),
    frames: textFrames,
  };
}

async function computeLifecycle(c, groups, scorePath, workDir, times) {
  const badPath = join(dirname(scorePath), c.lifecycle.badScore);
  const badGroups = registryGroups(c.lifecycle.badRegistries ?? []);
  const bad = packScore(badPath, badGroups, join(workDir, 'bad.pacb'));
  if (!bad.bytes) throw new Error('lifecycle: bad score did not pack');

  const driver = await PacerRt.load(readFileSync(WASM_RT), readFileSync(join(workDir, 'score.pacb')), {
    registries: groups,
  });
  if (!driver.ok) throw new Error(`lifecycle: good score refused: ${JSON.stringify(loadInfoRt(driver))}`);
  const initialInfo = loadInfoRt(driver);
  const time = times[0] ?? 0;
  const initialFrame = frameOf(driver.eval(time), time);

  const badLoad = driver.load(bad.bytes);
  const refused = loadInfoRt(driver);
  const afterRefusal = frameOf(driver.eval(time), time);
  if (sameJson(initialFrame, afterRefusal) === false) {
    throw new Error('lifecycle: refused reload changed the live frame');
  }

  const goodLoad = driver.load(readFileSync(join(workDir, 'score.pacb')));
  const recovered = loadInfoRt(driver);
  const afterRecovery = frameOf(driver.eval(time), time);
  if (!goodLoad.ok) throw new Error(`lifecycle: recovery refused: ${JSON.stringify(recovered)}`);
  if (!sameJson(initialFrame, afterRecovery)) {
    throw new Error('lifecycle: recovery produced a different frame');
  }

  return {
    load: {
      driver: 'runtime',
      steps: [
        {
          name: 'initial',
          load: initialInfo,
          time,
          writes: initialFrame.writes,
          order: initialFrame.order,
        },
        {
          name: 'refused-reload',
          load: { ...refused, accepted: badLoad.ok },
          time,
          writes: afterRefusal.writes,
          order: afterRefusal.order,
        },
        {
          name: 'recovered',
          load: { ...recovered, accepted: goodLoad.ok },
          time,
          writes: afterRecovery.writes,
          order: afterRecovery.order,
        },
      ],
    },
    meta: metaOf(driver),
    frames: [initialFrame],
  };
}

async function computeCase(c, opts) {
  const scorePath = join(CASES_DIR, c.id, c.score ?? 'score.sjon');
  const groups = registryGroups(c.registries);
  const times = c.times ?? [];
  const workDir = join(TMP, c.id);
  rmSync(workDir, { recursive: true, force: true });
  mkdirSync(workDir, { recursive: true });

  const packed = packScore(scorePath, groups, join(workDir, 'score.pacb'));
  const expectation = {
    id: c.id,
    pack: packed.expectation,
    meta: null,
    frames: [],
    load: null,
  };

  const mode = c.loadMode ?? 'text';

  if (mode === 'text') {
    const text = await computeText(c, groups, scorePath, times);
    expectation.meta = text.meta;
    expectation.frames = text.frames;
    expectation.load = text.load;
  } else if (mode === 'binary') {
    if (!packed.bytes) {
      throw new Error(`${c.id}: loadMode binary needs a packed carrier`);
    }
    const computed = c.derives?.length
      ? await computeDerivedBinary(c, groups, packed.bytes, times)
      : await computeBinary(c, groups, packed.bytes, times);
    expectation.meta = computed.meta;
    expectation.frames = computed.frames;
    expectation.load = computed.load;
  } else if (mode === 'both') {
    if (!packed.bytes) throw new Error(`${c.id}: loadMode both needs a packed carrier`);
    const computed = await computeBoth(c, groups, packed.bytes, scorePath, times);
    expectation.meta = computed.meta;
    expectation.frames = computed.frames;
    expectation.load = computed.load;
  } else if (mode === 'variants') {
    if (!packed.bytes) throw new Error(`${c.id}: loadMode variants needs a packed carrier`);
    const computed = await computeVariants(c, groups, packed.bytes, times);
    expectation.meta = computed.meta;
    expectation.frames = computed.frames;
    expectation.load = computed.load;
  } else if (mode === 'lifecycle') {
    if (!packed.bytes) throw new Error(`${c.id}: loadMode lifecycle needs a packed carrier`);
    const computed = await computeLifecycle(c, groups, scorePath, workDir, times);
    expectation.meta = computed.meta;
    expectation.frames = computed.frames;
    expectation.load = computed.load;
  } else {
    throw new Error(`${c.id}: unknown loadMode ${mode}`);
  }

  return expectation;
}

function lcsDiff(before, after) {
  const a = before === null ? [] : before.split('\n');
  const b = after.split('\n');
  const n = a.length;
  const m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] =
        a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.push(`- ${a[i]}`);
      i++;
    } else {
      out.push(`+ ${b[j]}`);
      j++;
    }
  }
  while (i < n) out.push(`- ${a[i++]}`);
  while (j < m) out.push(`+ ${b[j++]}`);
  return out;
}

function loadCases(opts) {
  const ids = readdirSync(CASES_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();
  if (opts.caseId && !ids.includes(opts.caseId)) {
    throw new Error(`unknown case: ${opts.caseId}`);
  }
  return ids
    .filter((id) => !opts.caseId || id === opts.caseId)
    .map((id) => {
      const c = JSON.parse(readFileSync(join(CASES_DIR, id, 'case.json'), 'utf8'));
      if (c.id !== id) throw new Error(`${id}/case.json says id ${c.id}`);
      return c;
    });
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    usage();
    return 0;
  }
  if (opts.build) buildOnce();
  else {
    for (const path of [BIN, WASM_TEXT, WASM_RT]) {
      if (!existsSync(path)) throw new Error(`--no-build: missing ${relative(ROOT, path)}`);
    }
  }

  let cases;
  try {
    cases = loadCases(opts);
  } catch (err) {
    console.error(err.message);
    return 2;
  }

  mkdirSync(TMP, { recursive: true });
  const results = [];
  let failed = 0;
  let changed = 0;

  for (const c of cases) {
    const expectedPath = join(CASES_DIR, c.id, 'expected.json');
    let actual;
    try {
      actual = await computeCase(c, opts);
    } catch (err) {
      failed++;
      const result = { id: c.id, title: c.title, ok: false, error: err.message };
      results.push(result);
      if (!opts.json) console.error(`FAIL ${c.id}: ${err.message}`);
      continue;
    }
    const text = `${JSON.stringify(actual, null, 2)}\n`;
    const before = existsSync(expectedPath) ? readFileSync(expectedPath, 'utf8') : null;
    const matches = before === text;
    let diff = [];
    if (!matches) {
      diff = lcsDiff(before, text);
      changed++;
      if (opts.update) writeFileSync(expectedPath, text);
    }
    const result = {
      id: c.id,
      title: c.title,
      aspect: c.aspect,
      ok: matches,
      expected: relative(ROOT, expectedPath),
      pack: { exit: actual.pack.exit, status: actual.pack.status },
      load: actual.load,
      frames: actual.frames.length,
      metaTracks: actual.meta?.trackCount ?? 0,
      changed: matches ? false : !opts.update,
      diff,
    };
    results.push(result);
    if (!opts.json) {
      if (matches) {
        console.log(`PASS ${c.id}`);
      } else if (opts.update) {
        console.log(`UPDATED ${c.id} (${diff.length} changed lines)`);
        for (const line of diff) console.log(`  ${line}`);
      } else {
        console.log(`FAIL ${c.id}`);
        for (const line of diff) console.log(`  ${line}`);
      }
    }
  }

  if (opts.update) {
    if (opts.json) {
      console.log(JSON.stringify(results, null, 2));
    } else {
      console.log(`${changed} case(s) updated, ${results.length - changed} unchanged`);
    }
    return failed === 0 ? 0 : 1;
  }

  const matched = results.filter((r) => r.ok).length;
  if (opts.json) {
    console.log(JSON.stringify(results, null, 2));
  } else {
    console.log(`${matched}/${results.length} cases match`);
  }
  return failed === 0 && matched === results.length ? 0 : 1;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((err) => {
    console.error(err.stack ?? err.message);
    process.exitCode = 2;
  });
