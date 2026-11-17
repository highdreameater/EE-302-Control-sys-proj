# BMS controller — flowchart

Source: [simulation/bms_4cell/src/bms_controller.m](../simulation/bms_4cell/src/bms_controller.m). One pass of this chart runs every control period `Ts` (1 s), which maps onto one iteration of the Arduino `loop()`.

## Every tick

```mermaid
flowchart TD
    A([Tick: every Ts = 1 s]) --> B[Read 4 cell voltages,<br/>4 cell temps, 4 resistor temps]
    B --> C{"Any V &lt; V_uv,<br/>V &gt; V_ov,<br/>T_cell &gt; T_cell_max or<br/>T_res &gt; T_res_max?"}
    C -- yes --> F[Latch fault bit]
    C -- no --> D
    F --> D{Manual stop<br/>pressed?}
    D -- yes --> STOP[STOP: all switches off<br/>latched]
    D -- no --> E{Fault latched?}
    E -- yes --> FAULT[FAULT: all switches off<br/>fault LED + code]
    E -- no --> G[Alerts: low voltage V &lt; V_lv,<br/>temperature warnings]
    G --> H{Current mode}
    H -- MONITOR --> M{mode_req?}
    M -- "1 and no low-V alert" --> PAS[Enter PASSIVE]
    M -- 2 --> ACT[Enter ACTIVE]
    M -- 0 --> OFF[All switches off]
    H -- PASSIVE --> P1{"mode_req ≠ 1 or<br/>low-V alert?"}
    P1 -- yes --> MON[Back to MONITOR]
    P1 -- no --> CYC[Balancing cycle]
    H -- ACTIVE --> A1{mode_req ≠ 2?}
    A1 -- yes --> MON
    A1 -- no --> CYC
```

## Balancing cycle (shared by PASSIVE and ACTIVE)

```mermaid
flowchart TD
    R0([Balancing cycle]) --> R1{Phase}
    R1 -- REST --> R2[All balancing switches off<br/>average readings from tick 2 to n_rest]
    R2 --> R3{tick = n_rest?}
    R3 -- no --> R9([end of tick])
    R3 -- yes --> R4[V_rest = average,<br/>V_min, spread = max − min]
    R4 --> R5{Mode}
    R5 -- PASSIVE --> R6["for each cell i:<br/>V_i − V_min &gt; dV_on → bleed ON<br/>V_i − V_min ≤ dV_off → bleed OFF<br/>V_i ≤ V_bal_min → bleed OFF<br/>else keep"]
    R5 -- ACTIVE --> R7["spread &gt; dV_on → SC on<br/>spread ≤ dV_off → SC off<br/>gate_k = min(1, I_max·R_eq / |ΔV_k|)"]
    R6 --> R8[Phase = RUN]
    R7 --> R8
    R1 -- RUN --> R10[Apply bleed / SC commands]
    R10 --> R11{tick &gt; n_on?}
    R11 -- yes --> R12[Phase = REST, switches off]
    R11 -- no --> R9
    R8 --> R10
    R12 --> R9
```

## Modes and codes

| Mode | Code | Switches | Leaves when |
|---|---|---|---|
| MONITOR | 0 | all off | `mode_req` = 1 (no low-V alert) or 2 |
| PASSIVE | 1 | bleed MOSFETs per cell | `mode_req` ≠ 1, low-V alert, fault, stop |
| ACTIVE | 2 | SC pair PWM, gated for current limit | `mode_req` ≠ 2, fault, stop |
| FAULT | 3 | all off | latched (reset / power cycle) |
| STOP | 4 | all off | latched (reset / power cycle) |

| Fault bit | Meaning | Default limit |
|---|---|---|
| 0 | under-voltage | V < 3.00 V |
| 1 | over-voltage | V > 4.25 V |
| 2 | cell over-temperature | T > 45 °C |
| 3 | bleed resistor over-temperature | T > 100 °C |

| Alert bit | Meaning | Default |
|---|---|---|
| 0 | low voltage (passive balancing inhibited) | V < 3.30 V |
| 1 | cell temperature warning | T > 40 °C |
| 2 | resistor temperature warning | T > 85 °C |
