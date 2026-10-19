#!/bin/sh
# Pin the `pacer` CLI's JSON envelopes.
#
#   tools/cli_golden.sh <path-to-pacer-cli> [--update]
#
# Default mode CHECKS: it re-renders each case to a temp file and diffs
# against the committed golden, failing if they differ (this is the leg
# `zig build verify` depends on). `--update` writes the goldens instead.
# Both go through the same render, so the gate compares what the verb
# would actually produce.
#
# WHY a golden on top of the in-process tests: those check shape and rules
# one assertion at a time. A golden checks the WHOLE envelope in one
# reviewable diff, and catches a reshuffle nothing happened to assert.
#
# These live in `src/cli/testdata/`, deliberately NOT in `corpus/`. That
# directory's contract is native == wasm byte for byte; the CLI is
# native-only and makes no parity claim, so mixing them would dilute a
# gate whose sharpness is the whole point.
#
# The argv for each case lives HERE and nowhere else. `examples/
# starter.score.sjon` is the fixture because it is already gate-pinned by
# `corpus/examples-starter` and exercises every track source, a scene, a
# tempo map, a control and three easing combinators — so a CLI golden and
# a corpus golden move together on one edit, and both diffs get reviewed.
set -eu

PACER="${1:?usage: cli_golden.sh <pacer-cli> [--update]}"
MODE="${2:-check}"
DIR="src/cli/testdata"

# The host registries `examples/index.html` provides, mirroring
# `corpus/examples-starter/times.sjon` exactly — a rename on either side
# fails here as well as there.
# One token per line: the splitter below uses newline as IFS, so a flag
# and its value are separate lines.
STARTER="examples/starter.score.sjon
--target
circle-radius
--target
circle-x
--target
circle-y
--target
tint:3
--target
flash:4
--target
spark
--target
master-gain:1:1
--target
click:4:1"

status=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# run_case <golden-name> <expected-exit> <newline-separated argv>
run_case() {
    name=$1
    want_exit=$2
    golden="$DIR/$name.json"

    # Split argv on newlines so a case can carry many flags readably.
    old_ifs=$IFS
    IFS='
'
    # shellcheck disable=SC2086
    set -- $3
    IFS=$old_ifs

    got_exit=0
    "$PACER" "$@" >"$tmp" 2>/dev/null || got_exit=$?
    if [ "$got_exit" -ne "$want_exit" ]; then
        echo "cli-golden: $name: exit $got_exit, expected $want_exit" >&2
        status=1
        return
    fi

    if [ "$MODE" = "--update" ]; then
        cp "$tmp" "$golden"
        echo "cli-golden: wrote $golden"
        return
    fi
    if [ ! -f "$golden" ]; then
        echo "cli-golden: $golden is missing — \`zig build cli-golden\` writes it" >&2
        status=1
        return
    fi
    if ! diff -u "$golden" "$tmp"; then
        echo "cli-golden: $golden is stale — \`zig build cli-golden\` regenerates it (review the diff)" >&2
        status=1
    fi
}

run_case starter-ir 0 "ir
$STARTER"

# Sampled across the loop: 0 and 0.5 s inside the first tempo segment, 4 s
# ON the segment boundary and the `drop` scene's opening, and 7 s which is
# `:dur` exactly and wraps to tick 0. `--set` pins the override path.
run_case starter-eval 0 "eval
$STARTER
--at
0
--at
0.5
--at
4
--at
7
--set
sway-amt=0.2"

# A defective score: the envelope must stay complete and parseable, and
# the exit code must be 1.
run_case controls-check 1 "check
corpus/diag-controls/doc.sjon
--target
tint:3
--json"

# A pack REFUSAL: starter's :pattern track cannot pack in v1 — the
# envelope stays complete, `pack` rides as null, and the refusal is an
# ordinary pacer diagnostic in score coordinates. The --out under
# .agent/control/tmp is never written: a refusal lands nothing.
run_case starter-pack 1 "pack
$STARTER
--out
.agent/control/tmp/starter-pack.pacb"

if [ "$status" -eq 0 ] && [ "$MODE" != "--update" ]; then
    echo "cli-golden: CLI envelopes are current"
fi
exit "$status"
