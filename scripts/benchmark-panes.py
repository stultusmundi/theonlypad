#!/usr/bin/env python3
"""Run disposable visible synthetic children. Preserve every failure/timeout and raw partial sample."""
import argparse
import json
import math
from pathlib import Path
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path)
    parser.add_argument("--mode", choices=("smoke", "full"), default="smoke")
    args = parser.parse_args()
    root = args.run_directory.resolve()
    allowed = Path(__file__).resolve().parent.parent / ".local" / "pane-benchmarks"
    if not root.is_relative_to(allowed.resolve()) or not root.is_dir():
        parser.error("run_directory must be an existing private .local/pane-benchmarks directory")
    for name in ("pane-performance", "swift-version.txt", "source-commit.txt", "source-sha256.txt"):
        if not (root / name).is_file() or (root / name).is_symlink():
            parser.error(f"missing or unsafe prepared artifact: {name}")
    smoke = args.mode == "smoke"
    results = []
    matrix_start = time.monotonic()
    for size in ((1_000_000,) if smoke else (1_000_000, 10_000_000, 100_000_000)):
        for fixture in (("multiline",) if smoke else ("multiline", "longline")):
            for count, axis in ((1, "sideBySide"), (2, "sideBySide"), (2, "stacked")):
                name = f"{size}-{fixture}-{count}-{axis}"
                record = dict(fixture=name, timeoutSeconds=120, samplesRequested=20)
                started = time.monotonic()
                with (root / f"{name}.json").open("wb") as output, (root / f"{name}.stderr").open("wb") as errors:
                    try:
                        child = subprocess.run(
                            [str(root / "pane-performance"), str(size), fixture, str(count), axis,
                             "20", str(root / "swift-version.txt")],
                            stdout=output, stderr=errors, timeout=120,
                        )
                        record["exitCode"] = child.returncode
                        record["status"] = "passed" if child.returncode == 0 else "failed"
                    except subprocess.TimeoutExpired:
                        # subprocess.run kills and waits for this exact owned child on expiry.
                        record["status"] = "timeout"
                record["elapsedSeconds"] = time.monotonic() - started
                if record["status"] == "passed":
                    report = json.loads((root / f"{name}.json").read_text())
                    record["observations"] = len(report["samples"])
                    for field in ("editSeconds", "undoSeconds", "resizeSeconds", "wrapToggleSeconds"):
                        values = sorted(sample[field] for sample in report["samples"])
                        record[field] = dict(median=statistics.median(values),
                                             empiricalNearestRankP95=values[math.ceil(.95 * len(values)) - 1],
                                             maximum=max(values))
                    record["peakRSSBytes"] = max(sample["peakRSSBytes"] for sample in report["samples"])
                results.append(record)
                summary = dict(mode=args.mode, elapsedSeconds=time.monotonic() - matrix_start, cases=results)
                (root / f"{args.mode}.json").write_text(json.dumps(summary, indent=2) + "\n")
                print(name, record["status"], flush=True)
    print("Raw artifacts:", root)
    print("Adapter stress only; two panes above 2M UTF16 bypass the app guard. 1GB is not covered.")
    print("Empirical percentiles describe 20 samples, not confidence bounds or app input-latency acceptance.")
    return 0 if all(record["status"] == "passed" for record in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
