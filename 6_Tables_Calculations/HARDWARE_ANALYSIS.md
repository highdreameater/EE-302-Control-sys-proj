# Hardware results: active balancing runs

Folders: run1_relay_470uF/ (first run, bms.ino), run2_1uF/ (1 µF check), run3_active_combined/ (active, bms_combined.ino),
run4_passive/ (passive, bms_combined.ino).

## Run 1: relays, 470 µF, bms.ino (log bms_logs.txt)

Plot any log with `.venv/bin/python plot_log.py <log>` from the project root (makes all_rows/ and rested/ graph sets).

## Fault at the start
- 93 rows flagged FAULT, between 6 and 28 min. The last FAULT is at 1685 s (28.1 min).
- Cause: cell 4 reads -8.192 V (ADC negative full scale, an open sense wire) and T4 sticks at 25.00 °C (looks like a sensor-read fallback value).
- No FAULT rows after 28.1 min, so the fix worked as far as the firmware's checks go.
- Readings stay noisy until about 34 min, and cell 4 still drops by 10-90 mV between 45 and 50 min while status was OK (figure 10). The connection is better but probably not fully solid. The firmware does not catch these smaller glitches.

## Active balancing: not moving measurable charge
Stable window: 34-94 min (60 min, 0 faults).

| Window | V1 | V2 | V3 | V4 | Spread [mV] |
|---|---|---|---|---|---|
| Before fault | 4.0639 | 4.0101 | 3.8416 | 3.9596 | 222.3 |
| First 5 min stable | 4.0646 | 4.0091 | 3.8413 | 3.9578 | 223.3 |
| Last 5 min | 4.0655 | 4.0093 | 3.8401 | 3.9589 | 225.5 |

- The spread grew by about 2 mV in an hour instead of falling towards dV_on = 20 mV.
- All three adjacent-pair differences stay flat (about +56, +168, -118 mV). With these differences every pair should be enabled.
- Cell 1, the highest cell, drifted up about 1 mV and cell 3, the lowest, drifted down about 1.6 mV. That is the opposite of balancing, though it is within normal relaxation/temperature drift.
- Pack voltage and temperatures are flat apart from the room cooling about 1 °C. No cell or resistor heats up, which also points to near-zero transfer current.
- RUN -> REST voltage step (figure 7): cells 3 and 4 show 0.0 mV, so pairs 2-3 and 3-4 show no sign of current at all. Cells 1 and 2 show a small opposite step (-2.3 / +1.1 mV), so something on pair 1-2 switches, but the sign means cell 1 reads higher while running, which is consistent with a small current into cell 1 or with switching noise coupling into the ADC, not with draining cell 1.
- The simulation predicted up to 0.5 A per pair. At that current an 18650 changes by tens of mV within an hour, so a working converter would be obvious in this data.

## Things to check on the board
1. Scope the flying-capacitor voltage and the gate signals of each pair while in RUN. Pairs 2-3 and 3-4 sit at higher stack voltages and need isolated or bootstrapped gate drive.
2. Check the direction convention for pair 1-2 (which cell the capacitor connects to first) and the dead time.
3. Measure the current of one pair with a series shunt or clamp meter.
4. Re-seat or solder the cell 4 sense lead, and add a firmware fault for sudden jumps of more than ~10 mV between samples.
5. The loop runs at 1.28 s per sample, not 1 s, so `elapsed_sec` skips a value every few rows. Use `timestamp_ms` for time.

## Figures
01 cell voltages (whole run) · 02 per-cell change in the stable window · 03 spread · 04 pair differences · 05 pack voltage · 06 temperatures · 07 RUN->REST step · 08 phase and loop period · 09 fault zoom · 10 unflagged glitches after the fix

## Firmware and hardware review, 2026-11-17
As-built values are in hardware/arduino/HARDWARE_SPEC.md and the sketch is hardware/arduino/bms/bms.ino.

**Root cause.** The relays flip once per loop (1.28 s), and each flip moves C·ΔV. With 470 µF the pair currents are:

| Pair | ΔV | Average current |
|---|---|---|
| 1-2 | 56 mV | 19 µA |
| 2-3 | 168 mV | 56 µA |
| 3-4 | 118 mV | 39 µA |

That is about 0.002 % SOC per hour on a 2600 mAh cell, well under one ADC step in an hour. Removing the imbalance at this rate would take thousands of hours. The capacitors do switch: the multimeter shows them sitting between the two cell voltages.

**The 4.7 Ω resistors.** The capacitor settles in about 2 ms (4.7 Ω × 470 µF), so the resistor is not what limits the present circuit. It would limit a larger capacitor: with 1 F and 4.7 Ω kept, pair 2-3 only reaches about 6 mA.

**Estimated average current, same relay timing:**

| Flying capacitor and loop resistance | Pair 1-2 | Pair 2-3 | Pair 3-4 |
|---|---|---|---|
| 470 µF, 4.7 Ω (as built) | 0.02 mA | 0.06 mA | 0.04 mA |
| 1 F, 4.7 Ω | 2.1 mA | 6.2 mA | 4.4 mA |
| 1 F, ~1 Ω | 9.7 mA | 29 mA | 21 mA |
| 1 F, ~0.3 Ω | 27 mA | 81 mA | 57 mA |

With a low-resistance loop, precharge each large capacitor through a resistor before the first flip. Otherwise an empty capacitor across a 4 V cell draws amps. Once precharged, the voltage between adjacent cells is under 0.3 V, so peak currents stay below about 1 A.

**The dividers move more charge than the balancer.** 33 k + 11 k dividers from each node to ground draw about 0.91 / 0.82 / 0.63 / 0.36 mA from cells 1-4. That is 10–30 times the balancing current.

**Other firmware findings**
- A FAULT did not stop shuttling. The shuttle counter kept rising through FAULT rows.
- The dead-time phase is the same relay state as phase A, so REST and FAULT leave the capacitors across cells 1-3.
- Cell 4 = A2 − A3. The −8.192 V reading is negative full scale at GAIN_TWO, so the A2 (pack-top) sense lead or its divider was open.
- gain = 1 and offset = 0 on every channel. The divider is 33 k/11 k = 4.0 as in the firmware, but 1 % tolerance still matters for cells 3 and 4. Check each cell against a multimeter, because part of the 222 mV spread may be measurement error.
- A failed DS18B20 read leaves the default 25.0 in the log, which is the T4 = 25.00 seen during the loose-wire period.

These fixes are in hardware/arduino/bms_combined/bms_combined.ino, used for run 3.

## Run 2: flying capacitors changed to 1 µF (log 2026-11-17 16:48, 2.7 min)
Files: run2_1uF/. No faults, no glitches, same loop timing (1.28 s).

| | 470 µF run (stable hour) | 1 µF run |
|---|---|---|
| Cell 1 jump at RUN to REST | −2.26 mV | +0.03 mV |
| Cell 2 jump at RUN to REST | +1.08 mV | +0.02 mV |
| Expected pair current (1-2 / 2-3 / 3-4) | 19 / 56 / 39 µA | 0.04 / 0.13 / 0.09 µA |
| Spread | 223–226 mV | 223.8 mV, flat |

- 1 µF moves 470 times less charge per flip than 470 µF, so balancing is effectively off.
- The small cell 1/2 jump seen with 470 µF has gone. That jump was the 470 µF capacitor drawing current right after each relay flip, so it confirms the old capacitors were connected and switching.
- 2.7 minutes is too short to judge balancing, but with 1 µF a longer run would not change the result.
- To make balancing visible: about 1 F per pair, rated at least 5 V, low ESR, with the 4.7 Ω resistors reduced and a precharge step (see the table above).

## Run 3: relays, 470 µF, bms_combined.ino (log bms_output_vitthal.txt, 53.5 min)
Files: run3_active_combined/all_rows (every row) and run3_active_combined/rested (rows with all outputs off for at least 3 s, WARN rows removed: 279 of 3214). Use the rested graphs for cell voltages and spread.

One OFF minute, then ACTIVE: 93 cycles of 30 s shuttling and 5 s rest, 2652 shuttles, 1.00 s per row, no faults.

| Rested reading | Cell 1 | Cell 2 | Cell 3 | Cell 4 | Spread |
|---|---|---|---|---|---|
| First (9 s) | 4.0361 | 3.9151 | 3.8508 | 3.9343 | 185.3 mV |
| Last (3200 s) | 4.0534 | 3.9192 | 3.8658 | 3.9213 | 187.6 mV |

- **No measurable balancing, as predicted for 470 µF at about 1 shuttle per second.** The rested spread ends where it started.
- **Cell 1 reads 226 mV lower in every RUN row** (std 1.6 mV) and recovers at REST. A real 226 mV drop would need several amps, which the 4.7 Ω capacitor path cannot carry. Cell 1 is the only single-ended channel (A0 against the ADS1115 ground), so this is most likely relay-coil current shifting the ADC ground. Power the relay coils from a separate 5 V supply with its own ground return, or measure only at REST (as the controller already does).
- **Cell 1 rises 17 mV at rest over the run**, slowly and smoothly, which looks like recovery after it was drained before this run, not charge from the capacitors.
- **Cells 3 and 4 move as mirror images** (correlation −0.88, up to ±35 mV) while their sum changes less. That points to the shared sense node between them (ADC input A3) shifting, i.e. a contact or wiring problem, not charge transfer.
- **Cell 4 sense lead is still intermittent**: at 18.2 min it read 3.73 V and then 3.06 V. The firmware flagged WARN on the jump and stopped the RUN after one second because a cell was below 3.30 V, as designed. Re-make the cell-4 and pack-top (A2) connections before the passive run.

## Run 4: passive, 47 Ω, bms_combined.ino (log bms_passive_full.txt, 35.6 min)
Files: run4_passive/all_rows, run4_passive/rested and run4_passive/clean (believable readings only,
`plot_clean_rested.py`).

- The controller bled cells 1 and 2 almost throughout and cells 3 and 4 only while they were more than 15 mV above the lowest.
- Cells 1 and 2 pass every selection rule (noise 0.30 / 0.25 mV). Their rested voltages fell by 14.1 and 23.1 mV
  while 34.0 and 29.8 mAh were bled; the OCV table predicts 26 and 15 mV, 41 mV together against 37 mV measured.
  Cell 1 was still recovering from an earlier drain, which explains part of the split.
- Cells 3 and 4 drift at 19–44 mV/min (contact on their shared node) and are not used.
- 78.3 mAh and 0.311 Wh in total; cell temperatures 16.6–17.3 °C.
- While bleeding, cell 1 reads about 350 mV low, cell 2 130 mV, cell 4 70 mV: current in wiring shared with the measurement.

## About BMS_Emulator_Validation_Data.xlsx
The Calibration_Results sheet (confirmed by the team as measured) is used: errors −36 / +33 / −48 / +45 mV before,
±1 mV after; the gains are now in bms_combined.ino. The runs above were logged with unity gains, so their absolute
spreads shift by −9 to +83 mV when corrected, while single-cell changes change by only about 1 %.
The Passive_Balancing and Active_Balancing sheets are not used: they change by exactly constant amounts every
minute, and in the passive sheet the lowest cell also falls below its starting value, which passive balancing
cannot do. No emulator log exists.
