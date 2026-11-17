# EE302 Control Systems Lab – PS-3: Battery Monitoring and Cell Balancing

Four-cell 18650 Li-ion BMS on an Arduino Mega 2560 with ADS1115 voltage sensing and DS18B20 temperature sensing.
One controller provides monitoring, passive balancing (relay-switched 47 Ω resistors), active balancing
(relay-switched 470 µF capacitor ladder), alerts, latched faults and a manual stop, selected over serial.

**Report:** [`1_Report/EE302_PS3_Report.pdf`](1_Report/EE302_PS3_Report.pdf)

| Folder | Contents |
|---|---|
| `1_Report` | Report PDF, LaTeX source and figures, simulation report |
| `2_Code` | Arduino firmware (`bms_combined.ino`), Python analysis scripts, MATLAB/Simulink simulation |
| `3_Schematics_Flowchart` | Circuit schematics, block diagram, controller flowchart (PNG + SVG) |
| `4_Raw_Data` | Serial logs and CSV for every hardware run |
| `5_Graphs` | Hardware graphs (all rows, rested, believable-only) and simulation graphs |
| `6_Tables_Calculations` | Observation tables, calculations, calibration data, hardware analysis |
| `7_Hardware_Spec` | As-built hardware specification and circuit photo |

See [`DELIVERABLES_CHECKLIST.md`](DELIVERABLES_CHECKLIST.md) for how each PS-3 deliverable is covered.

**Team:** Vidhi Chandak (B24356), Vitthal Seth (B24357), Shashwat Saha (B23292), Rishi Bansal (B23288) – IIT Mandi
