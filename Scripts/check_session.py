#!/usr/bin/env python3
"""Run app-session MIDI regressions against the real model without a visionOS runtime."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/PianoShared"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true", help="Reuse libraries just built by swift test")
args = parser.parse_args()
if not args.skip_build:
    subprocess.run(["swift", "build", "--package-path", str(PACKAGE)], check=True, cwd=ROOT)
result = subprocess.run(["swift", "build", "--package-path", str(PACKAGE), "--show-bin-path"],
                        capture_output=True, text=True, check=True, cwd=ROOT)
products = Path(result.stdout.strip().splitlines()[-1])
names = ("PianoCore", "PianoLink")
if all((products / f"{name}.o").exists() for name in names):
    include = products
    objects = [products / f"{name}.o" for name in names]
else:
    include = products / "Modules"
    objects = [obj for name in names for obj in sorted((products / f"{name}.build").glob("*.o"))]
if not objects:
    raise SystemExit("Shared library objects not found. Run swift build first.")
with tempfile.TemporaryDirectory(prefix="pianovision-session-") as temporary:
    executable = Path(temporary) / "PianoSessionRegression"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(include),
                    *map(str, objects), str(ROOT / "Apps/PianoVision/PianoSession.swift"),
                    str(ROOT / "Apps/PianoVision/PracticeSettings.swift"),
                    str(ROOT / "Scripts/Regression/SpatialCalibrationStub.swift"),
                    str(ROOT / "Scripts/Regression/PianoSessionRegression.swift"),
                    "-o", str(executable)], check=True, cwd=ROOT)
    subprocess.run([str(executable), str(Path(temporary) / "libraries"), str(ROOT / "Samples/FirstSteps.mid")], check=True, cwd=ROOT)
