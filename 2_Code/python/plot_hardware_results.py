#!/usr/bin/env python3
"""Convert the Arduino serial log (bms_logs.txt) to CSV and plot the bench results.

Usage (from the project root):
    .venv/bin/python actual_hardware_results/plot_hardware_results.py path/to/log.txt [output_dir] [--rested]

--rested keeps only rows measured with every balancing output off for at least 3 s (REST/IDLE rows whose two
previous rows were not RUN) and drops rows the firmware marked WARN or FAULT. These are the readings the
controller itself decides on; RUN rows are shifted by current and switching (see ANALYSIS.md).

Outputs, written to output_dir (default: next to this script):
    bms_telemetry_full.csv   every logged row + host clock time + validity flag
    bms_telemetry_valid.csv  rows after the last FAULT (loose wire fixed)
    figures/*.png            one PNG per graph
    summary.txt              numbers used in the analysis
"""
import csv
import re
import sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
RESTED = "--rested" in sys.argv
LOG = Path(ARGS[0]) if ARGS else HERE / "run1_relay_470uF" / "bms_logs.txt"
OUT = Path(ARGS[1]).resolve() if len(ARGS) > 1 else LOG.resolve().parent
OUT.mkdir(parents=True, exist_ok=True)
FIG = OUT / "figures"
FIG.mkdir(exist_ok=True)

# Fixed colour per entity (validated categorical palette, slots 1-4)
CELL_COL = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
PAIR_COL = ["#2a78d6", "#eb6834", "#1baf7a"]
INK, MUTED, GRID = "#0b0b0b", "#52514e", "#e4e3df"
FAULT_SHADE = "#e34948"
DV_ON, DV_OFF = 15.0, 10.0          # balancing thresholds in bms_combined.ino, mV
R_BLEED = [47.0, 47.0, 47.0, 47.0]  # ohm, bleed resistor per cell: edit if a cell uses a different value
SETTLE_S = 360.0                    # readings stay noisy ~5 min after the last FAULT
GLITCH_MV = 5.0                     # deviation from 60 s median that counts as a wiring glitch

plt.rcParams.update({
    "figure.dpi": 110, "savefig.dpi": 200, "font.size": 10,
    "axes.edgecolor": MUTED, "axes.labelcolor": INK, "axes.titleweight": "bold",
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False,
    "xtick.color": MUTED, "ytick.color": MUTED, "lines.linewidth": 1.6,
    "legend.frameon": False,
})

# ---------------------------------------------------------------- 1. convert
LINE = re.compile(r"^(\d{2}:\d{2}:\d{2}\.\d{3})\s*->\s*(.*)$")
header, rows = None, []
for raw in LOG.read_text(errors="replace").splitlines():
    m = LINE.match(raw.strip())
    host, payload = (m.group(1), m.group(2)) if m else ("", raw.strip())
    if not payload:
        continue
    if payload.startswith("timestamp_ms") and {"phase", "status", "v4"} <= set(payload.split(",")):
        header = payload.split(",")
        continue
    parts = payload.split(",")
    if header is None or len(parts) != len(header):
        continue                                    # skip garbled serial lines
    rows.append([host] + parts)

cols = ["host_time"] + header
if RESTED:
    ip, ist = cols.index("phase"), cols.index("status")
    keep = []
    for i, r in enumerate(rows):
        quiet = i >= 2 and all(rows[j][ip] != "RUN" for j in (i - 2, i - 1, i))
        if quiet and r[ip] in ("REST", "IDLE") and r[ist] == "OK":
            keep.append(r)
    print(f"--rested: kept {len(keep)} of {len(rows)} rows")
    rows = keep
STRING_COLS = {"phase", "status", "mode", "fault"}   # bms_combined.ino adds mode, b1-b4, sc_on, fault
num = {c: np.array([float(r[cols.index(c)]) for r in rows])
       for c in header if c not in STRING_COLS}
mode_col = np.array([r[cols.index("mode")] for r in rows]) if "mode" in header else None
phase = np.array([r[cols.index("phase")] for r in rows])
status = np.array([r[cols.index("status")] for r in rows])
t = (num["timestamp_ms"] - num["timestamp_ms"][0]) / 1000.0 + num["timestamp_ms"][0] / 1000.0
tmin = t / 60.0
V = np.c_[num["v1"], num["v2"], num["v3"], num["v4"]]
T = np.c_[num["t1"], num["t2"], num["t3"], num["t4"]]

fault = status == "FAULT"
# a sensor reading is implausible if a cell is outside 2.5-4.3 V or T4 sits on the 25.00 fallback
bad_sensor = (V < 2.5).any(1) | (V > 4.3).any(1) | (T == 25.0).any(1) | (T < -100).any(1)
last_fault_t = t[fault].max() if fault.any() else -1.0
settle = SETTLE_S if fault.any() else 0.0
valid = (t > last_fault_t + settle) & ~bad_sensor
if valid.sum() < 60:          # fault near the end (e.g. a STOP command): use every good, non-fault row
    valid = ~bad_sensor & ~fault

with open(OUT / "bms_telemetry_full.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(cols + ["time_s", "sensor_ok", "stable_after_fix"])
    for i, r in enumerate(rows):
        w.writerow(r + [f"{t[i]:.3f}", int(not bad_sensor[i]), int(bool(valid[i]))])
with open(OUT / "bms_telemetry_valid.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(cols + ["time_s"])
    for i, r in enumerate(rows):
        if valid[i]:
            w.writerow(r + [f"{t[i]:.3f}"])

# fault windows (merge FAULT rows closer than 60 s) for shading
def windows(mask, gap=60.0):
    out, ts = [], t[mask]
    if ts.size == 0:
        return out
    s = p = ts[0]
    for x in ts[1:]:
        if x - p > gap:
            out.append((s, p)); s = x
        p = x
    out.append((s, p))
    return out
FW = windows(fault)

def shade(ax, label=True):
    for k, (a, b) in enumerate(FW):
        ax.axvspan(a / 60, (b + 1.3) / 60, color=FAULT_SHADE, alpha=0.12, lw=0,
                   label="FAULT" if (label and k == 0) else None)

ROLL_N = 5 if RESTED else 47  # about 60 s: 3 rested rows per 35 s cycle, or 1 row per 1-1.3 s

def rolling(y, n=None):
    n = n or ROLL_N
    k = np.ones(n) / n
    yp = np.pad(y, (n // 2, n - 1 - n // 2), mode="edge")
    return np.convolve(yp, k, mode="valid")

SKIP_RESTED = {"07_run_rest_step.png", "08_phase_and_timing.png", "11_mode_and_outputs.png"}  # need RUN rows

def save(fig, name):
    if RESTED and name in SKIP_RESTED:
        plt.close(fig)
        return
    fig.tight_layout()
    fig.savefig(FIG / name, facecolor="white")
    plt.close(fig)
    print("saved", FIG / name)

ok = ~bad_sensor

# ---------------------------------------------------------------- 2. figures
# 01 cell voltages, whole run
fig, ax = plt.subplots(figsize=(10, 5))
shade(ax)
for k in range(4):
    y = np.where(ok, V[:, k], np.nan)
    ax.plot(tmin, y, color=CELL_COL[k], label=f"Cell {k+1}")
bad4 = V[:, 3] < 2.5
if bad4.any():
    ax.scatter(tmin[bad4], np.full(bad4.sum(), 3.80), marker="v", s=40, color=FAULT_SHADE,
               label="Cell 4 read -8.192 V (open wire)", zorder=3)
ax.set(xlabel="Time [min]", ylabel="Cell voltage [V]", title="Cell voltages, whole log")
ax.legend(ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.13))
save(fig, "01_cell_voltages_full.png")

# 02 change of each cell after the fix (mV, own baseline)
fig, axs = plt.subplots(4, 1, figsize=(10, 9), sharex=True)
tv = tmin[valid]
for k, a in enumerate(axs):
    d = (V[valid, k] - V[valid, k][:47].mean()) * 1000
    a.plot(tv, d, color=CELL_COL[k], alpha=0.35, lw=0.8)
    a.plot(tv, rolling(d), color=CELL_COL[k], lw=2)
    p = np.polyfit(tv / 60, d, 1)
    a.set_ylabel(f"Cell {k+1}\nΔV [mV]")
    a.text(0.005, 0.95, f"trend {p[0]:+.2f} mV/h", transform=a.transAxes, ha="left", va="top", color=INK,
           bbox=dict(fc="white", ec="none", alpha=0.8))
    lo, hi = np.percentile(d, [0.5, 99.5]); pad = max(1.0, 0.25 * (hi - lo))
    a.set_ylim(lo - pad, hi + pad)
axs[0].set_title("Cell voltage change over the analysed window (60 s mean in bold, y clipped to 99%)")
axs[-1].set_xlabel("Time [min]")
save(fig, "02_cell_delta_after_fix.png")

# 03 spread
spread = np.where(ok, num["spread_mV"], np.nan)
fig, ax = plt.subplots(figsize=(10, 4.5))
shade(ax)
ax.plot(tmin, spread, color=CELL_COL[0], alpha=0.35, lw=0.8)
ax.plot(tmin[ok], rolling(num["spread_mV"][ok]), color=CELL_COL[0], lw=2, label="Spread (max − min), 60 s mean")
ax.axhline(DV_ON, color=MUTED, ls="--", lw=1); ax.text(tmin[-1], DV_ON + 4, f"{DV_ON:.0f} mV: balancing threshold", ha="right", color=MUTED)
ax.axhline(spread[ok][:47].mean(), color=MUTED, ls=":", lw=1)
ax.set(xlabel="Time [min]", ylabel="Spread [mV]", title="Pack voltage spread (max − min cell)",
       ylim=(0, 260))
ax.legend(loc="center left")
save(fig, "03_spread.png")

# 04 adjacent pair differences (what each switched-capacitor pair sees)
fig, ax = plt.subplots(figsize=(10, 4.5))
shade(ax)
for k in range(3):
    d = (V[:, k] - V[:, k + 1]) * 1000
    ax.plot(tmin[ok], rolling(d[ok]), color=PAIR_COL[k], lw=2, label=f"V{k+1} − V{k+2}")
ax.axhline(0, color=MUTED, lw=1)
ax.set(xlabel="Time [min]", ylabel="Difference [mV]", title="Adjacent-pair voltage differences (60 s mean)")
ax.legend(ncol=4, loc="center right")
save(fig, "04_pair_differences.png")

# 05 pack voltage
fig, ax = plt.subplots(figsize=(10, 4))
shade(ax)
vp = np.where(ok, num["vpack"], np.nan)
ax.plot(tmin, vp, color=CELL_COL[0], alpha=0.35, lw=0.8)
ax.plot(tmin[ok], rolling(num["vpack"][ok]), color=CELL_COL[0], lw=2, label="Pack voltage, 60 s mean")
ax.set(xlabel="Time [min]", ylabel="Pack voltage [V]", title="Pack voltage")
ax.legend(loc="lower left")
save(fig, "05_pack_voltage.png")

# 06 temperatures
fig, ax = plt.subplots(figsize=(10, 4.5))
shade(ax)
for k in range(4):
    y = np.where(T[:, k] == 25.0, np.nan, T[:, k])
    ax.plot(tmin, y, color=CELL_COL[k], label=f"T{k+1}")
st = T[:, 3] == 25.0
if st.any():
    ax.scatter(tmin[st], np.full(st.sum(), 19.9), marker="v", s=30, color=FAULT_SHADE, label="T4 stuck at 25.00 °C", zorder=3)
ax.set(xlabel="Time [min]", ylabel="Temperature [°C]", title="Cell temperatures")
ax.legend(ncol=3, loc="upper center", bbox_to_anchor=(0.5, -0.15))
save(fig, "06_temperatures.png")

# 07 RUN -> REST step (sign of current through each cell during RUN)
chg = np.flatnonzero((phase[1:] == "REST") & (phase[:-1] == "RUN"))
if mode_col is not None:                      # bms_combined.ino: compare the modes
    groups = [(n.title(), mode_col == n) for n in ("PASSIVE", "ACTIVE") if (mode_col == n).any()]
elif FW:                                      # first bench run: before / during / after the loose wire
    groups = [("Before fault", t < FW[0][0]),
              ("Loose-wire period", (t >= FW[0][0]) & (t <= last_fault_t)),
              ("Stable after fix", valid)]
else:
    groups = [("Whole log", t >= 0)]
if not groups:
    groups = [("Whole log", t >= 0)]
steps = []
for name, m in groups:
    idx = [i for i in chg if m[i] and ok[i] and ok[i + 1]]
    steps.append(((V[[i + 1 for i in idx]] - V[idx]) * 1000).mean(0) if idx else np.full(4, np.nan))
steps = np.array(steps)
fig, ax = plt.subplots(figsize=(9, 4.5))
x = np.arange(4); ng = len(groups); wbar = 0.8 / ng
bar_cols = {"Before fault": "#c3c2b7", "Loose-wire period": FAULT_SHADE, "Passive": CELL_COL[1]}
for g in range(ng):
    off = (g - (ng - 1) / 2) * wbar
    ax.bar(x + off, steps[g], width=wbar - 0.02, color=bar_cols.get(groups[g][0], CELL_COL[0]),
           label=groups[g][0])
    for xi, s in zip(x + off, steps[g]):
        if np.isfinite(s) and abs(s) > 1:
            ax.text(xi, s + (0.4 if s > 0 else -0.4), f"{s:+.1f}", ha="center", va="bottom" if s > 0 else "top", fontsize=8, color=INK)
ax.axhline(0, color=MUTED, lw=1)
ax.set_xticks(x, [f"Cell {k+1}" for k in range(4)])
ax.set(ylabel="V(REST) − V(RUN) [mV]", title="Voltage step when balancing switches off (RUN → REST)")
ax.legend(loc="upper right")
save(fig, "07_run_rest_step.png")

# 08 phase and loop timing
fig, axs = plt.subplots(2, 1, figsize=(10, 5), sharex=True)
axs[0].fill_between(tmin, 0, (phase == "RUN").astype(float), step="post", color=CELL_COL[0], alpha=0.6, lw=0)
axs[0].set(yticks=[0, 1], yticklabels=["REST", "RUN"], title="Controller phase and loop period")
dt = np.diff(num["timestamp_ms"])
axs[1].plot(tmin[1:], dt, color=CELL_COL[0], lw=1)
axs[1].set(xlabel="Time [min]", ylabel="Sample period [ms]")
save(fig, "08_phase_and_timing.png")

# 09 zoom on the fault window
if FW:
    a, b = FW[0][0] - 60, last_fault_t + 60
    m = (t >= a) & (t <= b)
    fig, axs = plt.subplots(3, 1, figsize=(10, 7), sharex=True)
    for k in range(4):
        axs[0].plot(tmin[m], V[m, k], color=CELL_COL[k], label=f"V{k+1}")
    axs[0].set(ylabel="Raw cell voltage [V]", title="Fault period, raw readings")
    axs[0].legend(ncol=4, loc="lower left")
    axs[1].plot(tmin[m], T[m, 3], color=CELL_COL[3], label="T4 raw")
    axs[1].set(ylabel="T4 [°C]")
    axs[2].fill_between(tmin[m], 0, fault[m].astype(float), step="post", color=FAULT_SHADE, alpha=0.6, lw=0)
    axs[2].set(yticks=[0, 1], yticklabels=["OK", "FAULT"], xlabel="Time [min]")
    save(fig, "09_fault_zoom.png")


# 10 wiring glitches that the firmware did NOT flag as FAULT
def rolling_median(y, n=None):
    n = n or ROLL_N
    yp = np.pad(y, (n // 2, n - 1 - n // 2), mode="edge")
    return np.median(np.lib.stride_tricks.sliding_window_view(yp, n), axis=1)
post = (t > last_fault_t) & ok
dev = np.zeros_like(V)
for k in range(4):
    dev[post, k] = (V[post, k] - rolling_median(V[post, k])) * 1000
glitch = np.abs(dev) > GLITCH_MV
fig, ax = plt.subplots(figsize=(10, 4.5))
for k in range(4):
    ax.plot(tmin[post], dev[post, k], color=CELL_COL[k], lw=1, label=f"Cell {k+1}")
ax.axhline(GLITCH_MV, color=MUTED, ls="--", lw=1); ax.axhline(-GLITCH_MV, color=MUTED, ls="--", lw=1)
ax.set(xlabel="Time [min]", ylabel="Deviation from 60 s median [mV]",
       title="Jumps from the 60 s median (wiring glitches show up here)")
ax.legend(ncol=4, loc="lower right")
save(fig, "10_unflagged_glitches.png")

# 11 what the controller did (only for logs from bms_combined.ino)
if mode_col is not None:
    fig, axs = plt.subplots(3, 1, figsize=(10, 6), sharex=True,
                            gridspec_kw={"height_ratios": [1, 2, 1]})
    levels = {"OFF": 0, "PASSIVE": 1, "ACTIVE": 2}
    axs[0].step(tmin, [levels.get(m, 0) for m in mode_col], where="post", color=INK, lw=1.5)
    axs[0].set(yticks=[0, 1, 2], yticklabels=["OFF", "PASSIVE", "ACTIVE"], title="Controller mode and outputs")
    for k in range(4):
        axs[1].fill_between(tmin, k, k + 0.8 * num[f"b{k+1}"], step="post", color=CELL_COL[k], lw=0)
    axs[1].set(yticks=[0.4, 1.4, 2.4, 3.4], yticklabels=[f"Bleed {k+1}" for k in range(4)], ylim=(0, 4))
    axs[2].fill_between(tmin, 0, num["sc_on"], step="post", color=CELL_COL[0], alpha=0.7, lw=0)
    axs[2].set(yticks=[0, 1], yticklabels=["off", "shuttling"], xlabel="Time [min]")
    save(fig, "11_mode_and_outputs.png")

# 12 how far each cell is above the lowest cell (what passive balancing works on)
above = (V - V.min(axis=1, keepdims=True)) * 1000
fig, ax = plt.subplots(figsize=(10, 4.5))
shade(ax)
for k in range(4):
    y = np.where(ok, above[:, k], np.nan)
    ax.plot(tmin[ok], rolling(y[ok]), color=CELL_COL[k], lw=2, label=f"Cell {k+1}")
ax.axhline(DV_ON, color=MUTED, ls="--", lw=1)
ax.text(tmin[-1], DV_ON + 3, f"{DV_ON:.0f} mV: balancing threshold", ha="right", color=MUTED)
ax.set(xlabel="Time [min]", ylabel="Above lowest cell [mV]", title="Each cell above the lowest cell (60 s mean)",
       ylim=(0, None))
ax.legend(ncol=5, loc="upper center", bbox_to_anchor=(0.5, -0.15))
save(fig, "12_cells_above_lowest.png")

# ---------------------------------------------------------------- 3. summary
b0 = valid & (t < t[valid][0] + 300)
b1 = valid & (t > t[valid][-1] - 300)
pre = ok & (t < (FW[0][0] if FW else t[-1]))
lines = [
    f"Log file: {LOG}",
    f"Rows: {len(rows)}   FAULT rows: {fault.sum()}   last FAULT at {last_fault_t:.0f} s ({last_fault_t/60:.1f} min)",
    f"Rows with impossible sensor values: {bad_sensor.sum()} (cell 4 = -8.192 V: {(V[:,3]<0).sum()}, T4 = 25.00: {(T[:,3]==25).sum()})",
    f"Rows analysed: {valid.sum()} spanning {(t[valid][-1]-t[valid][0])/60:.1f} min, faults after fix: {(fault & (t>last_fault_t)).sum()}",
    f"Stable window used for balancing analysis starts {settle:.0f} s after the last FAULT",
    f"Glitch samples (>{GLITCH_MV:.0f} mV from 60 s median) after the fix, status OK: "
    + ", ".join(f"cell{k+1}={glitch[:, k].sum()}" for k in range(4))
    + (f"; last at {t[glitch.any(1)].max()/60:.1f} min" if glitch.any() else ""),
    f"Sample period: median {np.median(dt):.0f} ms, max {dt.max():.0f} ms",
    "",
    "Mean voltages [V]           cell1    cell2    cell3    cell4   spread[mV]",
    "  before fault        " + " ".join(f"{x:8.4f}" for x in V[pre].mean(0)) + f"   {num['spread_mV'][pre].mean():6.1f}",
    "  first 5 min analysed" + " ".join(f"{x:8.4f}" for x in V[b0].mean(0)) + f"   {num['spread_mV'][b0].mean():6.1f}",
    "  last 5 min          " + " ".join(f"{x:8.4f}" for x in V[b1].mean(0)) + f"   {num['spread_mV'][b1].mean():6.1f}",
    "",
    "RUN->REST step [mV]          cell1  cell2  cell3  cell4",
] + [f"  {g[0]:<24s}" + " ".join(f"{s:+6.2f}" for s in steps[i]) for i, g in enumerate(groups)]
if "b1" in num and not RESTED:                 # passive balancing: what each bleed resistor did
    dts = np.r_[np.diff(num["timestamp_ms"]), np.median(np.diff(num["timestamp_ms"]))] / 1000.0
    # RUN readings are shifted by the bleed current, so use the most recent rested reading of each cell
    quiet = np.array([i >= 2 and phase[i] in ("REST", "IDLE") and phase[i - 1] != "RUN" and phase[i - 2] != "RUN"
                      for i in range(len(phase))])
    Vr = V.copy()
    last = V[np.argmax(quiet)] if quiet.any() else V[0]
    for i in range(len(V)):
        if quiet[i]:
            last = V[i]
        Vr[i] = last
    lines += ["", "Passive bleeding (current = last rested cell voltage / R_BLEED)",
              "  cell  R [ohm]  on-time [min]  mean I [mA]  charge [mAh]  energy [Wh]"]
    tot = 0.0
    for k in range(4):
        on = num[f"b{k+1}"] > 0.5
        I = np.where(on, Vr[:, k] / R_BLEED[k], 0.0)
        q = (I * dts).sum() / 3.6                   # mAh
        e = (I * Vr[:, k] * dts).sum() / 3600.0     # Wh (I^2 R)
        tot += e
        mi = 1000 * I[on].mean() if on.any() else 0.0
        lines.append(f"  {k+1:>4}  {R_BLEED[k]:7.1f}  {(dts * on).sum() / 60:13.1f}  {mi:11.1f}  {q:12.2f}  {e:11.3f}")
    lines.append(f"  total energy dissipated: {tot:.3f} Wh;  peak temperature: {np.nanmax(np.where(T > -100, T, np.nan)):.2f} C")
(OUT / "summary.txt").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
