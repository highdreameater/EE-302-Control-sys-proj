#!/usr/bin/env python3
"""Make all the graphs for one BMS log.

Run from the project folder:
    .venv/bin/python plot_log.py my_log.txt       a saved log file (Serial Monitor copy or CSV)
    .venv/bin/python plot_log.py                  asks for a file, or lets you paste the log

Accepts logs from bms.ino (15 columns) and bms_combined.ino (22 columns), with or without the
Serial Monitor "HH:MM:SS.mmm -> " timestamps. Lines starting with '#' are ignored.

Graphs, CSVs and summary.txt go to actual_hardware_results/<log name>/all_rows and /rested.
Use the rested set for cell voltages and spread; RUN rows are shifted by switching current.
"""
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PLOTTER = ROOT / "actual_hardware_results" / "plot_hardware_results.py"
LOG_DIR = ROOT / "actual_hardware_results" / "logs"


def ask_for_log() -> Path:
    print("Drag the log file into this window and press Enter,")
    print("or just press Enter to paste the log text instead.")
    answer = input("> ").strip().strip("'\"")
    if answer:
        return Path(answer.replace("\\ ", " ")).expanduser()

    print("Paste the log, then press Ctrl-D (Mac/Linux) or Ctrl-Z then Enter (Windows):")
    text = sys.stdin.read()
    if "timestamp_ms" not in text:
        sys.exit("No header line (timestamp_ms,...) found in the pasted text.")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"log_{datetime.now():%Y%m%d_%H%M%S}.txt"
    path.write_text(text)
    print(f"Saved pasted log to {path}")
    return path


def main():
    log = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else ask_for_log()
    if not log.is_file():
        sys.exit(f"Log file not found: {log}")
    out = ROOT / "actual_hardware_results" / log.stem
    out.mkdir(parents=True, exist_ok=True)
    if log.resolve().parent != out.resolve():
        shutil.copy2(log, out / log.name)           # keep the raw log with its results
    # every row (shows switching artefacts), and rested rows only (valid cell voltages)
    for sub, extra in (("all_rows", []), ("rested", ["--rested"])):
        result = subprocess.run([sys.executable, str(PLOTTER), str(log.resolve()), str(out / sub)] + extra)
        if result.returncode != 0:
            sys.exit("Plotting failed, see the error above.")
    print(f"\nGraphs, every row:        {out / 'all_rows' / 'figures'}")
    print(f"Graphs, rested rows only: {out / 'rested' / 'figures'}")
    if sys.platform == "darwin":
        subprocess.run(["open", str(out)])


if __name__ == "__main__":
    main()
