# Legacy 3-cell model — notes

The first model of the project: 3 × 27 Ah Li-ion cells (80 / 65 / 75 % SOC), passive balancing through
47 Ω resistors, controlled on **SOC** (1 % threshold). It is kept as a reference; the PS-3 work is in
`../bms_4cell/`. Last saved in MATLAB R2026a.

Original, unmodified model: `~/Downloads/Research_Paper_ORIGINAL_backup.slx` (outside this folder).

## Cost metrics added (2026-11-11)

## New blocks in the model (standard Simulink only, original wiring unchanged)

| Group | Blocks | Output |
|---|---|---|
| Energy lost | Power Mux → Integrator → Gain 1/3600 → Sum | Scope **Energy Lost (Wh)**: per cell + total |
| SOC spread | Max SOC, Min SOC → Subtract → ×100 | Scope **SOC Spread (%)** |
| Logging (To Workspace, every 10 s) | `SOC`, `SOC_spread_pct`, `V_cell`, `P_bleed_W`, `E_loss_Wh`, `E_total_Wh`, `BalCmd`, `BalActive` | available as `out.<name>` after `sim` |

Column order for every logged vector: **[80% cell, 65% cell, 75% cell]**.

## How to run
1. Open MATLAB R2026a in this folder (`simulation/legacy_3cell/`).
2. Run `analyze_balancing.m`.
   - Prints the metrics and writes `results/`: `metrics_summary.csv`, `metrics_per_cell.csv`,
     `balancing_logs.mat`, and 4 figures at 300 dpi.

## Metrics computed
- Energy burned in each resistor and in total (Wh), as % of full-pack energy and of energy stored at t = 0
- Balancing time: first time the SOC spread falls to the controller threshold (1 %)
- Start and end SOC per cell, final spread, and hours each bleed resistor was on
- Usable capacity of the series pack, `AH × (1 − spread)`, before vs after balancing

## Results (R2026a run, 2026-11-13) vs hand calculation
- 23.96 Wh lost (8.0 % of the 299 Wh pack), 46.8 h to balance, 80.8 mA average bleed current
- Known issue: MATLAB reports an algebraic loop through the `Passive Cell Balancing` enabled subsystem (results unaffected)

Hand calculation made before the run:
- About 24–26 Wh lost, about 8 % of the ~299 Wh pack
- About 47 h to balance at about 81 mA bleed current
- Usable capacity about 22.95 Ah → about 26.7 Ah (+16 %)

