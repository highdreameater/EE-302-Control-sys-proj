# EE302 PS-3 deliverables checklist

Status as of 17 Nov 2026 (after the passive run). Folder names refer to the submission folder built by `make_submission.py`.

## Student deliverables

| PS-3 deliverable | Status | Where |
|---|---|---|
| Working prototype: 4-cell voltage and temperature monitoring | Done | `2_Code/arduino/bms_combined/` (live demo on the board) |
| Balancing-mode control (monitor / passive / active) | Done | serial commands `o` / `p` / `a` |
| Fault indication | Done | D13 LED solid + buzzer on FAULT; D13 blinking + D9 alert light on alerts; buzzer chirp on low voltage |
| Manual stop | Done | serial `s`, and push-button on D3 (optional, to GND) |
| Labelled circuit schematic | Done, **check against the board** | `3_Schematics_Flowchart/schematic_passive.png`, `schematic_active.png`, `block_diagram.png` |
| Controller flowchart | Done | `3_Schematics_Flowchart/flowchart.png` |
| Commented microcontroller code | Done | `2_Code/arduino/` |
| Demonstration of active balancing | Done (3 runs) | `4_Raw_Data/`, `5_Graphs/hardware/`; no measurable transfer with relays + 470 µF, explained in the report |
| Demonstration of passive balancing | Done (35.6 min, run 4) | `4_Raw_Data/run4_passive`, `5_Graphs/hardware/run4_passive` (`clean/` = believable readings); a ~7 h run would show the full balance |
| Validation on a capacitor test emulator before cell testing | **Not done** (stated in report) | logic verified in simulation and host firmware simulation instead |
| Calibration results against a multimeter | Done | errors −36/+33/−48/+45 mV → ±1 mV; `6_Tables_Calculations/calibration_readings.csv`, gains in the sketch |
| Raw data files | Done | `4_Raw_Data/` (serial logs + CSV per run) |
| Observation tables and calculations | Done | `6_Tables_Calculations/OBSERVATIONS_AND_CALCULATIONS.md` |
| Graphs | Done | `5_Graphs/` |
| Comparative technical report | Done | `1_Report/EE302_PS3_Report.pdf` (IEEE two-column, 8 pages); source in `1_Report/latex/` |
| Presentation and live demo | **To do** | not prepared |

## Project requirements

| Requirement | Status |
|---|---|
| 1. Monitoring and calibration, measurement error quantified | Done: 41 mV RMS before, ±1 mV after (single point near 3.85 V) |
| 2. Controller with modes, voltage/temperature checks, switching logic, alerts, manual stop | Done |
| 3. Passive: spread, current, energy, temperature | Done for run 4: ~85 mA, 78.3 mAh, 0.311 Wh, cells ≤ 17.3 °C (resistor temperature not measured) |
| 4. Active: charge transfer demonstrated and characterised | Characterised (R_eq, currents, step tests, 1 µF check); transfer too small to measure with relays |
| 5. Comparison: none / passive / active, repeatability | Done with run 2 as monitoring reference; **no equal-length no-balancing run and no repeat runs** |
| 6. Data analysis, limitations, uncertainty | Done (`ANALYSIS.md`, report) |

## Before submitting
1. Compile `docs/latex/report.tex` to PDF (Overleaf, or install a TeX engine) and copy it to `docs/latex/report.pdf`.
2. Prepare the presentation.
3. Rebuild the folder: `.venv/bin/python make_submission.py`.
