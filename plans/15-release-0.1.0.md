# Pacer 0.1.0 release plan

Created 2026-10-25. Status: **released and verified.** npm
`@mr_hugo/pacer@0.1.0` and GitHub `v0.1.0` are live and aligned to source
`99e6c85`. The staged-publish placeholder was removed; no open actions.

The release target is **0.1.0**, tagged `v0.1.0`. The repository currently
declares 0.2.0; moving those declarations to 0.1.0 is intentional, per the
owner's release decision. This document is the checklist and evidence record
for a second review before publication.

## Scope

Release the existing Pacer compiler/evaluator, playback runtime, JS glue and
generated types. Include both `pacer.wasm` and `pacer-rt.wasm`, the `pacer/rt`
export, and the CLI's offline `pacer pack` workflow. No new language features
or wire-format changes are needed for this release.

**Dependency requirement: SJON 1.5.0 or newer.** Pin an exact qualifying
release/revision for reproducibility; do not resolve a floating latest version.

Publish the npm package publicly to the **npm registry** as the scoped name
**`@mr_hugo/pacer`**. The unscoped `pacer` name is already taken on npmjs, so
the scope is required; `publishConfig` sets `access: public`.
Source publication uses `https://github.com/HugoDaniel/pacer.git` as the
release remote (`git remote release`). Native CLI distribution defaults to
documented source builds with pinned inputs; prebuilt native downloads can
follow separately.

## Baseline findings

Observed locally on 2026-10-25; these are evidence from the assessment,
not substitutes for checks against the final release commit:

- Lint and TypeScript checking pass.
- `npm pack --dry-run --json` builds successfully and lists both WASM assets,
  JS sources, generated declarations, README and license. Reported packed size:
  359,046 bytes; unpacked size: 997,019 bytes. This was a dry run, not an
  installed-tarball smoke test.
- `zig build audit-diagnostics audit-rt-imports fuzz parity` exits successfully.
  Native parity reports 44 cases, zero failures and zero skips.
- The `zig build verify` Node leg reports 182 tests: 177 pass, three fail,
  two skip. The three failures are bundle tests: the sibling pngine's built
  `npm/pngine/dist/viewer.mjs` lacks `payloadsOf`, although its source exports
  it. The full verify gate has **not** been established green.
- SJON is an unpinned sibling path dependency. Browser proofs also depend on
  the sibling pngine checkout and its Playwright installation.
- No local release tags or tracked GitHub/Gitea CI workflows were found.
  Remote publication history and registry availability have not been checked.
- The latest production-delivery acceptance record closes Groups D/E with
  explicit QA qualifiers. Older README/strategy prose still says work is pending.
  See `plans/binary/06-production-delivery.md`, final dated closure.
- Assessment builds generated an untracked `zig-pkg/` directory. Decide its
  ignore/cache treatment; do not accidentally commit fetched dependencies.

## 1. Establish release inputs and availability

- [x] Check remote tags and registry versions. Confirm 0.1.0 is available;
  record any existing 0.2.0 publication and its dist-tag before making changes.
  Do not overwrite a published version or silently move an existing tag.
  Evidence: `git ls-remote --tags origin` returned no tags; Gitea `main` is
  `5face6f`. The release remote `release` is
  `https://github.com/HugoDaniel/pacer.git` (public, currently empty).
  `npm view @mr_hugo/pacer` returns 404 on npmjs, so `@mr_hugo/pacer@0.1.0`
  is available; the `@mr_hugo` scope is owned by npm user `mr_hugo`. No tag
  exists locally or remotely.
- [x] Confirm registry authentication and intended package visibility without
  printing tokens. Use the configured registry explicitly in read-only probes.
  Evidence: `npm whoami` against npmjs returns `mr_hugo`; the `@mr_hugo`
  scope owns existing packages. `publishConfig` sets `access: public` for the
  scoped package. The Gitea package registry is no longer the target (Forgejo
  returns 404 for npm `whoami`, and the source repo is private, so it was not
  suitable for a public install).
- [x] Record Pacer, SJON and pngine commit IDs and dirty status, exact Zig,
  Node and npm versions, plus the release host OS/architecture.
  Evidence: Pacer `5face6f` + the release working-tree changes; SJON
  `97e12f39d9e63d028aa9b124660cc4cfed4cc726` (v1.5.0, clean); pngine
  `e9aff0d` (four unrelated tracked edits: CONTRIBUTING.md, README.md,
  build.zig.zon, src/dsl_sjon/Compiler.zig). Zig 0.16.0, Node v26.12.0,
  npm 11.20.0, macOS 27.0.1 on arm64.
- [x] Make source builds repeatable: prefer a Zig dependency URL/hash pinned
  to SJON if practical; otherwise document and verify the exact sibling SJON
  revision and clone/build commands. Pin pngine's integration-test revision too.
  Evidence: URL pinning is not practical for this release (SJON is a path
  dependency with its own sibling dependencies); the documented sibling pin is
  `v1.5.0` / `97e12f39…`, now stated in README, `docs/cli.md` and the npm
  README. A source build from a fetched source archive plus a fresh SJON clone
  at that revision built `pacer` and packed the starter score byte-identically
  (see §4). pngine integration pin: `e9aff0d`.
- [x] Verify the pinned SJON version is **1.5.0 or newer**, using its package
  manifest and release tag/revision. Record that evidence and state the minimum
  in Pacer's source-build documentation. Run all release gates against that pin.
  Evidence: `../SJON/build.zig.zon` declares `.version = "1.5.0"`; tag `v1.5.0`
  points at `97e12f39…`, the checkout used for every gate.
- [x] Verify the chosen source distribution contains all files its documented
  build needs. In particular, review `build.zig.zon`'s `.paths`, which currently
  omits `tools`, `corpus` and `npm` even though build/test steps use them.
  Evidence: `.paths` now lists `tools`, `corpus`, `examples`, `docs`, the
  CHANGELOG and the explicit `npm/pacer` source/test/browser/tools files. A
  `zig fetch` of the candidate produced a 772-entry manifest with no
  `node_modules` or generated wasm/types; extracting it beside the pinned SJON
  and running `zig build cli` + `pacer pack` succeeded.
- [x] Rebuild pngine's JS bundle from the recorded checkout and confirm its
  public viewer exports `payloadsOf`. Preserve unrelated sibling changes;
  use an isolated checkout if required.
  Evidence: rebuilt `pngine/npm/pngine/dist/viewer.mjs` with
  `node scripts/bundle.cjs` at `e9aff0d`; `payloadsOf` is exported. The four
  unrelated tracked pngine edits were preserved untouched. The bundle gate now
  passes.

## 2. Prepare versions and documentation

- [x] Set 0.1.0 in `build.zig.zon`, `src/root.zig`,
  `npm/pacer/package.json`, and both root package-version entries in
  `npm/pacer/package-lock.json`. Keep npm dependency versions unchanged;
  select SJON separately under the minimum-version requirement above.
  Evidence: all four declarations and both lockfile entries are `0.1.0`;
  devDependency versions are unchanged (`@biomejs/biome ^2.5.0`,
  `typescript ^5.9.0`).
- [x] Run the existing version-lockstep test; check the lockfile separately.
  Evidence: `exports.test.js` lockstep test passes; the lockfile root and
  `packages[""]` versions both read `0.1.0`.
- [x] Write release notes describing the shipped APIs, `.pacb` packing,
  playback runtime, supported environments, registry install instructions,
  and known limitations. Avoid a 1.0 stability claim.
  Evidence: [`CHANGELOG.md`](../CHANGELOG.md).
- [x] Reconcile current README/status summaries with the latest dated plan
  closures. Preserve historical records; correct the current summary instead
  of rewriting past evidence.
  Evidence: README now states the delivered source-free names / pattern tracks
  / runtime-only export and carries the QA qualifiers; the stale "implementation
  pending" summary is replaced. `plans/00-strategy.md` gains the plan-15 row and
  its What's next pointer.
- [x] Document building and invoking the CLI, including `pacer pack`, from
  the pinned source inputs. Make clear that npm does not install a CLI binary.
  Evidence: README Quickstart and "Asking a score a question", `docs/cli.md`
  "Build from source", npm README "Playback runtime"/"Develop".
- [x] Carry forward relevant acceptance qualifiers; do not claim real Safari,
  real tab-hide behavior or PCM-content verification from the existing evidence.
  Evidence: CHANGELOG "Known limitations" and README "Delivery status" name all
  three, pointing at `plans/binary/06-production-delivery.md`.
- [x] Resolve generated `zig-pkg/` handling and review the complete diff.
  Evidence: `zig-pkg/` (and `.agent/` scratch) are now gitignored; the generated
  directory is untracked. The tracked diff is the version bump, the golden
  header refresh, the `.paths`/ignore changes, the CLI-golden scratch-dir fix,
  and documentation/release notes. No fetched dependency is staged.

## 3. Run release gates

Run from a clean checkout of the candidate commit with the recorded inputs.
Save commands, exit codes, summaries and full logs in the evidence record.

```sh
# Repository root
zig build verify
zig build audit-diagnostics audit-rt-imports fuzz parity

# npm/pacer
npm ci
npm run lint
npm run typecheck
npm test
npm run g5:test
npm run g5:prepare
npm run test:browser
```

- [x] All commands exit zero. Record test totals and explain each skip;
  required bundle/browser coverage must actually execute.
  Evidence: `zig build verify` exit 0, Build Summary 35/35 steps, native
  749/749 tests; Node 182 tests: 180 pass, 0 fail, 2 skip; golden CLI
  envelopes current; score docs current; corpus 44/44.
  `zig build audit-diagnostics audit-rt-imports fuzz parity` exit 0,
  Build Summary 26/26 steps, fuzz 397/397 tests, parity 44/44 with zero
  skips, diagnostic coverage and runtime-import allowlists green. `npm ci`, `npm run lint`,
  `npm run typecheck`, `npm test`, `npm run g5:test` (10/10),
  `npm run g5:prepare`, and `npm run test:browser` (10/10) all exit 0.
  The two Node skips are the frozen pre-SNAM artifact comparisons: the plan
  does not ship those historical binaries, and the tests self-skip loudly
  naming the missing artifact path. Required bundle coverage ran (all three
  bundle legs pass); required browser coverage ran (all 10 spec tests pass).
  The browser runner needed its Playwright Chromium install repaired on this
  host; the browser proof itself is green.
- [x] Confirm no golden corpus or generated score-reference drift and no
  unintended tracked changes from the gates.
  Evidence: after the gates, the only tracked changes are the release files
  below; `corpus/` and `docs/score-language.md` are untouched. The four
  `src/cli/testdata/*.json` diffs are the expected `0.2.0` → `0.1.0` version
  headers only, regenerated via `zig build cli-golden` and reviewed.
- [x] Confirm both shipped WASM files are freshly built from the recorded
  source/toolchain. Repeat with independent fresh build caches and compare
  SHA-256 digests; investigate any mismatch before proceeding.
  Evidence: two independent fresh-cache builds (separate local and global
  caches, separate prefixes) produced
  `pacer.wasm` `5a6d5316241f6c210970a652a1c030dfbc983f28855c2f9cafe773c365eb097a`
  (668,296 B) and `pacer-rt.wasm`
  `34fa25a7ed75eb8e050ac9d7e6064fc53d5d85fec5198ef9cd84e7cba74770d8`
  (189,321 B), both equal to the shipped copies and to the earlier Group E
  record.

## 4. Verify the distributable

- [x] Run a real `npm pack` from `npm/pacer`; retain the 0.1.0 tarball and its
  SHA-256 digest. Inspect its file list, version, exports, declarations,
  license and both WASM files. Exclude fixtures, credentials and local artifacts.
  Evidence: `mr_hugo-pacer-0.1.0.tgz`, SHA-256
  `cba5403f3d67e95021c0698d014cfa2ffa3b439ca7c758edb0a866e014ec96ed`
  (359,382 B). 35 entries: `src/*.js`, generated `types/*.d.ts` + maps,
  `pacer.wasm`, `pacer-rt.wasm`, README, LICENSE, package.json. No tests,
  fixtures, credentials or build scratch. Version/exports/license/repository
  inspected; `repository.url` is the GitHub release remote. A second
  `npm pack` run after a full `prepack` rebuild produced the same SHA-256.
- [x] Install that tarball in a fresh directory outside the repository.
  Resolve assets using the public package subpaths, not workspace paths.
  Evidence: fresh consumer under `$TMPDIR`; installed `@mr_hugo/pacer@0.1.0`;
  wasm read through `import.meta.resolve('@mr_hugo/pacer/pacer.wasm')` and
  `@mr_hugo/pacer/pacer-rt.wasm`; installed wasm digests equal the release
  digests.
- [x] Node smoke: compile a small score with `Pacer`, pack the same score
  through the documented CLI, load it through `PacerRt`, and compare writes
  at explicit sample times against independently chosen expected values.
  Evidence: compose-mode score with one declared target, keys 0.25 at 0b and
  0.75 at 4b at 120 bpm; independent expectations 0.25 / 0.5 / 0.75 at
  t = 0 / 1 / 2. `Pacer` and `PacerRt` (loaded from `pacer pack` output) both
  produced those f32 writes.
- [x] TypeScript smoke: type-check imports of the root and documented
  subpaths against the installed declarations.
  Evidence: strict `tsc --noEmit` consumer importing `pacer`, `pacer/rt`,
  `pacer/route`, `pacer/clock`, `pacer/audio`, `pacer/host-check` and their
  documented types passed.
- [x] Browser smoke: load the installed package's two WASM assets and exercise
  text and binary playback, checking diagnostics and console errors.
  Evidence: isolated HTTP webroot serving the installed package; headless
  Chromium via the pngine Playwright install. `Pacer` diagnostics empty;
  text and binary playback both wrote 0.25 / 0.5 / 0.75 at t = 0 / 1 / 2;
  zero console or page errors. Separately, the repo's G5 browser proof
  (`npm run test:browser`) is 10/10.
- [x] Verify the documented source-build/CLI path in a fresh checkout using
  only the recorded prerequisites.
  Evidence: extracted the `zig fetch` source archive into a fresh root,
  cloned SJON at `v1.5.0` / `97e12f39…`, then `zig build cli` and `pacer pack`
  on the starter score succeeded. The resulting cartridge SHA-256 matched the
  same pack from the candidate working tree
  (`9996d7765d832492fc67e5d296ae71a94baa16202be009cbd3482a6cab139136`).

## 5. Second review — stop here before publication

Review this checklist against the final candidate, not the assessment build.

- [x] Every item above has evidence or an explicitly accepted exception.
  Evidence: every §1–§4 item is checked; the npmjs scope, authentication and
  visibility are recorded in §1.
- [x] Version declarations, tarball version and release notes all say 0.1.0.
  Evidence: package.json / lockfile / build.zig.zon / root.zig, installed
  tarball, `npm pack` JSON and CHANGELOG all report `0.1.0`.
- [x] The candidate commit and dependency revisions are fixed; working trees
  are clean or unrelated changes are isolated and documented.
  **Evidence:** the candidate is the release commit on top of
  `5face6f`; no tag has been created (tagging belongs to §6 and waits for
  authorization). SJON is clean at the pin;
  pngine has four unrelated tracked edits, documented above and left alone.
- [x] The pinned SJON version is **1.5.0 or newer**, the documented minimum
  agrees, and the recorded gate results use that exact dependency revision.
- [x] All required native, Node, bundle and browser gates are green.
  Evidence: see §3. The only skips are the two optional frozen pre-SNAM
  artifact tests.
- [x] Fresh-build digests match and the actual tarball smoke tests pass.
- [x] Registry/version availability, visibility and authentication are verified.
  Evidence: `@mr_hugo/pacer` is absent on npmjs, the `mr_hugo` session is
  authenticated, and `publishConfig.access` is `public`.
- [x] Review the npm lifecycle: `prepublishOnly` runs lint/typecheck/tests;
  `prepack` rebuilds binaries/types. Ensure publication uses the reviewed
  artifact and does not substitute unchecked rebuilt bytes. Verify lifecycle
  behavior for the chosen publish command and npm version before using it.
  Evidence: npm 11.20.0 `npm publish --dry-run` runs `prepack` (which rebuilds
  both wasm files and types) but **skips** `prepublishOnly`; the normal
  `npm publish` path runs it, and `npm run lint` / `npm run typecheck` /
  `npm test` were run separately and are green. A dry-run publish of the
  reviewed tarball (`npm publish ./mr_hugo-pacer-0.1.0.tgz --dry-run`) runs
  no lifecycle scripts and uses those exact bytes. Recommended procedure:
  run the three checks, publish the reviewed tarball rather than a loose
  directory, and verify the registry digest after upload.
- [x] Record the final review outcome and owner authorization to publish.
  Evidence: the owner published `@mr_hugo/pacer@0.1.0` on 2026-10-25 at
  `19:51:20Z`. The review outcome above is superseded only on the source-tag
  alignment point, which is recorded in §6.

### Review outcome — 2026-10-25

**Released and verified.**
Every build, test, reproducibility and installed-consumer check above is green.
`@mr_hugo/pacer@0.1.0` is live on npmjs, the GitHub release is published, and a
fresh registry install passes the Node, TypeScript and browser smokes. The
`0.0.0-stage` placeholder has been removed; the release has no open items.

## 6. Publish and verify

Execute only after the second review is complete and publication is authorized.
Executed on 2026-10-25: npm publication, source tag alignment, GitHub
release, and staged-placeholder cleanup.

The source release remote is `release` →
`https://github.com/HugoDaniel/pacer.git`. The npm registry is
`https://registry.npmjs.org/`; the package is the scoped, public
`@mr_hugo/pacer`.

- [x] Commit the prepared release.
  Evidence: `0cc3003` (`release: prepare pacer 0.1.0`) plus the release-remote
  and scoped-package follow-ups, ending at `99e6c85` for the published bytes.
- [x] Tag the published source commit `v0.1.0`.
  Evidence: force-updated the tag from the pre-scope `678af2d` to `99e6c85`
  at the owner's explicit request. The old tag object was `bd7a2ba`; the new
  annotated tag object is `1ccefcb`, peeled to `99e6c85`.
- [x] Push the aligned `main` and `v0.1.0` to `release`.
  Evidence: `release/main` fast-forwarded `678af2d..0c4433c`; the tag was
  force-pushed. Remote peel: `v0.1.0^{}` = `99e6c85`.
- [x] Publish the verified npm artifact to the configured registry.
  Evidence: `@mr_hugo/pacer@0.1.0` published to npmjs at
  `2026-10-25T19:51:20.078Z`; integrity
  `sha512-6aTJ9h2mth9eYRk4UmeAZjDrQKuXiu7adkbkFqEqW2I4fhA2c4nOwc5PpIILbqA7oQG2cd0ana66GKg5g87gTw==`,
  tarball `https://registry.npmjs.org/@mr_hugo/pacer/-/pacer-0.1.0.tgz`.
- [x] Publish the GitHub release notes for `v0.1.0` with the source-build
  instructions and artifact digests. Attach standalone WASM artifacts if
  offering direct downloads.
  Evidence: https://github.com/HugoDaniel/pacer/releases/tag/v0.1.0,
  published `2026-10-25T20:51:34Z`, with the tarball and both wasm files
  attached.
- [x] Install `@mr_hugo/pacer@0.1.0` from the registry in a new consumer
  directory; verify resolved version, dist-tag, tarball integrity and both
  playback paths.
  Evidence: fresh registry install reported `@mr_hugo/pacer@0.1.0`; the
  downloaded tarball SHA-256 matches `cba5403f…14ec96ed`; Node, strict
  TypeScript and headless-browser smokes pass; wasm digests match the release.
- [ ] Record release URLs, publication time, final commit/tag and verification
  outcome here. If publication partially fails, record what succeeded before
  retrying; never reuse the version for different bytes.
  Evidence: recorded below. `@mr_hugo/pacer` now lists only `0.1.0`; the
  `0.0.0-stage` placeholder has been removed.

## Evidence record

Fill this in as execution proceeds. An unchecked item remains outstanding.

| Item | Result / evidence |
|---|---|
| Candidate Pacer commit / tag | `99e6c85`; annotated tag `v0.1.0` -> `1ccefcb` -> `99e6c85`; `release/main` carries the release record (see `git ls-remote release`) |
| Release remote | `release` → `https://github.com/HugoDaniel/pacer.git` (public, empty at preparation time) |
| SJON version (>=1.5.0) / revision / dependency hash | 1.5.0 / `97e12f39d9e63d028aa9b124660cc4cfed4cc726` / sibling path pin; `zig fetch` source hash `pacer-0.1.0-e0Ny2EFk9QGznZaQQKpWLeGrI57aw-HEPfFtil63ijwB` |
| pngine revision / bundle provenance | `e9aff0d`, bundle rebuilt with `node scripts/bundle.cjs`; viewer exports `payloadsOf`; four unrelated tracked edits preserved |
| Toolchain / host | Zig 0.16.0, Node v26.12.0, npm 11.20.0, macOS 27.0.1, arm64 |
| Remote tags / registry availability | No local/remote tags; Gitea `main` `5face6f`; GitHub release remote empty; `@mr_hugo/pacer` absent on npmjs; npm session is `mr_hugo` |
| Full gate logs / test totals / skip reasons | `zig build verify` 0: native 749/749, Node 182 (180 pass, 2 skip, 0 fail), corpus 44/44, CLI goldens/docs current. `audit-diagnostics audit-rt-imports fuzz parity` 0: parity 44/44. npm lint/typecheck/test 0; g5:test 10/10; test:browser 10/10. Skips: frozen pre-SNAM artifact absent (optional historical comparison). Logs in `.agent/release/` (gitignored). |
| Browser proof | G5 10/10; installed-tarball browser smoke: diagnostics empty, text+binary 0.25/0.5/0.75, zero console errors |
| WASM SHA-256 / repeat-build comparison | `pacer.wasm` `5a6d5316…f365eb097a`; `pacer-rt.wasm` `34fa25a7…cba74770d8`; two independent fresh-cache builds and both shipped copies agree |
| Tarball filename / SHA-256 / file manifest | `mr_hugo-pacer-0.1.0.tgz` / `cba5403f…14ec96ed` / 35 entries, listed in `.agent/release/scoped-tarball-files.txt` |
| Installed-tarball consumer checks | Node, strict TypeScript, and headless-browser smokes all pass outside the repo |
| Documentation / limitations review | README, npm README, `docs/cli.md`, CHANGELOG and `plans/00-strategy.md` updated; Safari/tab-hide/PCM qualifiers carried |
| Second review / exceptions / authorization | Complete: npm publication, tag alignment, GitHub release, and `0.0.0-stage` removal |
| Publication URLs / post-publish checks | npm `https://www.npmjs.com/package/@mr_hugo/pacer/v/0.1.0` (2026-10-25T19:51:20.078Z) and GitHub `https://github.com/HugoDaniel/pacer/releases/tag/v0.1.0` (2026-10-25T20:51:34Z). Integrity `sha512-6aTJ…87gTw==`; registry install + Node/TS/browser smokes pass. Tarball `cba5403f…14ec96ed`. |
