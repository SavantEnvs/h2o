#!/usr/bin/env bash
#
# h2o: RUNS the upstream C unit suite (t/00unit, picotest/TAP, ~4k known-answer assertions across
# hpack/qpack/url/http1/http2/headers/etc.) built by mayhem/build.sh with normal flags.
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

UT=build/normal/t-00unit-evloop.t
[ -x "$UT" ] || { echo "missing $UT — mayhem/build.sh should have built it" >&2; emit_ctrf "picotest" 0 1 0; exit 1; }

OUTFILE="$(mktemp)"
trap 'rm -f "$OUTFILE"' EXIT
"$UT" >"$OUTFILE" 2>&1
rc=$?
tail -n 5 "$OUTFILE"

passed=$(grep -cE '^ *ok [0-9]+' "$OUTFILE" || true)
failed=$(grep -cE '^ *not ok [0-9]+' "$OUTFILE" || true)
skipped=$(grep -ciE '^ *ok [0-9]+.*# *skip' "$OUTFILE" || true)
passed=$(( passed - skipped ))

# A run that produced no TAP assertions (e.g. the binary was neutered) or exited non-zero is a failure.
[ "$rc" -eq 0 ] || failed=$(( failed + 1 ))
[ $(( passed + failed )) -gt 0 ] || failed=1
# picotest ends with a top-level plan line "1..N" that must equal the number of top-level results.
top=$(grep -cE '^(not )?ok [0-9]+' "$OUTFILE" || true)
plan=$(grep -E '^1\.\.[0-9]+$' "$OUTFILE" | tail -n 1 | cut -d. -f3)
[ -n "$plan" ] && [ "$plan" -eq "$top" ] || failed=$(( failed + 1 ))

emit_ctrf "picotest" "$passed" "$failed" "$skipped"
