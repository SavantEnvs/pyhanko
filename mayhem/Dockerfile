# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — PYTHON target (pyhanko / pyHanko, PDF signing & validation library).
# Builds ON TOP of the org C/C++ base (ghcr.io/savantenvs/base) — the base already ships CPython +
# pip + clang (clang links the compiled ELF launcher that drives the Atheris harness). This adds
# an in-image Python wheelhouse + site dir under /opt/toolchains/python (so the air-gapped PATCH
# re-run resolves atheris/pytest/pyHanko's runtime+test deps offline) and runs mayhem/build.sh.
#
# pyHanko is a monorepo (uv workspace): the actual `pyhanko` and `pyhanko-certvalidator`
# packages live under pkgs/*/src as PEP 420 namespace/src-layout trees with NO built distribution
# in this checkout, so we put those source trees directly on PYTHONPATH (editable) rather than
# `pip install` them — this also means a PATCH agent's edits to pkgs/pyhanko/src/... take effect
# immediately with no reinstall step. Everything else (cryptography, lxml, aiohttp, atheris,
# pytest, certomancer, ...) is a normal third-party dependency resolved via the wheelhouse.
#
# WHY a fixed /opt/toolchains/python prefix (SPEC §6.2 items 8/9, §6.5):
#   pip's default cache/user-site live under $HOME. The commit build and the PATCH RL re-run use
#   DIFFERENT $HOMEs, so anything left at the default would vanish under the re-run identity. We
#   pin the wheelhouse + installed site dir at FIXED, $HOME-independent paths so (a) they lock
#   uniformly and (b) the wheelhouse the FIRST (online) build fills is found again — by the SAME
#   absolute path — when build.sh re-runs OFFLINE at the PATCH tier.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never an ENV (an empty value breaks clang).
ARG SOURCE_DATE_EPOCH
# Sanitizer override (the launcher is a thin exec wrapper; Atheris instruments the Python at import).
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# ── Python toolchain caches at a FIXED, lockable, $HOME-independent prefix ─────
# The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): they must read the
# interpreter and read/refresh the wheelhouse + site dir, so hand the prefix to 2000. PYTHONPATH is
# baked as ENV so the fuzz target's exec'd python (and test.sh) find atheris + pyhanko at run time.
ENV PY_PREFIX=/opt/toolchains/python \
    PYTHONPATH=/opt/toolchains/python/site:/mayhem/pkgs/pyhanko/src:/mayhem/pkgs/pyhanko-certvalidator/src:/mayhem/internal/common-test-utils/src:/mayhem \
    PYTHONDONTWRITEBYTECODE=1
USER root
RUN install -d -o 2000 -g 2000 /opt/toolchains/python
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates the wheelhouse (online, this first build), installs deps offline into the site dir, and
# compiles the ELF launcher + standalone reproducer + the pytest-runner wrapper.
RUN bash mayhem/build.sh

# Run the project's functional tests at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
