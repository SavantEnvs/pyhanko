#!/usr/bin/env python3
#
# mayhem/fuzz_pdf.py — v2 port of the mayhemheroes `fuzz-pdf` Atheris harness
# (mayhemheroes/pyHanko@cf07cbb6, mayhem/fuzz_pdf.py), reconstructed byte-for-byte for this
# backport (repro-4a33d05, mayhemheroes run 2: 5 relevant defects — 4x CWE-248 uncaught
# ValueError, 1x CWE-190 OverflowError, all raised out of PdfFileReader's own xref-parsing code).
# The current v2 harness for this repo (mayhem/fuzz_pdf_reader.py on the `mayhem` branch) treats
# ValueError/OverflowError as expected control flow for malformed input and would swallow exactly
# the exceptions this run found, so it cannot reproduce them — this harness restores the original
# input framing (one bool selects PdfFileReader vs IncrementalPdfFileWriter; the rest of the input
# is the whole PDF file body) and the original oracle (only pyhanko's own PdfError is expected;
# anything else, including these, is a genuine unhandled-exception defect).
import sys

import atheris
import fuzz_helpers

with atheris.instrument_imports(include=['pyhanko']):
    from pyhanko.pdf_utils.reader import PdfFileReader
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter

from pyhanko.pdf_utils.misc import PdfError


def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        with fdp.ConsumeMemoryFile(all_data=True, as_bytes=True) as f:
            if fdp.ConsumeBool():
                PdfFileReader(f)
            else:
                IncrementalPdfFileWriter(f)
    except PdfError:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
