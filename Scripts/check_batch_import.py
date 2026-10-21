#!/usr/bin/env python3
"""Compile and run the actual Mac batch-import model without a SwiftUI window."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/PianoShared"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true", help="Reuse an already-built PianoLink module")
args = parser.parse_args()
if not args.skip_build:
    subprocess.run(["swift", "build", "--package-path", str(PACKAGE)], check=True, cwd=ROOT)
result = subprocess.run(["swift", "build", "--package-path", str(PACKAGE), "--show-bin-path"],
                        capture_output=True, text=True, check=True, cwd=ROOT)
products = Path(result.stdout.strip().splitlines()[-1])
aggregate = products / "PianoLink.o"
if aggregate.exists():
    include, objects = products, [aggregate]
else:
    include = products / "Modules"
    objects = sorted((products / "PianoLink.build").glob("*.o"))
if not objects:
    raise SystemExit("PianoLink objects not found. Run swift build first.")
with tempfile.TemporaryDirectory(prefix="pianovision-batch-") as temporary:
    executable = Path(temporary) / "MIDIBatchImportRegression"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(include),
                    *map(str, objects), str(ROOT / "Apps/PianoBridge/MIDIBatchImportModel.swift"),
                    str(ROOT / "Scripts/Regression/MIDIBatchImportRegression.swift"),
                    "-o", str(executable)], check=True, cwd=ROOT)
    subprocess.run([str(executable), str(Path(temporary) / "fixtures")], check=True, cwd=ROOT)
