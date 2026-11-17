# Observation tables and calculations (EE302 PS-3)

Hardware: 4S 18650 pack (about 2.6 Ah per cell), Arduino Mega 2560, ADS1115, 33 kΩ / 11 kΩ dividers,
47 Ω bleed resistors on relays, 3 × 470 µF flying capacitors with 4.7 Ω on SPDT relays. Full list:
`hardware/arduino/HARDWARE_SPEC.md`. Raw logs and graphs are in the `run*` folders next to this file.

## 1. Observation tables

### 1.1 Runs recorded

| Run | Firmware | Mode | Flying capacitor | Duration | Rows | Faults / warnings | Notes |
|---|---|---|---|---|---|---|---|
| 1 | bms.ino | active | 470 µF | 93.6 min | 4399 (1.28 s) | 93 FAULT rows (6–28 min) | open cell-4 sense lead, fixed during the run |
| 2 | bms.ino | active | 1 µF | 2.7 min | 128 (1.28 s) | none | capacitor-value check |
| 3 | bms_combined.ino | active | 470 µF | 53.5 min | 3214 (1.00 s) | 5 WARN rows (cell-4 jump) | serial-controlled final firmware |
| 4 | bms_combined.ino | passive | – | 35.6 min | 2136 (1.00 s) | 8 WARN rows (cell-4 jump) | 47 Ω bleed, 10 s on / 5 s rest |
| 5 | bms_combined.ino | none (OFF) | – | *not recorded* | | | run 2 (1 µF, ≈0.1 µA) serves as monitoring-only reference |

### 1.2 Rested cell voltages (outputs off for at least 3 s)

| Run | Point | V1 [V] | V2 [V] | V3 [V] | V4 [V] | Pack [V] | Spread [mV] |
|---|---|---|---|---|---|---|---|
| 1 | before fault | 4.0639 | 4.0101 | 3.8416 | 3.9596 | 15.875 | 222.3 |
| 1 | first 5 min of stable window (34 min) | 4.0646 | 4.0091 | 3.8413 | 3.9578 | 15.873 | 223.3 |
| 1 | last 5 min | 4.0655 | 4.0093 | 3.8401 | 3.9589 | 15.874 | 225.5 |
| 2 | whole run | 4.0634 | 4.0090 | 3.8396 | 3.9595 | 15.872 | 223.8 |
| 3 | first rest (9 s) | 4.0361 | 3.9151 | 3.8508 | 3.9343 | 15.736 | 185.3 |
| 3 | last rest (3200 s) | 4.0534 | 3.9192 | 3.8658 | 3.9213 | 15.760 | 187.6 |
| 4 | start, OFF mode (3 s) | 4.0579 | 3.9196 | 3.8816 | 3.8714 | 15.731 | 186.5 |
| 4 | end (median of last 5 rests, 35.6 min) | 4.0438 | 3.8965 | 3.8858* | 3.8706* | – | –* |

### 1.3 Voltage step when outputs switch off (V_REST − V_RUN)

| Run | Cell 1 [mV] | Cell 2 [mV] | Cell 3 [mV] | Cell 4 [mV] | Interpretation |
|---|---|---|---|---|---|
| 1, stable window | −2.25 | +1.08 | −0.07 | −0.07 | small effect of the 470 µF capacitors after each flip |
| 2 (1 µF) | +0.03 | +0.02 | +0.06 | +0.05 | nothing: confirms run 1 step came from the capacitors |
| 3 | +225.8 | +0.07 | −0.03 | +11.5 | cell 1 offset while relays shuttle (ADC ground shift); cell 4 includes glitches |
| 4 | +350.6 | +131.9 | −5.5 | +72.7 | bleed and relay-coil current in wiring shared with the measurement |

### 1.4 Temperatures

| Run | Range of T1–T4 [°C] | Note |
|---|---|---|
| 1 | 17.5 – 19.7 | room temperature drift, no heating from balancing |
| 3 | 17.3 – 17.9 | no heating from balancing |
| 4 | 16.6 – 17.3 | cells only; bleed resistors not monitored |

## 2. Calculations

### 2.1 Measurement chain
- Divider ratio: k = (R_top + R_bot) / R_bot = (33 + 11) / 11 = **4.0** (firmware `DIV`).
- ADS1115 at ±2.048 V: 62.5 µV per LSB, so **0.25 mV per cell** after ×4.
- Cell voltages: v1 = 4·A0, v2 = 4·(A1 − A0), v3 = 4·(A3 − A1), v4 = 4·(A2 − A3).
- Open-wire signature: an open pack-top lead drives A2 − A3 to the negative limit, −2.048 V × 4 = **−8.192 V** (seen in run 1).
- Tolerance: cells 3 and 4 are differences of node voltages near 12–16 V, so 1 % resistors can give tens of mV
  of error. Calibration against a multimeter: `hardware/calibration/` (template and script).

### 2.2 Divider loading
Each 44 kΩ divider draws I = V_node / 44 kΩ, and cell i supplies all dividers at or above it:

| | Cell 1 | Cell 2 | Cell 3 | Cell 4 |
|---|---|---|---|---|
| Drain current [mA] | 0.90 | 0.81 | 0.63 | 0.36 |

The 0.54 mA difference between cell 1 and cell 4 is larger than the active stage's transfer current.

### 2.3 Passive bleed stage
I_b = V / R_b,  P = V² / R_b  (at 4.0 V):

| R_b | I_b | P | Note |
|---|---|---|---|
| 100 Ω | 40 mA | 0.16 W | slow |
| **47 Ω (fitted)** | **85 mA** | **0.34 W** | resistor near 46 °C in simulation |
| 22 Ω | 182 mA | 0.73 W | resistor near 69 °C in simulation |
| 10 Ω | 400 mA | 1.6 W | needs a 5 W+ resistor |

Energy actually dissipated in a passive run is computed from the log by `plot_hardware_results.py`
(section "Passive bleeding" of `summary.txt`): E = Σ b_i · v_i² / R_b · Δt, with v_i the last rested reading.

Run 4 (passive, 35.6 min, R_b = 47 Ω, believable readings only; see section 4):

| Cell | On-time [min] | Charge removed [mAh] | Energy [Wh] | Rested ΔV [mV] | Expected ΔV from charge [mV] |
|---|---|---|---|---|---|
| 1 | 23.7 | 34.0 | 0.137 | −14.1 | −26 |
| 2 | 21.5 | 29.8 | 0.116 | −23.1 | −15 |
| 3 | 2.0 | 2.8 | 0.011 | contact-affected | |
| 4 | 8.5 | 11.8 | 0.046 | contact-affected | |
| Total | | 78.3 | 0.311 | −37.2 (cells 1+2) | −41 (cells 1+2) |

Expected ΔV: charge / 2.6 Ah converted through the OCV table (about 20 mV/% above 90 % SOC, 13 mV/% between
75 and 90 %).

### 2.4 Switched-capacitor stage
Charge per flip q = C·ΔV. Averaged model:
R_eq = (1 / fC) · (1 + e^−x) / (1 − e^−x),  x = D / (f·R·C),  I = ΔV / R_eq.

| Quantity | Run 1 | Run 3 |
|---|---|---|
| Shuttle rate f | 0.78 Hz (1.28 s loop) | 1.0 Hz (500 ms + 500 ms) |
| Conduction fraction D per position | 0.39 | 0.50 |
| Capacitor settling τ = R·C | 2.3 ms | 2.3 ms |
| R_eq (C = 470 µF, R = 4.8 Ω) | 2728 Ω | 2128 Ω |
| Mean pair differences [mV] | 56 / 168 / 118 | 131 / 48 / 47 |
| Pair currents [µA] | 21 / 62 / 43 | 61 / 23 / 22 |
| Charge per hour, largest pair | 0.06 mAh | 0.05 mAh |
| SOC change per hour, largest pair | 0.002 % | 0.002 % |

With 1 µF (run 2) the current is 470 times smaller, about 0.1 µA.

### 2.5 Estimated time to balance (from the measured voltages of run 1)
SOC from the open-circuit-voltage table (3.0/3.4/3.6/3.7/3.8/4.0/4.2 V at 0/10/25/50/75/90/100 %):
93.2 / 90.5 / 78.0 / 87.0 %. Charge to remove for passive balancing: ΔQ_i = (SOC_i − SOC_min)·2.6 Ah =
0.395 / 0.324 / 0 / 0.234 Ah. Passive time ≈ max ΔQ / (I_b · 10/15) = 0.395 / (0.085 · 0.667) ≈ 7.0 h
(integration with the stop band: 6.7 h, 3.5 Wh dissipated).

| Configuration | R_eq [Ω] | Time to ≤ 10 mV |
|---|---|---|
| Passive, 47 Ω, 10 s on / 5 s rest | – | 6.7 h |
| Active, relays, 470 µF (as built) | 2728 | ≈ 26 700 h |
| Active, relays, 4 × 470 µF | 682 | ≈ 6 700 h |
| Active, MOSFET 100 Hz, 470 µF | 27.0 | 264 h |
| Active, MOSFET 1 kHz, 470 µF | 20.1 | 196 h |
| Active, MOSFET 1 kHz, 4 × 470 µF | 5.02 | 49 h |
| Active, MOSFET 1 kHz, 470 µF, 0.4 Ω loop | 2.49 | 24 h |

### 2.6 Final voltages
- Passive: every cell ends at the lowest cell, V∞ = V_oc(SOC_min) ≈ **3.840 V** (pack falls to about 15.36 V).
- Active: cells end at the mean SOC, V∞ = V_oc(mean SOC) ≈ **3.962 V** (pack voltage almost unchanged).

### 2.7 Calibration (multimeter, single point near 3.85 V)

| Cell | Multimeter [V] | BMS before [V] | Error before [mV] | Gain | Offset [V] | Error after [mV] |
|---|---|---|---|---|---|---|
| 1 | 3.851 | 3.815 | −36 | 1.0094 | +0.001 | −1 |
| 2 | 3.852 | 3.885 | +33 | 0.9915 | −0.002 | +1 |
| 3 | 3.849 | 3.801 | −48 | 1.0126 | 0.000 | −1 |
| 4 | 3.850 | 3.895 | +45 | 0.9884 | +0.001 | +1 |

RMS error 41.0 mV before, 1.0 mV after. Gain = multimeter / BMS (e.g. 3.851 / 3.815 = 1.0094).

## 3. Measurement uncertainty
- ADC resolution 0.25 mV per cell; rested noise about 0.2–0.5 mV.
- Divider tolerance: measured −36 to +48 mV before calibration, ±1 mV after (section 2.7); runs 1–4 were logged before the gains were applied.
- Readings during RUN are shifted (bleed current × cell and wire resistance, relay-coil ground shift on cell 1),
  so only rested readings are used for decisions and for the spread graphs (`--rested`).
- Intermittent cell-4 / pack-top wiring produced −8.192 V (run 1) and 3.06 V (run 3) readings; these rows are
  flagged FAULT/WARN and excluded from the rested graphs.
- The SOC-based time estimates use a generic OCV table, so they are approximate.

## 4. Selection of believable readings
Applied identically to every cell and run by `plot_clean_rested.py`:
1. Rested rows only (all outputs off for at least 3 s, status OK).
2. A rested reading more than 3 mV from the median of its 7 neighbours is discarded (bleeding changes a cell by
   about 0.2 mV per 15 s cycle).
3. A cell with noise above 1 mV or a 1-minute rate of change above 10 mV/min is marked contact-affected and not
   used. Real cells: at most 3.3 mV/min. Contact drift on cells 3 and 4: 19–44 mV/min.

| Run | Cell 1 | Cell 2 | Cell 3 | Cell 4 |
|---|---|---|---|---|
| 3 (active) | reliable, +17.6 mV | reliable, +4.2 mV | contact-affected | contact-affected |
| 4 (passive) | reliable, −14.1 mV | reliable, −23.1 mV | contact-affected | contact-affected |

\* cells 3 and 4 contact-affected, so the run-4 spread is not meaningful.
