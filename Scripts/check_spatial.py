#!/usr/bin/env python3
"""Run real SpatialCalibration async logic on macOS with controlled ARKit boundaries.

Requires the existing Xcode Swift toolchain; installs no dependencies. Hardware
tracking and actual ARKit persistence still require a Vision Pro test.
"""

from pathlib import Path
import argparse
import platform
import subprocess
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Reuse the PianoCore module from a recent shared build")
    args = parser.parse_args()
    package = root / "Packages" / "PianoShared"
    if not args.skip_build:
        subprocess.run(["swift", "build", "--package-path", str(package)], check=True, cwd=root)
    result = subprocess.run(["swift", "build", "--package-path", str(package), "--show-bin-path"],
                            capture_output=True, text=True, check=True, cwd=root)
    products = Path(result.stdout.strip().splitlines()[-1])
    if (products / "PianoCore.o").exists():
        include = products
        objects = [products / "PianoCore.o"]
    else:
        include = products / "Modules"
        objects = sorted((products / "PianoCore.build").glob("*.o"))
    if not objects:
        raise SystemExit("PianoCore objects not found. Run swift build first.")
    regression = root / "Scripts" / "Regression"
    production = (root / "Apps" / "PianoVision" / "Spatial" / "SpatialCalibration.swift").read_text()
    for framework in ("ARKit", "RealityKit"):
        production = production.replace(f"import {framework}\n", "")
    sources = [
        (regression / "SpatialMock" / "ARKitStubs.swift").read_text(),
        (regression / "SpatialMock" / "RealityKitStubs.swift").read_text(),
        production,
        (regression / "SpatialCalibrationRegression.swift").read_text(),
    ]
    with tempfile.TemporaryDirectory(prefix="piano-spatial-regression-") as temporary:
        directory = Path(temporary)
        source = directory / "SpatialCalibrationRegression.swift"
        binary = directory / "spatial-regression"
        source.write_text("\n\n".join(sources))
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            "-target", f"{platform.machine()}-apple-macos15.0", "-I", str(include),
            *map(str, objects), str(source), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
