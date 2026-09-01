#!/usr/bin/env bash
#
# mayhem/build.sh — build the pyhanko Atheris fuzz harness + its standalone reproducer, and
# prepare pyHanko's own test suite. Runs inside the commit image (mayhem/Dockerfile) as `mayhem`
# in /mayhem. Python adaptation of the C/C++ template (see astpretty/mayhem/build.sh for the
# single-module-package version of this same shape).
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + pyHanko's third-party runtime deps + a scoped slice of its own
#      pytest deps OFFLINE from that wheelhouse into a fixed site dir on PYTHONPATH. The first
#      (CI, online) build fills the wheelhouse; the air-gapped PATCH re-run resolves entirely
#      from it (pip --no-index --find-links).
#   2. `pyhanko` and `pyhanko-certvalidator` themselves are NOT pip-installed — this checkout is
#      a uv workspace monorepo and those packages exist only as pkgs/*/src source trees with no
#      built distribution here (pyproject.toml pins them as `{ workspace = true }` sources, not
#      PyPI releases). Put pkgs/pyhanko/src, pkgs/pyhanko-certvalidator/src (runtime) and
#      internal/common-test-utils/src (test-only fixtures) directly on PYTHONPATH instead — this
#      also means a PATCH agent's edits to the source tree take effect with no reinstall.
#   3. Compile launcher.c -> the ELF Mayhem target `pyhanko_fuzzer` (Atheris is a Python script;
#      Mayhem needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper).
#   4. Build the same launcher as the standalone (run-once) reproducer `pyhanko_fuzzer-standalone`.
#   5. Compile the pytest ELF runner wrapper `pyhanko_run_tests` (so the sabotage oracle bites).
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). We only need
# DEBUG_FLAGS here (the launcher is a thin C exec wrapper — sanitizing it would just instrument the
# wrapper, not the fuzzed Python; Atheris instruments the pyhanko.pdf_utils modules at import time).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

# 1) Wheelhouse: download every runtime/test dependency ONCE (online). atheris ships a prebuilt
#    manylinux wheel for this CPython. The rest are pyHanko's own third-party runtime deps
#    (asn1crypto/tzlocal/cryptography/aiohttp/lxml for pyhanko itself; oscrypto/uritools/certifi/
#    requests additionally for pyhanko-certvalidator) plus the test-only deps needed to RUN a
#    scoped slice of pyHanko's own pytest suite offline (pytest/pytest-asyncio/pytest-aiohttp,
#    freezegun, certomancer[web-api-async] (offline mock-CA cert generation used by the test
#    fixtures — no network), requests-mock, pyyaml — see mayhem/test.sh for exactly which test
#    modules this covers and why).
PKGS=(
  atheris pytest pytest-asyncio pytest-aiohttp freezegun
  "certomancer[web-api-async]" requests-mock pyyaml
  asn1crypto tzlocal cryptography aiohttp lxml
  oscrypto uritools certifi requests
)
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). Idempotent: once the
#    site dir holds atheris+pytest we SKIP the reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','pytest')) ) else 1)"; then
  echo ">> deps already installed in $SITE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi

# pyhanko / pyhanko-certvalidator / the test fixtures package stay editable source trees on
# PYTHONPATH (see header comment). Order matters only in that $SITE must come first so the
# wheelhouse-installed atheris/pytest/etc. are found before anything of the same name on the
# base image's system site-packages.
PYRUN="$SITE:$SRC/pkgs/pyhanko/src:$SRC/pkgs/pyhanko-certvalidator/src:$SRC/internal/common-test-utils/src"

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, pytest; from pyhanko.pdf_utils.reader import PdfFileReader; print("imports OK: pyhanko.pdf_utils.reader.PdfFileReader =", PdfFileReader)'

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits
#    at run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + pyhanko.
HARNESS="$SRC/mayhem/fuzz_pdf_reader.py"
echo ">> compiling pyhanko_fuzzer (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pyhanko_fuzzer"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when the
# harness is given a file path (no fuzzing loop), which is exactly the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pyhanko_fuzzer-standalone"

# 4) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's anti-reward-hack
#    sabotage check (which neuters non-system binaries to exit(0)) actually bites the suite — a
#    test.sh that shelled straight to the /usr/bin python would be spared and look reward-hackable.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/pyhanko_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/pyhanko_fuzzer" "$SRC/pyhanko_fuzzer-standalone" "$SRC/pyhanko_run_tests"
