#!/usr/bin/env python3
#
# mayhem/fuzz_pdf_reader.py — Atheris harness for the old (pre-pyhanko-package) layout of
# pdf-stamp/pyHanko: pdf_utils.reader.PdfFileReader, then the signature integrity analysis
# (pdfstamp.sign.validation.EmbeddedPdfSignature), which walks the object graph of every
# incremental update made after a signature (HistoricalResolver.collect_indirect_references).
#
# The fuzzer input is the whole PDF file, byte for byte: signature coverage depends on the exact
# file length, so no control bytes are carved off it.
import sys
from io import BytesIO

import atheris

with atheris.instrument_imports(include=['pdf_utils', 'pdfstamp']):
    from pdf_utils import misc as pdf_misc
    from pdf_utils.reader import PdfFileReader
    from pdfstamp.sign import fields
    from pdfstamp.sign.validation import EmbeddedPdfSignature

# Exceptions the parser raises for malformed input. AssertionError, AttributeError, MemoryError
# and RecursionError during the signature analysis are left uncaught: they are findings.
EXPECTED_EXCEPTIONS = (
    pdf_misc.PyPdfError,
    ValueError,
    IndexError,
    KeyError,
    TypeError,
    UnicodeDecodeError,
    OverflowError,
    LookupError,
    EOFError,
)

MAX_SIGNATURES = 3


def TestOneInput(data):
    if not data:
        return

    # Stage 1: parse. Deeply nested garbage hits the recursion limit on almost any input, so
    # RecursionError is not interesting here.
    try:
        reader = PdfFileReader(BytesIO(data))
        _ = reader.root
    except EXPECTED_EXCEPTIONS + (RecursionError,):
        return -1

    # Stage 2: signature integrity analysis (coverage + what changed after the signature).
    try:
        count = 0
        for _name, sig_value, _field_ref in fields.enumerate_sig_fields(
            reader, filled_status=True
        ):
            emb_sig = EmbeddedPdfSignature(reader, sig_value)
            emb_sig.compute_integrity_info()
            count += 1
            if count >= MAX_SIGNATURES:
                break
    except EXPECTED_EXCEPTIONS:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
