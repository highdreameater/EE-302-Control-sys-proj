# EE302 PS-3: BMS hardware as built

Source: specification supplied by the team on 2026-11-17. The checks at the end compare it with the sketch that produced bms_logs.txt (bms/bms.ino) and with the log itself.

## Core microcontroller
| Item | Value |
|---|---|
| Board | Arduino Mega 2560 Rev3 (ATmega2560, 16 MHz, 256 KB flash, 8 KB SRAM) |
| Pins used | 2 (OneWire), 22–25 (passive relays), 26–29 (active relays) |
| Communication | I²C to ADS1115; serial 115200 baud |

## Voltage measurement
| Item | Value |
|---|---|
| ADC | ADS1115, 16-bit, I²C 0x48 |
| Gain (spec) | GAIN_ONE, ±4.096 V, 0.125 mV/bit (see check 1) |
| Divider | R_top 33 kΩ, R_bot 11 kΩ, 1 % metal film: (33 + 11) / 11 = 4.0×, as used in the firmware |
| Channel mapping | A0 → node 1, A1 → node 2, A3 → node 3, A2 → node 4 (pack top) |
| Cell readings | v1 = A0, v2 = A1 − A0, v3 = A3 − A1, v4 = A2 − A3 |

## Battery pack
| Item | Value |
|---|---|
| Cells | Li-ion 18650, 4S1P, ~2600 mAh |
| Voltages | 3.7 V nominal, 4.2 V full, 2.8 V cutoff per cell |
| Measured pack | ~15.87 V (~90 % SOC) |

## Temperature sensing
| Item | Value |
|---|---|
| Sensors | 4 × DS18B20 on pin 2, 4.7 kΩ pull-up to 5 V, 12-bit |
| Measured range | 17.5–20.0 °C |

## Passive balancing
| Item | Value |
|---|---|
| Relays | 2 × dual-channel 5 V modules, active-LOW, pins 22–25 |
| Bleed resistors | 47 Ω, 2 W, one per cell, ~85 mA at 4.0 V |
| Cycle | 10 s ON, 5 s REST, target ΔV < 15 mV |

## Active balancing
| Item | Value |
|---|---|
| Topology | Switched-capacitor ladder, adjacent cells |
| Switches | 4 × SPDT 5 V relays, active-LOW, pins 26–29 |
| Flying capacitors | 3 × 470 µF, 50 V electrolytic |
| Series resistors | 4.7 Ω with each capacitor |
| Switching | ~0.95 Hz nominal; 0.78 Hz measured (1.28 s per shuttle including measurement) |
| Transfer current | ~25 µA estimate; 19 / 56 / 39 µA on pairs 1-2 / 2-3 / 3-4 at the logged voltage differences |
| Capacitor voltage | ~3.9 V on a multimeter, between the two cells it alternates across |

## Power, protection and logging
| Item | Value |
|---|---|
| Supply | USB 5 V from PC; relay coils from the Arduino 5 V |
| Faults | over-voltage 4.35 V, under-voltage 2.80 V, thermal cutoff 55 °C |
| Minimum voltage to balance | 3.30 V per cell |
| Log | CSV, 15 columns, 4,399 rows over 93.6 min |

## Checks against the sketch and the log
1. **ADC gain.** The sketch sets GAIN_TWO (±2.048 V, 0.0625 mV/bit), not GAIN_ONE. The log agrees with GAIN_TWO: cell readings step in 0.25 mV (0.0625 mV × 4), and the open-wire reading is −8.192 V (−2.048 V × 4).
2. **Divider ratio.** 33 kΩ over 11 kΩ gives exactly 4.0, which matches the sketch. The remaining error comes from resistor tolerance: 1 % parts can shift cells 3 and 4 by tens of mV because they are differences of node voltages near 12–16 V. Calibrated against a multimeter: errors −36 / +33 / −48 / +45 mV before, ±1 mV after; gains 1.0094 / 0.9915 / 1.0126 / 0.9884 are in bms_combined.ino.
3. **Divider drain.** Each 44 kΩ divider runs from its node to ground, so cell 1 supplies all four divider currents and cell 4 only one: about 0.91 / 0.82 / 0.63 / 0.36 mA drawn from cells 1-4. The 0.55 mA difference between cell 1 and cell 4 is 10–30 times the active balancing current. The dividers stay connected when the Arduino is off.
4. **Fault limits.** The sketch trips at 3.00 V and 60 °C. The spec says 2.80 V and 55 °C.
5. **Dead time.** The sketch uses 20 ms, the spec says 50 ms. In both cases the dead-time phase is the same relay state as phase A, because SPDT relays have no open position.
6. **Minimum balance voltage and asynchronous temperature reads.** Neither is in the sketch that produced the log.
7. **Log rate.** The log is one row per 1.28 s, not 1 s.
