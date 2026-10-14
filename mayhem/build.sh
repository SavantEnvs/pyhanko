#!/usr/bin/env bash
#
# mayhem/build.sh — build the pdf_utils/pdfstamp Atheris fuzz harness + its standalone reproducer,
# and prepare the pre-fix commit's own pytest modules. Runs inside the commit image
# (mayhem/Dockerfile) as `mayhem` in /mayhem; idempotent and air-gapped on re-run.
#
# This is the MINING layer on the commit before upstream's collect_indirect_references fix: the
# code lives in the old top-level `pdf_utils` / `pdfstamp` packages, used straight from the
# checkout on PYTHONPATH, plus the `certvalidator` fork its requirements.txt pins, vendored in
# mayhem/vendor/. Third-party deps go in a wheelhouse + site dir under /opt/toolchains/python.
#
# The launcher is compiled so Mayhem gets an ELF cmd (DWARF < 4) that execs python on the Atheris
# harness; a second ELF runs pytest so the gate's sabotage check bites the test oracle.
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

# 1) Wheelhouse: download every runtime/test dependency ONCE (online); atheris ships a prebuilt
#    wheel for this CPython. oscrypto >= 1.3.0 is needed to load libcrypto of OpenSSL 3.
PKGS=(
  atheris pytest freezegun requests-mock pyyaml
  asn1crypto pytz tzlocal "oscrypto>=1.3.0" requests
  qrcode fonttools click python-barcode ocspbuilder crlbuilder pillow
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

# pdf_utils / pdfstamp (the checkout) and the vendored certvalidator stay plain source trees on
# PYTHONPATH. $SITE comes first so the wheelhouse-installed packages win over system ones.
PYRUN="$SITE:$SRC/mayhem/vendor:$SRC"

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, pytest; from pdf_utils.reader import PdfFileReader; from pdfstamp.sign import fields, validation; print("imports OK:", PdfFileReader, validation.EmbeddedPdfSignature)'

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits
#    at run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + pdf_utils.
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
