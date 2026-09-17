#!/usr/bin/env bash
#
# mayhem/test.sh — RUN a scoped slice of pyHanko's OWN test suite (deps already installed by
# mayhem/build.sh) and emit a CTRF (ctrf.io) summary. exit 0 iff failed==0.
#
# Scope: pyHanko's full pyhanko_tests/ tree exercises the whole library (signing, PKCS#11
# hardware tokens, CSC remote signing, AdES/trust-list validation against live-looking HTTP
# fixtures, ...) — most of that is orthogonal to the code this port actually fuzzes. We run the
# test modules that directly assert the behavior of pyhanko.pdf_utils — the package
# mayhem/fuzz_pdf.py fuzzes (reader/xref/generic object-model parsing plus the writer/content
# layers built on it). BACKPORT NOTE (repro-4a33d05): at this historical commit pdf_utils.crypt's
# PDF-MAC filters and the standalone content-stream-parser/internal-utils test modules the live
# mayhem/test.sh runs don't exist yet — test_utils.py (generic.py object model, extensions,
# content streams, misc helpers) covers that ground here instead:
#   test_xref.py   — PdfFileReader / IncrementalPdfFileWriter / xref-table behavior
#   test_utils.py  — generic.py object model, extensions, content streams, misc helpers
#   test_crypt.py  — pdf_utils.crypt (standard + pubkey security handlers)
# All three assert concrete values (parsed object contents, decrypted plaintext, golden byte
# offsets, raised-exception types) via pytest's own assertions — not just "the process exited 0"
# — so a no-op/neutered PATCH fails this oracle (anti-reward-hacking, SPEC §6.3). None of them
# touch PKCS#11 hardware, a CSC remote-signing service, or real network.
#
# It does NOT compile — build.sh installed pytest + the runtime/test deps into the in-image site
# dir already. We only RUN the suite. It is routed through the compiled NON-system
# pyhanko_run_tests ELF wrapper so the gate's sabotage check (neuter non-system binaries to
# exit(0)) actually perturbs the run (the CPython interpreter under /usr/bin would otherwise be
# spared, since it's a "system" binary the shim leaves alone).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"
cd "$SRC"

# Put the in-image site dir (atheris/pytest/test deps) and the repo root (pyhanko + pyhanko_tests,
# a flat package at this historical commit) on PYTHONPATH.
PY_PREFIX=/opt/toolchains/python
# shellcheck disable=SC1091
[ -f "$PY_PREFIX/env.sh" ] && source "$PY_PREFIX/env.sh"
export PYTHONPATH="$PY_PREFIX/site:$SRC${PYTHONPATH:+:$PYTHONPATH}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

RUNNER="$SRC/pyhanko_run_tests"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing/not executable — mayhem/build.sh must build it first" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

TESTS=(
  pyhanko_tests/test_xref.py
  pyhanko_tests/test_utils.py
  pyhanko_tests/test_crypt.py
)

LOG="$(mktemp)"
# test_date_parsing / test_parse_datetime assert pytz's 'EST'/'CET' bare-abbreviation offsets,
# which the base image's current IANA tzdata resolves to a pre-1883 LMT offset (e.g. -05:18)
# instead of the fixed -05:00/+01:00 these tests were written against in 2023 — a tzdata-version
# drift unrelated to the pdf_utils reader/xref/generic code this backport fuzzes (BACKPORT.md:
# "old code x current toolchain").
"$RUNNER" -p no:cacheprovider -o addopts= -m "not hsm" \
    -k "not test_date_parsing and not test_parse_datetime" -q "${TESTS[@]}" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Parse pytest's summary line, e.g. "316 passed, 2 skipped in 12.4s" / "1 failed, 315 passed in ...".
line="$(grep -E '^(=+ )?[0-9].*(passed|failed|error|skipped)' "$LOG" | tail -1)"
get() { echo "$line" | grep -oE "[0-9]+ $1" | grep -oE '^[0-9]+' | head -1; }
passed="$(get passed)";  passed="${passed:-0}"
failed="$(get failed)";  failed="${failed:-0}"
errors="$(get error)";   errors="${errors:-0}"
skipped="$(get skipped)"; skipped="${skipped:-0}"
rm -f "$LOG"

# pytest errors (collection/setup) count as failures for the oracle.
failed=$(( failed + errors ))

# If pytest itself could not run (rc!=0 and no parseable counts), report a failure.
if [ "$(( passed + failed + skipped ))" -eq 0 ] && [ "$rc" -ne 0 ]; then
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$skipped"
