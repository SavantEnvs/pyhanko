#!/usr/bin/env python3
#
# mayhem/fuzz_pdf_reader.py — Atheris harness for pyHanko's low-level PDF object-model
# reader (pyhanko.pdf_utils.reader.PdfFileReader). This is the entry point every higher-level
# pyHanko feature (signature validation, incremental-update parsing, form filling, ...) sits on
# top of, so it is the natural fuzz surface for a net-new port of a PDF-signing/validation
# library: feed raw bytes in as a whole PDF file body, no real file I/O beyond an in-memory
# BytesIO (SPEC/netnew-worker-prompt §3 — the harness must not touch the filesystem).
#
# The fuzzer input is split into one control byte (selects `strict` mode — pyHanko's reader has
# two materially different code paths depending on this flag) plus the remaining bytes, which are
# fed verbatim as the PDF body. After constructing the reader (which alone parses the header,
# xrefs and trailer), a few cheap, read-only accessors are exercised to walk further into the
# object graph (root/pages/metadata/version) without doing anything unbounded.
import sys
from io import BytesIO

import atheris
import fuzz_helpers

with atheris.instrument_imports():
    from pyhanko.pdf_utils import misc as pdf_misc
    from pyhanko.pdf_utils.reader import PdfFileReader

# Exceptions that pyHanko's own reader raises (or lets bubble up from binary/text parsing of
# untrusted, syntactically-malformed input) to signal "this is not a valid/well-formed PDF" —
# these are the parser's normal control flow for garbage input, not defects. Left uncaught (and
# therefore genuine Mayhem findings): AssertionError, AttributeError, MemoryError and anything
# else not explicitly named here.
EXPECTED_EXCEPTIONS = (
    pdf_misc.PdfError,  # PdfReadError, PdfStrictReadError, PdfStreamError, ...
    ValueError,
    IndexError,
    KeyError,
    TypeError,
    UnicodeDecodeError,
    OverflowError,
    LookupError,
    EOFError,
    # A maliciously deep nesting of arrays/dicts/xref chains hits Python's recursion limit fast
    # and uninterestingly on almost any random input; treat it like the "guard the hang
    # precondition narrowly" guidance for interpreters (netnew-worker-prompt §6b) so real findings
    # aren't drowned out by one recursion-depth report per fuzz exec.
    RecursionError,
)


def TestOneInput(data):
    if not data:
        return
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    strict = fdp.ConsumeBool()
    pdf_bytes = fdp.ConsumeRemainingBytes()

    try:
        reader = PdfFileReader(BytesIO(pdf_bytes), strict=strict)

        # Walk a bit further into the object graph. Each accessor is independently guarded so a
        # failure in one (e.g. a malformed /Root) doesn't skip exercising the others.
        try:
            root = reader.root
        except EXPECTED_EXCEPTIONS:
            root = None

        try:
            _ = reader.trailer_view
        except EXPECTED_EXCEPTIONS:
            pass

        try:
            _ = reader.input_version
        except EXPECTED_EXCEPTIONS:
            pass

        try:
            _ = reader.document_meta_view
        except EXPECTED_EXCEPTIONS:
            pass

        try:
            _ = reader.encrypt_dict
        except EXPECTED_EXCEPTIONS:
            pass

        if root is not None:
            try:
                pages = root['/Pages']
                # Touch a couple of shallow, cheap fields — do NOT recurse the page tree
                # ourselves (an attacker-controlled kid-count/depth is exactly the kind of thing
                # that belongs to the library to bound, not the harness to hand-walk unbounded).
                _ = pages.get('/Count')
                _ = pages.get('/Kids')
            except EXPECTED_EXCEPTIONS:
                pass
    except EXPECTED_EXCEPTIONS:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
