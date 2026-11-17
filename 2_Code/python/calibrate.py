#!/usr/bin/env python3
"""Calibrate the BMS voltage channels against a multimeter and quantify the measurement error.

1. Flash bms_combined.ino, leave it in OFF mode (monitor only) for a minute.
2. Measure each cell with a multimeter directly at the cell terminals.
3. Average v1..v4 over the same 10 rows of the log and enter both in calibration_readings.csv.
   One row per cell gives a gain-only correction. Two or more rows per cell at different voltages
   (e.g. before and after a passive run) give gain and offset.
4. Run:  .venv/bin/python hardware/calibration/calibrate.py [calibration_readings.csv]

Prints the error table and the gain[]/offs[] lines to paste into bms_combined.ino.
"""
import csv
import sys
from pathlib import Path

import numpy as np

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name("calibration_readings.csv")
pts = {k: [] for k in range(1, 5)}
for row in csv.DictReader(open(path)):
    try:
        pts[int(row["cell"])].append((float(row["multimeter_V"]), float(row["bms_V"])))
    except (ValueError, KeyError):
        continue                                   # empty template rows

if not any(pts.values()):
    sys.exit(f"No readings in {path}. Fill multimeter_V and bms_V first.")

gain, offs = [1.0] * 4, [0.0] * 4
print(f"{'cell':>4} {'n':>2} {'meter V':>9} {'BMS V':>9} {'error mV':>9} {'error %':>8} {'gain':>8} {'offset mV':>10}")
errs = []
for k in range(1, 5):
    if not pts[k]:
        print(f"{k:>4}  -  no readings")
        continue
    m = np.array([p[0] for p in pts[k]]); b = np.array([p[1] for p in pts[k]])
    e = (b - m) * 1000
    errs.extend(e)
    if len(m) >= 2 and np.ptp(b) > 0.02:
        g, o = np.polyfit(b, m, 1)                 # meter = g * bms + o
    else:
        g, o = float(np.mean(m / b)), 0.0
    gain[k - 1], offs[k - 1] = g, o
    print(f"{k:>4} {len(m):>2} {m.mean():9.4f} {b.mean():9.4f} {e.mean():+9.1f} {0.1 * e.mean() / m.mean():+8.3f} {g:8.5f} {1000 * o:+10.1f}")

errs = np.array(errs)
print(f"\nUncalibrated error over {len(errs)} readings: mean {errs.mean():+.1f} mV, "
      f"max |error| {np.abs(errs).max():.1f} mV, RMS {np.sqrt((errs ** 2).mean()):.1f} mV")
print("Multimeter accuracy (typically ±0.5 % + 2 digits on the 20 V range) also bounds the result.\n")
print("Paste into bms_combined.ino:")
print("float gain[4] = {" + ", ".join(f"{g:.5f}" for g in gain) + "};")
print("float offs[4] = {" + ", ".join(f"{o:.5f}" for o in offs) + "};")
