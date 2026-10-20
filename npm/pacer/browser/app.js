// The G5 diagnostic bench — Operate (load a variant, eval at a
// supplied time) with a secondary Read (the assertion readout). One
// job: prove a served PNG bundle → pngine's public `payloadsOf` → a
// source-free `PacerRt` → visible scene names + supplied-time writes,
// passively verifying every fetched byte against the served manifest
// (crypto.subtle digests over the actual bytes — never headers).
//
// Honesty rules this file is written under:
//   - every failure (fetch, digest mismatch, walker throw, wasm load
//     refusal) surfaces in #error and CLEARS/blocks all data zones —
//     never a stale name, never a fake success;
//   - names render through textContent ONLY (never innerHTML, never
//     object keys) — hostile name bytes appear as literal glyphs;
//   - raw-DEFLATE inflation uses the platform DecompressionStream —
//     the same primitive pngine's own inflate.js uses — no second
//     codec; the proof is the cartridge digest matching the manifest;
//   - `window.__pacerProof` is a passive readback for QA (values,
//     digests, requests, errors) — it drives nothing.

import { PacerRt } from '/rt.js';
import { payloadsOf } from '/viewer.mjs';

const $ = (id) => document.getElementById(id);

const state = {
  manifest: null,
  rtModule: null,
  driver: null,
  variant: null,
  writes: 0,
};

// Passive QA readback: values, digests, requests, errors — no fake
// success; every field is set from something that actually happened.
const proof = {
  status: 'boot',
  variant: null,
  manifestVerified: false,
  digests: {},
  names: null,
  writes: [],
  requests: [],
  errors: [],
};

function setStatus(text, kind = '') {
  $('status').textContent = text;
  $('status').className = kind;
  proof.status = kind === '' ? text : kind;
}

function showError(error) {
  const message = error?.message ?? String(error);
  $('error').textContent = message;
  $('error').hidden = false;
  setStatus(`error: ${message}`, 'error');
  proof.errors.push(message);
  proof.digests = {};
  proof.names = null;
  // Clear and block every data zone — no stale names, no stale
  // writes, no eval against a half-armed runtime.
  $('names').textContent = '—';
  $('scene-count').textContent = '—';
  for (const id of [
    'transport-bpm',
    'transport-dur',
    'transport-end',
    'transport-bpb',
    'scene-start',
    'scene-dur',
  ]) {
    $(id).textContent = '—';
  }
  $('hash').textContent = '—';
  const tbody = $('writes-table').tBodies[0];
  while (tbody.rows.length > 0) tbody.deleteRow(0);
  $('writes').textContent = 'writes cleared after error';
  $('eval-button').disabled = true;
  state.driver = null;
  state.variant = null;
}

function clearError() {
  $('error').hidden = true;
  $('error').textContent = '';
}

async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Fetch a fixture route and verify its bytes against the manifest. */
async function fetchVerified(route) {
  const res = await fetch(route);
  if (!res.ok) throw new Error(`fetch ${route} failed: HTTP ${res.status}`);
  const bytes = new Uint8Array(await res.arrayBuffer());
  const pin = state.manifest.files[route];
  if (!pin) throw new Error(`manifest pins no bytes for ${route}`);
  const digest = await sha256Hex(bytes);
  if (digest !== pin.sha256 || bytes.length !== pin.bytes) {
    throw new Error(
      `digest mismatch for ${route}: fetched ${bytes.length} B sha256 ${digest}, manifest pins ${pin.bytes} B sha256 ${pin.sha256}`,
    );
  }
  return bytes;
}

/** Raw-DEFLATE via the platform — the same primitive pngine uses. */
async function inflateRaw(bytes) {
  if (typeof DecompressionStream !== 'function') {
    throw new Error(
      'DecompressionStream("deflate-raw") unsupported — cannot inflate the compressed bundle',
    );
  }
  const stream = new DecompressionStream('deflate-raw');
  const writer = stream.writable.getWriter();
  const reader = stream.readable.getReader();
  writer.write(bytes).catch(() => {});
  writer.close().catch(() => {});
  const chunks = [];
  let len = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    len += value.length;
  }
  const out = new Uint8Array(len);
  let at = 0;
  for (const chunk of chunks) {
    out.set(chunk, at);
    at += chunk.length;
  }
  return out;
}

async function refreshRequestLog() {
  const res = await fetch('/__requests.json');
  if (!res.ok) return;
  const { requests } = await res.json();
  proof.requests = requests;
  $('request-log').textContent = requests
    .map((e) => `${e.method} ${e.path} ${e.status}`)
    .join('\n');
}

function renderMetadata(driver) {
  const meta = driver.meta;
  const names = meta.scenes.map((s) => s.name);
  // textContent ONLY — hostile names must appear as literal glyphs.
  $('names').textContent = names.join(', ');
  proof.names = names;
  $('scene-count').textContent = String(meta.scenes.length);
  $('transport-bpm').textContent = String(meta.transport.bpm);
  $('transport-dur').textContent = String(meta.transport.dur);
  $('transport-end').textContent = String(meta.transport.end);
  $('transport-bpb').textContent = String(meta.transport.beatsPerBar);
  $('scene-start').textContent = String(meta.scenes[0].startTick);
  $('scene-dur').textContent = String(meta.scenes[0].durTicks);
}

function setPressed(name) {
  for (const id of ['toggle-compressed', 'toggle-raw', 'toggle-hostile']) {
    $(id).setAttribute('aria-pressed', String(id === name));
  }
}

async function loadVariant(name) {
  clearError();
  setPressed(`toggle-${name}`);
  $('eval-button').disabled = true;
  const bundleRoute = state.manifest.variants[name].bundle;
  try {
    setStatus(`loading ${bundleRoute} …`);
    const bundle = await fetchVerified(bundleRoute);
    proof.variant = name;
    state.variant = name;
    proof.digests.bundle = { route: bundleRoute, sha256: await sha256Hex(bundle), match: true };

    setStatus(`extracting PACB payloads …`);
    const payloads = [...payloadsOf(bundle)]; // throws on a malformed bundle
    if (payloads.length !== 1) {
      throw new Error(`expected exactly one PACB payload, got ${payloads.length}`);
    }
    const pacb = payloads[0];
    if (pacb.kind !== 'PACB' || pacb.version !== 1) {
      throw new Error(`unexpected payload ${pacb.kind} v${pacb.version}`);
    }
    const wantFlags = state.manifest.variants[name].flags;
    if ((pacb.flags & 1) !== wantFlags) {
      throw new Error(
        `flags ${(pacb.flags & 1).toString(2)} disagree with the manifest pin (${wantFlags})`,
      );
    }

    setStatus('materializing the cartridge …');
    const cartridge = pacb.flags & 1 ? await inflateRaw(pacb.body) : pacb.body;
    const cartridgeDigest = await sha256Hex(cartridge);
    const cartridgePin = state.manifest.variants[name].cartridgeSha256;
    if (cartridgeDigest !== cartridgePin) {
      throw new Error(
        `cartridge digest mismatch: inflated ${cartridgeDigest}, manifest pins ${cartridgePin}`,
      );
    }
    proof.digests.cartridge = { sha256: cartridgeDigest, bytes: cartridge.length, match: true };

    setStatus('arming PacerRt …');
    const driver = await PacerRt.load(state.rtModule, cartridge);
    if (!driver.ok)
      throw new Error(`PacerRt refused the cartridge: status ${driver.status} (${driver.reason})`);
    state.driver = driver;

    renderMetadata(driver);
    $('hash').textContent = `${bundleRoute} sha256 ${proof.digests.bundle.sha256}`;
    setStatus(
      `ready — variant ${name}, ${state.manifest.variants[name].names.length} scene(s); eval enabled`,
      'ready',
    );
    $('eval-button').disabled = false;
  } catch (error) {
    showError(error);
  } finally {
    await refreshRequestLog();
  }
}

function evalAt(supplied) {
  if (!state.driver) return;
  const t = Number(supplied);
  if (!Number.isFinite(t)) {
    showError(new Error(`supplied time must be a finite number, got "${supplied}"`));
    return;
  }
  const entries = state.driver.eval(t) ?? [];
  const tbody = $('writes-table').tBodies[0];
  for (const entry of entries) {
    const row = tbody.insertRow();
    // textContent only, everywhere; names of targets are absent on
    // this path (declared-only targets carry no name over the wire),
    // so the key is the wasm-supplied join of id/registry/ncomp.
    row.insertCell().textContent = String(t);
    row.insertCell().textContent = `#${entry.targetId} reg${entry.registry} ×${entry.ncomp}`;
    row.insertCell().textContent = Array.from(entry.value.slice(0, entry.ncomp), String).join(', ');
    row.insertCell().textContent = String(entries.length);
    proof.writes.push({
      variant: state.variant,
      t,
      targetId: entry.targetId,
      registry: entry.registry,
      ncomp: entry.ncomp,
      value: Array.from(entry.value.slice(0, entry.ncomp)),
    });
  }
  if (entries.length === 0) {
    const row = tbody.insertRow();
    row.insertCell().textContent = String(t);
    row.insertCell().textContent = '—';
    row.insertCell().textContent = '—';
    row.insertCell().textContent = '0';
    proof.writes.push({ variant: state.variant, t, entries: 0 });
  }
  state.writes += 1;
  $('writes').textContent = `evals: ${state.writes} — rows: ${tbody.rows.length} (last t=${t})`;
  refreshRequestLog();
}

async function init() {
  for (const id of ['toggle-compressed', 'toggle-raw', 'toggle-hostile']) {
    $(id).addEventListener('click', () => loadVariant(id.replace('toggle-', '')));
  }
  // The malformed control is an ACTION, not a state: fetch the real
  // truncated bundle and let the public walker fail for real — the
  // error path is never a forged callback.
  $('toggle-malformed').addEventListener('click', () => loadMalformed());
  $('eval-button').addEventListener('click', () => evalAt($('time-input').value));
  for (const id of ['preset-0', 'preset-05', 'preset-2']) {
    $(id).addEventListener('click', () => {
      $('time-input').value = $(id).dataset.t;
    });
  }

  try {
    setStatus('loading manifest …');
    const res = await fetch('/manifest.json');
    if (!res.ok) throw new Error(`manifest fetch failed: HTTP ${res.status}`);
    state.manifest = await res.json();
    proof.manifestVerified = true;

    setStatus('fetching + verifying pacer-rt.wasm …');
    const wasmBytes = await fetchVerified('/pacer-rt.wasm');
    proof.digests.wasm = {
      sha256: await sha256Hex(wasmBytes),
      bytes: wasmBytes.length,
      match: true,
    };
    state.rtModule = new WebAssembly.Module(wasmBytes);

    await loadVariant('compressed');
  } catch (error) {
    showError(error);
    await refreshRequestLog();
  }
}

/** The failure-path control: the REAL truncated PNG through the REAL walker. */
async function loadMalformed() {
  clearError();
  setPressed(null);
  $('eval-button').disabled = true;
  try {
    setStatus('loading /bundle/g5-malformed.png (this must fail) …');
    const res = await fetch('/bundle/g5-malformed.png');
    if (!res.ok) throw new Error(`fetch malformed bundle failed: HTTP ${res.status}`);
    const bytes = new Uint8Array(await res.arrayBuffer());
    const payloads = [...payloadsOf(bytes)]; // the walker throws here
    throw new Error(
      `the malformed bundle unexpectedly yielded ${payloads.length} payload(s) — fixture broken`,
    );
  } catch (error) {
    showError(error);
  } finally {
    await refreshRequestLog();
  }
}

// Module scripts execute after the document is parsed.
if (document.readyState === 'loading') {
  window.addEventListener('DOMContentLoaded', () => init());
} else {
  init();
}

// Passive readback for QA (never consumed by the page itself).
window.__pacerProof = proof;
