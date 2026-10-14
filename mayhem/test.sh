#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the pre-fix commit's OWN pytest modules (deps already installed by
# mayhem/build.sh) and emit a CTRF (ctrf.io) summary. exit 0 iff failed==0.
#
# Scope: pdfstamp_tests/test_utils.py (pdf_utils object model, reader, writer, filters),
# test_text.py and test_barcode.py; each asserts concrete values (parsed objects, golden bytes,
# raised exception types), so a neutered build fails it. test_signing.py cannot be collected on
# the base image (its module-level PKCS#12 fixture needs RC2, which this OpenSSL lacks), and two
# tests fail on today's fonttools / python-barcode APIs; those two are deselected BY NAME and
# counted as skipped. Anything else failing still fails the run.
#
# It does NOT compile. It is routed through the compiled NON-system pyhanko_run_tests ELF wrapper so
# the gate's sabotage check (neuter non-system binaries to exit(0)) actually perturbs the run.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"
cd "$SRC"

# Put the in-image site dir (atheris/pytest/test deps), and the checkout
# on PYTHONPATH.
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
  pdfstamp_tests/test_utils.py
  pdfstamp_tests/test_text.py
  pdfstamp_tests/test_barcode.py
)
KNOWN_FAILING=(
  pdfstamp_tests/test_utils.py::test_embed_subset
  pdfstamp_tests/test_barcode.py::test_code128_render
)
DESELECT=()
for t in "${KNOWN_FAILING[@]}"; do DESELECT+=(--deselect "$t"); done

LOG="$(mktemp)"
"$RUNNER" -p no:cacheprovider -o addopts= -o log_cli=false -q "${DESELECT[@]}" "${TESTS[@]}" 2>&1 | tee "$LOG"
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

skipped=$(( skipped + ${#KNOWN_FAILING[@]} ))
emit_ctrf "pytest" "$passed" "$failed" "$skipped"
