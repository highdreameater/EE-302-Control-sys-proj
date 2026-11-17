# Simulation-Based Design and Comparison of Passive and Active Cell Balancing for a Four-Cell Lithium-Ion Battery Pack

**EE302 Control Systems Laboratory — Final End-Semester Project, Problem Statement 3**
Battery Monitoring and Cell Balancing: Design and Experimental Comparison of Passive and Active Balancing

Work period: 11–13 November 2026
Tools: MATLAB/Simulink R2026a (Update 4), Simscape, Simscape Electrical, Simscape Battery

---

## Abstract

This report presents a simulation study of a battery monitoring and cell-balancing system for a four-cell
series lithium-ion pack. It was carried out as the design stage ahead of an Arduino-based hardware
implementation. A single controller monitors cell voltages and temperatures. It provides monitoring,
passive-balancing, active-balancing, fault and manual-stop modes, together with low-voltage and temperature alerts.

Passive balancing is realised with switched bleed resistors. Active balancing is realised with a
switched-capacitor equaliser between adjacent cells, represented by an averaged model whose equivalent resistance
was verified against a switch-level circuit to within 0.3 % over four decades of switching frequency.
The measurement chain of the target microcontroller, including ADC quantisation, noise and calibration error,
is modelled explicitly.

Starting from identical initial conditions (state of charge 80/65/75/70 %, voltage spread 107 mV), both
balancing methods reduced the spread to about 11 mV. Passive balancing required 1.55 ± 0.02 h and dissipated
2.05 ± 0.04 Wh (5.5 % of pack energy). Active balancing required 1.05 ± 0.02 h with 0.007 Wh of conduction loss,
and left the pack with 10 % more deliverable charge.

The study also established four quantitative design constraints for the hardware:
- the minimum bleed-resistor value, set by resistor temperature;
- the minimum balancing thresholds permitted by a 10-bit ADC;
- the need for current limiting in the switched-capacitor stage;
- the minimum capacitance of the supercapacitor test emulator.

---

## 1. Introduction

In a series-connected battery pack, differences in capacity, internal resistance and self-discharge cause the
cells to drift apart in state of charge (SOC). The usable capacity of the pack is then limited by its weakest cell,
since discharge must stop when the lowest cell reaches its cut-off voltage and charging must stop when the highest
cell reaches its limit. Cell balancing counteracts this drift. *Passive* methods dissipate the excess charge of
the higher cells as heat. *Active* methods transfer charge between cells using capacitive or inductive elements [1], [4].

Problem Statement 3 requires the following:
- a microcontroller-based system that monitors the voltages and temperatures of a four-cell pack;
- a controller with monitoring, passive-balancing, active-balancing and fault-handling modes, including alerts and
  a manual stop;
- implementations of resistor-based passive balancing and switched-capacitor active balancing;
- a controlled comparison of no balancing, passive balancing and active balancing.

The safety requirements specify validation on a capacitor-based test emulator before any cells are connected.

This report describes the simulation stage of that work. Its objectives were to:
1. develop a model of the complete system whose controller can be transferred directly to the microcontroller;
2. reproduce, in simulation, the experiment plan required by the problem statement;
3. identify design constraints and failure modes before hardware is built;
4. provide quantitative predictions against which bench measurements can later be compared.

---

## 2. Background and Related Work

### 2.1 Starting point

The project began from an existing Simulink model of three series 27 Ah cells at 80, 65 and 75 % SOC. That model
used passive balancing through 47 Ω resistors, with a controller acting on SOC and a 1 % threshold. Energy-loss and
SOC-spread instrumentation had previously been added to it. Its results were verified by hand calculation in this
work: 23.96 Wh dissipated (8.0 % of a 299 Wh pack) over 46.8 h. Two defects in its analysis script were corrected
(Section 6, issues E1 and E2).

The model nevertheless did not meet the problem statement in three respects:
- **Cell count:** it contained three cells rather than four.
- **Controlled variable:** it acted on SOC, which a microcontroller cannot measure directly.
- **Run length:** at 27 Ah per cell a single balancing run lasted about 47 h, which is impractical for laboratory
  demonstration.

It has been retained unchanged as a reference model.

### 2.2 Balancing methods

Daowd et al. compared passive and active topologies in MATLAB/Simulink and established the trade-off that frames
this study [1]. The shunt-resistor method is simple and inexpensive but wasteful. Capacitive and inductive methods
are more efficient at the cost of complexity. The review by Gallardo-Lozano et al. rates switched-capacitor
equalisers favourably when cost, complexity and efficiency are weighed together [4]. Recent reviews reach the same
conclusion and note that passive balancing remains best suited to small, cost-sensitive systems [10].

The adjacent-cell switched-capacitor equaliser was introduced by Pascual and Krein [3]. Its average behaviour is
described by the equivalent-resistance analysis of switched-capacitor converters, with slow- and fast-switching
limits identified by Seeman and Sanders [2]. Behavioural averaged models of this kind were formalised by
Ben-Yaakov [5].

### 2.3 Recent work

The study closest to the present one is Lim, Siek and Tan [11]. In simulation, they compared passive,
switched-capacitor, hybrid and adaptive pulse-frequency-modulated balancing for a four-cell pack. The hybrid scheme
balanced 16 % faster than active-only balancing at 97.7 % efficiency. Varying the switching frequency with the
voltage mismatch raised efficiency to 99.9 %.

An Arduino-based BMS cross-validated against a Simulink model has also been reported [12]. Its authors observe that
low-cost implementations seldom combine hardware experiments with energy and thermal analysis, which is the
combination planned for this project.

On the choice of controlled variable, recent reviews note that voltage-based balancing avoids state-estimation
error but is degraded by flat open-circuit-voltage (OCV) curves and by the voltage shift that the balancing current
itself introduces. SOC-based balancing is more accurate, provided the SOC estimate is accurate [13].

---

## 3. Methodology

### 3.1 Model construction

The four-cell model was not derived from the earlier hand-wired model. It is generated programmatically by a
MATLAB script, `build/build_4cell_model.m`. The script produces two variants: one with lithium-ion cells and one
with the supercapacitor emulator. This keeps every block, connection and parameter in reviewable text form, and lets
the model be regenerated whenever a parameter changes. The entry script `run_all.m` rebuilds the models before each
set of experiments, so results and model are always consistent.

The plant is modelled in Simscape. Each cell uses the Simscape Battery table-based equivalent-circuit block [7]
with a thermal port and convective heat transfer to ambient. Each bleed branch consists of a resistor, a current
sensor and an ideal MOSFET switch. Bleed-resistor temperature is represented by a first-order thermal model, because
resistor temperature rather than cell temperature turned out to be the limiting quantity.

### 3.2 Control strategy

The controller acts on measured cell voltage, the only cell quantity available to the target hardware. It is
implemented as a MATLAB Function block that calls a plain procedural function, `src/bms_controller.m`. The function
is written so that it can be translated line by line into the Arduino `loop()`. It executes once per second.

Every cycle begins with protection checks for under-voltage, over-voltage, cell over-temperature and resistor
over-temperature. Any violation is latched and forces the FAULT mode. The manual stop is also latched and has the
highest priority. The flowchart and the complete tables of modes, faults and alerts are given in
[controller_flowchart.md](controller_flowchart.md).

Two measurement effects shaped the balancing logic:
- **Voltage drop from the balancing current.** While a cell is being bled, its terminal voltage is depressed by the
  product of the bleed current and the cell's internal resistance, about 6 mV here. That is comparable to the
  balancing thresholds. The controller therefore runs a repeating cycle: 60 s of balancing, then 5 s with all
  balancing switches open. The readings taken during the rest interval are averaged and used for the next decision.
  Measuring in the absence of balancing current is established BMS practice [6].
- **Hysteresis.** In passive mode, a cell is bled when its rested voltage exceeds the minimum by more than
  `dV_on`. Bleeding stops when the difference falls to `dV_off` or below. In active mode, the same thresholds apply
  to the pack spread. The band prevents chattering around a single threshold.

### 3.3 Passive balancing

Each cell is paralleled by a bleed resistor switched by a logic-level MOSFET; this is the shunt-resistor method of
[1]. The resistor value was selected by a parametric sweep (Section 5.4). Passive balancing is inhibited while a
low-voltage alert is active, because bleeding healthy cells towards a nearly empty one would reduce pack energy
without benefit.

### 3.4 Active balancing

One flying capacitor is assigned to each adjacent pair of cells, three in total. It is switched alternately across
cell *k* and cell *k*+1 by complementary PWM with a short dead time [3]. Simulating kilohertz switching over hours
would be impractical, so long runs use an averaged representation. Each pair transfers a current
*I* = Δ*V* / *R*<sub>eq</sub> from the higher to the lower cell. Charge is conserved, and the power dissipated is
*I*·Δ*V*. The equivalent resistance is

  *R*<sub>eq</sub> = (1 / *fC*) · (1 + e<sup>−*x*</sup>) / (1 − e<sup>−*x*</sup>),  where *x* = *D* / (*f* · *R*<sub>loop</sub> · *C*).

This expression tends to 1/(*fC*) for slow switching and to 2*R*<sub>loop</sub>/*D* for fast switching, in agreement
with the limits described in [2]. To verify it for the circuit at hand, a separate switch-level model of one stage was
built, containing four switches, a flying capacitor and a pulse generator. Its measured equivalent resistance was
compared with the formula over 10 Hz to 100 kHz (Section 5.6).

The transfer current is proportional to the voltage difference, so a single deeply discharged cell could draw a
large current. The controller therefore limits each pair's average current to `I_sc_max` by gating the PWM in
bursts with duty min(1, `I_sc_max`·*R*<sub>eq</sub>/|Δ*V*|).

### 3.5 Measurement model

Each cell voltage passes through a model of the measurement chain before reaching the controller. The model applies
a gain and offset error (representing residual calibration error), additive noise of 1 mV rms, and quantisation to
the resolution of the 10-bit ATmega328P ADC (4.88 mV per count at a 5 V reference) [8]. Temperatures are quantised
to 0.25 °C. A 16-bit ADS1115 converter [9] was simulated as an alternative.

### 3.6 Test emulator

In line with the safety requirements, a second plant variant replaces the cells with 100 F supercapacitors. Its
voltage limits are scaled to the 2.7 V rating of the capacitors. This variant provides predictions for the first
bench tests, before cells are connected.

### 3.7 Parameter validation

Several parameters are coupled. Examples are the balancing thresholds and the ADC resolution, the bleed resistance
and its power rating and temperature, and the bleed window and the voltage drop it produces. A validation function,
`src/check_params.m`, therefore checks every parameter set before simulation and halts on inconsistent combinations.
Run durations, the resistor sweep, the low-voltage test condition and all figure annotations are derived from the
parameters. Substituting measured hardware values therefore requires no code changes.

---

## 4. Simulation Parameters

The values below are simulation assumptions unless stated otherwise. The final column is provided for recording the
corresponding values of the hardware once components are selected and measured. All values are defined in
`simulation/bms_4cell/src/params_4cell.m`.

**Table 1. Cells and pack.**

| Parameter | Value | Basis | Hardware value |
|---|---|---|---|
| Configuration | 4 in series, generic 18650 Li-ion | problem statement; cell type assumed | |
| Capacity | 2.5 Ah | typical 18650 | |
| Nominal voltage | 3.7 V | Li-ion (NMC/LCO) | |
| Open-circuit voltage | 3.0 / 3.4 / 3.6 / 3.7 / 3.8 / 4.0 / 4.2 V at 0 / 10 / 25 / 50 / 75 / 90 / 100 % SOC | generic curve from reference model | |
| Internal resistance | 33–47 mΩ (32.8 mΩ at 50 % SOC, 20 °C) | scaled from reference model | |
| Initial SOC, cells 1–4 | 80 / 65 / 75 / 70 % | chosen; 107 mV initial spread | |
| Thermal mass; surface area; convection | 45 J/K; 4.2 cm²; 10 W/(m²·K) | 18650 geometry, still air | |
| Ambient temperature | 25 °C | assumed | |
| Charging during trials | none | safety requirement | |

**Table 2. Passive balancing circuit (per cell).**

| Parameter | Value | Basis | Hardware value |
|---|---|---|---|
| Bleed resistance | **22 Ω** | parametric sweep (Section 5.4) | |
| Resistor power rating | 2 W (0.80 W dissipated at 4.2 V) | assumed | |
| Bleed current | ≈ 172 mA | result | |
| MOSFET on-resistance | 50 mΩ | logic-level device, assumed | |
| Resistor thermal resistance; time constant | 70 K/W; 90 s | typical 2 W axial resistor, assumed | |

**Table 3. Active balancing stage (per adjacent pair; three stages).**

| Parameter | Value | Basis | Hardware value |
|---|---|---|---|
| Flying capacitor | **2.2 mF**, ESR 20 mΩ | low-ESR electrolytic, assumed | |
| MOSFET on-resistance | 10 mΩ (two per conduction loop) | assumed | |
| Switching frequency; conduction per phase | 2 kHz; 48 % (2 % dead time) | near the knee of the *R*<sub>eq</sub> curve | |
| Loop resistance | 72.8 mΩ (cells); 90 mΩ (emulator) | 2·*R*<sub>on</sub> + ESR + source resistance | |
| Equivalent resistance | **0.358 Ω** (cells); 0.420 Ω (emulator) | Section 3.4 | |
| Average current limit | 0.5 A | design choice | |

**Table 4. Supercapacitor test emulator.**

| Parameter | Value | Basis | Hardware value |
|---|---|---|---|
| Capacitance per position | 100 F, ESR 50 mΩ | overshoot criterion (Section 6, issue E12) | |
| Initial voltages | 2.50 / 2.20 / 2.40 / 2.30 V | below 2.7 V rating | |
| Voltage limits | under-voltage 0.5 V; low-voltage 1.0 V; over-voltage 2.75 V | scaled to capacitor rating | |
| Balancing / rest window | 5 s / 2 s | overshoot criterion | |

**Table 5. Measurement and controller.**

| Parameter | Value | Basis | Hardware value |
|---|---|---|---|
| Voltage ADC | 10-bit, 5 V reference (4.88 mV per count) | ATmega328P [8] | |
| Voltage noise; gain/offset error | 1 mV rms; 0 | assumed; to be replaced by calibration residuals | |
| Temperature resolution | 0.25 °C | thermistor with ADC, assumed | |
| Control period | 1 s | | |
| Balancing / rest window | 60 s / 5 s | Section 3.2 | |
| Thresholds `dV_on` / `dV_off` | 20 mV / 10 mV (4 and 2 ADC counts) | Section 6, issue E13 | |
| Minimum voltage for bleeding | 3.30 V | assumed | |
| Voltage limits | low-voltage alert 3.30 V; under-voltage fault 3.00 V; over-voltage fault 4.25 V | typical Li-ion | |
| Temperature limits | cell: warning 40 °C, fault 45 °C; resistor: warning 85 °C, fault 100 °C | assumed | |

---

## 5. Results and Discussion

All experiments are defined in `experiments/run_experiments.m`. Table 6 relates each experiment to the requirement
it addresses. Figures are stored in `results/figures/`, summary tables in `results/tables/` and time-series data in
`results/timeseries/`.

**Table 6. Simulated experiments.**

| Experiment | Purpose | Requirement |
|---|---|---|
| no_balancing, passive, active | comparison from identical initial conditions | 3, 4, 5 |
| repeat_1–3, active_repeat_1–3 | repeatability (new noise realisation, ±0.5 % initial SOC) | 5 |
| manual_stop | stop command at 70 min | 2 |
| over_temp | undersized 4.7 Ω bleed resistor | 2 |
| low_voltage, active_low_volt | cell 4 at 3.75 % SOC (3.15 V) | 2 |
| emulator, active_emulator | supercapacitor emulator | safety |
| sweep_R10, R22, R47, R100 | bleed-resistor selection | 3 |
| adc10_tight, adc16 | measurement resolution and thresholds | 1, 6 |
| sc_characterize | switch-level characterisation of one stage | 4 |

### 5.1 Comparison of balancing methods

![Method comparison](../simulation/bms_4cell/results/figures/fig_method_comparison.png)

*Figure 1. Comparison of no balancing, passive balancing and active balancing from identical initial conditions.*

**Table 7. Summary of the comparison (four runs per method).**

| Metric | No balancing | Passive (22 Ω) | Active (switched capacitor) |
|---|---|---|---|
| Voltage spread, initial → final | 107 → 107 mV | 107 → 11 mV | 107 → 11 mV |
| Time to spread ≤ 20 mV | — | 1.55 ± 0.02 h | 1.05 ± 0.02 h |
| Energy dissipated | 0 | 2.05 ± 0.04 Wh (5.5 % of pack) | 0.007 Wh (0.02 %)\* |
| Peak resistor temperature | 25 °C | 69 °C | 25 °C |
| Deliverable charge after balancing | 1.62 Ah | 1.62 Ah | 1.78 Ah |
| Usable capacity per cycle, AH·(1 − SOC spread) | 2.13 Ah | 2.43 Ah | 2.43 Ah |

\* Conduction losses only; see Section 7.

**Both methods reach the same final spread.** Both reduced the voltage spread to about 11 mV, a value set by the
10 mV stop threshold rather than by the method.

**They differ in where the charge goes.** Passive balancing brought every cell down to the level of the lowest
(65 % SOC) and dissipated the difference. Active balancing redistributed charge towards the mean. The deliverable
charge of the pack therefore rose from 1.62 Ah to 1.78 Ah.

**Active balancing was also faster here.** Its initial transfer current (245 mA) exceeded the bleed current
(172 mA). This advantage depends on the chosen component values and is not inherent to the method.

**A note on the capacity metric.** Both methods raise the per-cycle usable capacity from 2.13 Ah to 2.43 Ah. That
quantity describes the capacity available over a full charge–discharge cycle, not the charge available immediately.
Passive balancing increases the former while reducing the latter.

### 5.2 Passive balancing

![Spread and SOC](../simulation/bms_4cell/results/figures/fig_spread_soc.png)

*Figure 2. Voltage spread (rested measurement) and cell SOC during passive balancing.*

![Current and energy](../simulation/bms_4cell/results/figures/fig_current_energy.png)

*Figure 3. Bleed currents and cumulative energy dissipated.*

![Temperature](../simulation/bms_4cell/results/figures/fig_temperature.png)

*Figure 4. Bleed-resistor and cell temperatures.*

Cells 1, 3 and 4 were bled at about 172 mA in 60 s windows, and the bleed resistors settled at 69 °C. Cell
temperatures remained at ambient, since the cells' own resistive heating was of the order of 1 mW. The dissipated
energy of 2.05 Wh is consistent with an independent estimate of about 0.54 Ah removed at a mean voltage of about 3.8 V.

### 5.3 Fault handling

![Fault handling](../simulation/bms_4cell/results/figures/fig_fault_handling.png)

*Figure 5. Manual stop, over-temperature fault and low-voltage alert.*

**Manual stop.** When the stop command was issued at 70 min, all switches opened and the controller entered the
latched STOP mode.

**Over-temperature.** With a 4.7 Ω bleed resistor, the resistor dissipated about 3 W and exceeded 100 °C after 43 s.
The controller entered FAULT, after which the resistor cooled to ambient.

**Low voltage.** With cell 4 at 3.15 V, the low-voltage alert was raised and passive balancing was inhibited, as
intended.

### 5.4 Selection of the bleed resistor

![Resistor sweep](../simulation/bms_4cell/results/figures/fig_resistor_sweep.png)

*Figure 6. Balancing time and peak resistor temperature against bleed resistance.*

**Table 8. Bleed-resistor sweep.**

| Bleed resistance | Balancing time | Peak resistor temperature | Outcome |
|---|---|---|---|
| 10 Ω | — | 100 °C after 148 s | over-temperature fault |
| **22 Ω** | **1.53 h** | **69 °C** | selected |
| 47 Ω | 3.21 h | 46 °C | acceptable, slow |
| 100 Ω | 6.64 h | 35 °C | acceptable, very slow |

The energy dissipated was about 2.04 Wh for every resistor that completed balancing. The charge to be removed is
fixed by the initial imbalance, so the resistance only trades balancing time against temperature. With the assumed
thermal parameters, 10 Ω is not viable. 22 Ω is the lowest value that remains below the warning threshold.

### 5.5 Active balancing

![Active](../simulation/bms_4cell/results/figures/fig_active.png)

*Figure 7. Pair transfer currents and cell voltages during active balancing (top), and recovery of a nearly empty
cell under current limiting (bottom).*

The pair currents began at 245 mA and decayed approximately exponentially as the voltages converged. Because charge
moves only between neighbouring cells, imbalance between cells 1 and 4 must pass through the intermediate cells.
This chain transfer is the principal factor limiting speed.

With cell 4 at 3.75 % SOC, the initial voltage difference of 0.65 V would have produced about 1.8 A. The burst-gating
limit held the average current below 0.5 A. The depleted cell was recharged from the others to 54 % SOC in 10.7 h,
at a cost of 0.16 Wh.

### 5.6 Characterisation of the switched-capacitor stage

![SC characterisation](../simulation/bms_4cell/results/figures/fig_sc_characterisation.png)

*Figure 8. Equivalent resistance against switching frequency, transfer current against voltage difference, and
flying-capacitor waveforms.*

**Table 9. Equivalent resistance: switch-level simulation against the averaged model.**

| Frequency | Switch-level | Averaged model | Deviation |
|---|---|---|---|
| 10 Hz | 45.5 Ω | 45.5 Ω | 0.1 % |
| 1 kHz | 0.543 Ω | 0.543 Ω | 0.1 % |
| 2.15 kHz | 0.414 Ω | 0.414 Ω | 0.1 % |
| 100 kHz | 0.374 Ω | 0.375 Ω | −0.3 % |

The averaged model agrees with the switch-level circuit to within 0.3 % from 10 Hz to 100 kHz. This justifies its use
for the long-duration experiments. The transfer current was linear in the voltage difference, corresponding to
*R*<sub>eq</sub> = 0.420 Ω for the emulator. Transfer efficiency equalled *V*<sub>low</sub>/*V*<sub>high</sub>
(95.8 % at a 100 mV difference), as theory predicts.

### 5.7 Effect of measurement resolution

![ADC resolution](../simulation/bms_4cell/results/figures/fig_adc_resolution.png)

*Figure 9. True SOC spread for different ADC resolutions and thresholds.*

**Table 10. Measurement configurations.**

| Configuration | Balancing time | Final voltage spread |
|---|---|---|
| 10-bit ADC, 20/10 mV (selected) | 1.53 h | 11.9 mV |
| 10-bit ADC, 15/5 mV | 1.75 h | 7.2 mV, with a noise-induced stall |
| 16-bit ADS1115, 10/3 mV | 1.95 h | 4.5 mV |

Tighter thresholds give a smaller final spread, but only when the measurement resolution supports them. With a 10-bit
converter, a 5 mV stop threshold corresponds to a single quantisation step, and noise was sufficient to halt balancing
prematurely (Section 6, issue E13). A 16-bit converter permits a final spread of 4.5 mV.

In the flat region of the OCV curve, even an 11 mV spread corresponds to about 3 % SOC. This illustrates the
limitation of voltage-based balancing noted in [13].

### 5.8 Emulator predictions

![Emulator](../simulation/bms_4cell/results/figures/fig_emulator.png)

*Figure 10. Passive balancing on the supercapacitor emulator.*

On the 100 F emulator, passive balancing completed in 6.2 min and active balancing in 3.0 min. These figures are the
reference predictions for the first bench tests.

### 5.9 Repeatability

**Table 11. Repeatability (four runs per method).**

| Method | Balancing time | Energy dissipated | Final spread |
|---|---|---|---|
| Passive | 1.55 ± 0.02 h | 2.05 ± 0.04 Wh | 11.4 ± 0.6 mV |
| Active | 1.05 ± 0.02 h | 0.0072 ± 0.0000 Wh | 11.0 ± 0.5 mV |

Each repetition used a new noise realisation and initial SOC values perturbed by up to ±0.5 %. The resulting
variation was about 1–2 % in balancing time and below 6 % in final spread, so the comparison in Table 7 is not
sensitive to these factors.

---

## 6. Development Issues and Their Resolution

A number of problems arose during development. They are recorded here because several of them carry design
implications for the hardware.

### 6.1 Issues with design implications

**Controller overshoot on the emulator (E12).** The first emulator configuration used 10 F capacitors and a 10 s
bleed window. A single window lowered a capacitor's voltage by about 110 mV, far more than the 15 mV hysteresis band
then in use. The controller repeatedly overshot the minimum cell, and the resulting limit cycle drained every
capacitor to the low-voltage cut-off. The underlying condition is that the voltage change produced in one control
window must be smaller than the start threshold: *V*/(*R*·*C*)·*t*<sub>on</sub> < `dV_on`. The emulator was
re-dimensioned to 100 F with a 5 s window, and the condition is now enforced by the parameter check.

**Noise-induced stall of passive balancing (E13).** With 15/5 mV thresholds, balancing stopped for about an hour
while one cell remained 13 mV above the minimum. The lowest cell lay on a quantisation boundary. A noise excursion of
one count made the difference appear to be 4.9 mV, which is below the stop threshold. Two changes resolved this:
averaging the readings over the rest interval, and expressing the thresholds as multiples of the ADC resolution
(at least 4 and 2 counts). The original configuration is retained as an experiment because it shows the effect of
measurement resolution.

**Unbounded switched-capacitor current (E17).** Because the transfer current is proportional to the voltage
difference, a nearly empty cell would have drawn 1.6–1.8 A from its neighbours. The average current is now limited
by burst gating. As discussed in Section 7, this does not limit the peak current of individual capacitor pulses.

**Missing dead time in the averaged model (E16).** At high frequency, the switch-level circuit initially showed an
equivalent resistance 4 % above the formula. The discrepancy was traced to the 2 % dead time between phases, which
the original formula did not include. Adding the conduction fraction *D* reduced the deviation to below 0.3 %.

**Measurement during balancing (E14).** The first reading of each rest interval still contained the effect of the
bleed current, because the gate command reaches the switch one control period later. That reading is therefore
excluded from the average.

### 6.2 Modelling and implementation errors

**Table 12. Modelling and implementation errors.**

| No. | Observation | Cause | Resolution |
|---|---|---|---|
| E1 | Reference model reported 74.7 mA mean bleed current against 81 mA expected | Average included solver-noise samples after switch opening | Average taken only while the switch is commanded on (80.8 mA) |
| E2 | Exported figures illegible | Dark desktop theme applied to figures (R2025a and later) | Light theme forced before export |
| E3 | Capacity gain attributed to passive balancing | Per-cycle capacity reported without the deliverable charge | Both quantities reported and defined |
| E6 | Connection errors when wiring Simscape blocks | Physical-port order undocumented; some ports exist only once enabled | Port domains identified by test connection |
| E7, E20 | Invalid block and annotation names | "/" interpreted as a path separator | Names changed; annotation text set separately |
| E8 | Output data type rejected | Relational Operator does not support `double` output | Default type retained |
| E9 | Cell temperature fell to −230 °C | Temperature-source terminals reversed | Terminals corrected |
| E10 | Build error in emulator variant | Deleting a block leaves its connection attached | Connection deleted first |
| E11 | Active mode charged the highest cell; run ended in FAULT | Controlled-current-source polarity reversed | Polarity corrected; charge conservation verified |
| E15 | Negative transfer current in switch-level model | Current sensor reversed | Sensor re-oriented |
| E18 | Current plots unreadable | 60 s / 5 s cycling sampled at 5 s | Cycle-averaged currents plotted |
| E22 | All MOSFET blocks failed to initialise | A script variable named `ee` shadowed the Simscape Electrical package `ee` | Variable renamed |

### 6.3 Toolchain issues

**Table 13. Toolchain issues.**

| No. | Observation | Cause | Resolution |
|---|---|---|---|
| E4 | MATLAB initially believed unavailable | Installed outside the standard location | Located and run in batch mode |
| E5 | Stateflow unavailable for the controller | Not licensed | MATLAB Function block used instead, which also eases porting to C |
| E19 | Name-shadowing warning | Stale model file on the path | Removed before each rebuild |
| E21 | Failed batch run reported as successful | Exit status not propagated | Logs checked for errors explicitly |

The reference model also produces an algebraic-loop warning from its enabled subsystem. This was not corrected,
since that model is retained unchanged. The new model avoids the problem by introducing a one-period delay between
controller and switches, which also represents the real computation latency.

---

## 7. Limitations

The results should be read in the light of the following limitations.

**Assumed parameters.** The parameters in Section 4 are assumed rather than measured. The thermal parameters of the
bleed resistor and the cells are particularly uncertain. The OCV curve is generic and piecewise linear, whereas
practical 18650 cells have a flatter characteristic between 50 and 75 % SOC. This would further reduce the precision
of voltage-based balancing.

**No relaxation dynamics.** The cell model omits RC relaxation branches, so terminal voltage recovers instantaneously
when balancing stops. Real cells relax over minutes, and the adequacy of the 5 s rest interval must be confirmed
experimentally.

**Active losses are a lower bound.** The reported active-balancing loss includes conduction losses only. Gate drive
for twelve MOSFETs switching at 2 kHz, switching transitions, isolated driver supplies and controller consumption are
excluded and would add continuous losses of the order of tens of milliwatts.

**Burst gating limits only the average current.** At a 100 mV difference, individual capacitor current pulses still
reach about 0.85 A. Components must be rated for this peak. Alternatively, the switching frequency could be reduced
as the voltage difference grows, as in the adaptive pulse-frequency scheme of [11].

**Idealised measurement.** Calibration errors were set to zero, and loading of the cells by the measurement circuit
was not modelled.

**Simplified thermal environment.** Thermal coupling between resistors and cells, and the effect of an enclosure,
are not represented.

**Simulated repeatability.** Repeatability was assessed by varying noise and initial conditions only, and does not
capture experimental run-to-run variation.

---

## 8. Conclusions and Future Work

A complete simulation of a four-cell monitoring and balancing system has been developed. It covers all the
functional requirements of Problem Statement 3:
- voltage and temperature monitoring with a realistic measurement model;
- a five-mode controller with alerts, latched faults and a manual stop;
- resistor-based passive balancing;
- switched-capacitor active balancing, supported by a verified averaged model;
- a supercapacitor test emulator;
- a repeatable comparison of the three operating cases.

Under identical initial conditions, both balancing methods reduced the voltage spread from 107 mV to about 11 mV.
Active balancing did so in about two-thirds of the time, with negligible conduction loss, and left more charge in
the pack. Passive balancing dissipated 5.5 % of the pack energy and raised the bleed resistors to 69 °C.

The study yields the following design guidance for the hardware:
- **Bleed resistance:** not below 22 Ω with 2 W resistors of the assumed thermal resistance.
- **Thresholds:** at least 4 and 2 ADC counts when a 10-bit converter is used.
- **Measurement:** taken during a rest interval free of balancing current.
- **Switched-capacitor stage:** current-limited, with components rated for its peak pulse current.
- **Emulator:** dimensioned so that one control window cannot overshoot the hysteresis band.

The next stages of the project are:
1. implementation of `bms_controller.m` in Arduino firmware;
2. preparation of the circuit schematic;
3. emulator tests compared against the predictions of Section 5.8;
4. calibration of the measurement channels against a multimeter.

The measured component values and calibration residuals will then be entered into the model, and all predictions
regenerated for comparison with the cell experiments. Two extensions identified in the recent literature merit
consideration: adaptive switching frequency for the active stage, and hybrid passive–active operation [11].

---

## References

References [1]–[5] were checked against publisher or index records on 13 November 2026. References [10]–[13] were
identified in a literature search on the same date; only their abstracts and bibliographic records were consulted.
References [6]–[9] are cited from standard sources, and their editions and document numbers should be confirmed
before submission.

[1] M. Daowd, N. Omar, P. Van Den Bossche, and J. Van Mierlo, "Passive and active battery balancing comparison based
on MATLAB simulation," in *Proc. 2011 IEEE Vehicle Power and Propulsion Conf. (VPPC)*, Chicago, IL, 2011, pp. 1–7,
doi: 10.1109/VPPC.2011.6043010.

[2] M. D. Seeman and S. R. Sanders, "Analysis and optimization of switched-capacitor DC–DC converters," *IEEE Trans.
Power Electron.*, vol. 23, no. 2, pp. 841–851, Mar. 2008, doi: 10.1109/TPEL.2007.915182.

[3] C. Pascual and P. T. Krein, "Switched capacitor system for automatic series battery equalization," in *Proc. IEEE
Applied Power Electronics Conf. (APEC)*, Atlanta, GA, 1997, vol. 2, pp. 848–854.

[4] J. Gallardo-Lozano, E. Romero-Cadaval, M. I. Milanés-Montero, and M. A. Guerrero-Martínez, "Battery equalization
active methods," *J. Power Sources*, vol. 246, pp. 934–949, 2014, doi: 10.1016/j.jpowsour.2013.08.026.

[5] S. Ben-Yaakov, "Behavioral average modeling and equivalent circuit simulation of switched capacitors converters,"
*IEEE Trans. Power Electron.*, vol. 27, no. 2, pp. 632–636, Feb. 2012, doi: 10.1109/TPEL.2011.2171996.

[6] G. L. Plett, *Battery Management Systems*, vols. I and II. Norwood, MA: Artech House, 2015.

[7] MathWorks, "Battery (Table-Based)," Simscape Battery documentation, R2026a.

[8] Microchip Technology, *ATmega328P Datasheet*.

[9] Texas Instruments, *ADS111x Ultra-Small, Low-Power, I²C-Compatible, 16-Bit ADCs*, datasheet.

[10] "A comprehensive review of the art of cell balancing techniques and trade-offs in battery management systems,"
*Energies*, vol. 18, no. 13, art. 3321, 2025. [Online]. Available: https://www.mdpi.com/1996-1073/18/13/3321

[11] W. C. Lim, L. Siek, and E. L. Tan, "Adaptive hybrid switched-capacitor cell balancing for 4-cell Li-ion battery
pack with a study of pulse-frequency modulation control," *J. Low Power Electron. Appl.*, vol. 15, no. 4, art. 61,
2025, doi: 10.3390/jlpea15040061.

[12] "Dual-platform Arduino and Simulink battery management system," *Int. J. Power Electron. Drive Syst. (IJPEDS)*,
2025. [Online]. Available: https://ijpeds.iaescore.com/index.php/IJPEDS/article/view/24439

[13] "Cell balancing for the transportation sector: techniques, challenges, and future research directions,"
arXiv:2404.13890, 2024. [Online]. Available: https://arxiv.org/abs/2404.13890
