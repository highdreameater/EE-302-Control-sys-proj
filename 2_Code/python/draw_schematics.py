#!/usr/bin/env python3
"""Draw the BMS circuit schematics, block diagram and controller flowchart.

Run from the project root:
    .venv/bin/python hardware/schematics/draw_schematics.py

Writes PNG and SVG files next to this script. The drawings follow hardware/arduino/HARDWARE_SPEC.md and
hardware/arduino/bms_combined/bms_combined.ino. Check the pin and part labels against the real board.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import schemdraw
import schemdraw.elements as elm
from schemdraw import flow

OUT = Path(__file__).resolve().parent
schemdraw.config(fontsize=11, lw=1.3)

NODE_Y = [0, 3.4, 6.8, 10.2, 13.6]          # stack nodes 0 (pack -) .. 4 (pack +)
ADC_PIN = {1: "A0", 2: "A1", 3: "A3", 4: "A2"}


def save(d, name):
    d.save(str(OUT / f"{name}.png"), dpi=200)
    d.save(str(OUT / f"{name}.svg"))
    print("saved", OUT / f"{name}.png")


def cell_stack(d, x=0):
    """Four cells from node 0 to node 4 at x. Returns nothing; nodes are at (x, NODE_Y[k])."""
    d += elm.Ground().at((x, 0))
    for k in range(1, 5):
        d += elm.BatteryCell().at((x, NODE_Y[k - 1])).to((x, NODE_Y[k])).reverse() \
            .label(f"Cell {k}\n18650\n2.6 Ah", loc="bottom", ofst=0.4)
        d += elm.Dot().at((x, NODE_Y[k]))
    d += elm.Label().at((x - 0.2, NODE_Y[4] + 0.5)).label("Pack +\n≈15.9 V", halign="right")


# --------------------------------------------------------------------------- 1. measurement + passive
def measurement_passive():
    with schemdraw.Drawing(show=False) as d:
        d.config(unit=2.5)
        cell_stack(d, 0)

        # passive bleed branches: relay contact + 47 ohm across each cell
        xb = 3.2
        for k in range(1, 5):
            y0, y1 = NODE_Y[k - 1], NODE_Y[k]
            d += elm.Line().at((0, y1)).to((xb, y1))
            if k == 1:
                d += elm.Line().at((0, y0)).to((xb, y0))
            ym = (y0 + y1) / 2
            d += elm.Switch().at((xb, y1)).to((xb, ym + 0.1)).label(f"K{k}\nD{21 + k}", loc="bottom", ofst=0.15)
            d += elm.Resistor().at((xb, ym + 0.1)).to((xb, y0)).label(f"R{k}\n47 Ω\n2 W", loc="bottom", ofst=0.15)

        # dividers to the ADC: 33k from node, 11k to ground
        xd = 7.0
        for k in range(1, 5):
            y = NODE_Y[k]
            d += elm.Line().at((xb, y)).to((xd - 0.9, y))
            d += elm.Resistor().at((xd - 0.9, y)).to((xd + 1.6, y)).label("33 kΩ", loc="top")
            d += elm.Dot().at((xd + 1.6, y))
            d += elm.Resistor().at((xd + 1.6, y)).down(1.7).label("11 kΩ", loc="bottom", ofst=0.1)
            d += elm.Ground()
            d += elm.Line().at((xd + 1.6, y)).to((xd + 3.2, y))
            d += elm.Label().at((xd + 3.3, y)).label(f"→ ADS1115 {ADC_PIN[k]}", halign="left")

        d += elm.Label().at((xd - 2.0, -1.2)).label(
            "ADS1115 (I²C 0x48, GAIN_TWO ±2.048 V) → Arduino Mega SDA/SCL\n"
            "Cell readings ×4.0: v1 = A0,  v2 = A1−A0,  v3 = A3−A1,  v4 = A2−A3\n"
            "K1–K4: 5 V relay module, active-LOW, driven from D22–D25", halign="left", valign="top", fontsize=10)
        d += elm.Label().at((0, -2.6)).label("Measurement and passive balancing", halign="left", fontsize=13)
        save(d, "schematic_passive")


# --------------------------------------------------------------------------- 2. active ladder
def active_ladder():
    with schemdraw.Drawing(show=False) as d:
        d.config(unit=2.5)
        cell_stack(d, 0)
        xr = 4.0                                # relay commons column
        xc = 7.5                                # capacitor column
        mids = []
        for k in range(1, 5):
            y0, y1 = NODE_Y[k - 1], NODE_Y[k]
            ym = (y0 + y1) / 2
            # NC throw to the cell's bottom node, NO throw to its top node
            d += elm.Line().at((0, y1)).to((xr - 1.2, y1))
            if k == 1:
                d += elm.Line().at((0, y0)).to((xr - 1.2, y0))
            sw = elm.SwitchSpdt2(action="close").at((xr, ym)).left().anchor("a")
            d += sw
            d += elm.Line().at(sw.b).to((xr - 1.2, sw.b[1])).to((xr - 1.2, y1 if sw.b[1] > ym else y0))
            d += elm.Line().at(sw.c).to((xr - 1.2, sw.c[1])).to((xr - 1.2, y0 if sw.c[1] < ym else y1))
            d += elm.Label().at((xr + 0.1, ym + 0.75)).label(f"K{4 + k} (D{25 + k})", halign="left", fontsize=10)
            d += elm.Line().at((xr, ym)).to((xc, ym))
            d += elm.Dot().at((xc, ym))
            mids.append(ym)
        d += elm.Label().at((xr - 1.25, NODE_Y[4] + 0.6)).label("NO = upper node, NC = lower node", halign="left", fontsize=10)
        for k in range(3):
            ya, yb = mids[k], mids[k + 1]
            yr = ya + (yb - ya) * 0.45
            d += elm.Resistor().at((xc, ya)).to((xc, yr)).label("4.7 Ω", loc="bottom", ofst=0.15)
            d += elm.Capacitor(polar=True).at((xc, yr)).to((xc, yb)).reverse().label(f"C{k + 1}\n470 µF\n50 V", loc="bottom", ofst=0.2)
        d += elm.Label().at((xc + 1.6, mids[0] - 0.4)).label(
            "Relays released (NC): C1–C3 across cells 1–3\n"
            "Relays energised (NO): C1–C3 across cells 2–4\n"
            "500 ms per position, one shuttle per ~1 s\n"
            "Each SPDT relay acts as a half-bridge across one cell", halign="left", valign="top", fontsize=10)
        d += elm.Label().at((0, -2.6)).label("Active balancing: relay-switched capacitor ladder", halign="left", fontsize=13)
        save(d, "schematic_active")


# --------------------------------------------------------------------------- 3. block diagram
def block_diagram():
    with schemdraw.Drawing(show=False) as d:
        d.config(fontsize=10, unit=1)
        pc = flow.Box(w=2.6, h=1.4).label("PC\nSerial Monitor\nlog + commands").at((0, -0.6))
        d += pc
        mega = flow.Box(w=3.2, h=7.4).label("Arduino\nMega 2560\n\n1 s control loop").at((4.6, -0.6))
        d += mega
        d += flow.Arrow().at(pc.E).to((mega.W[0], pc.E[1])).label("USB\n115200", loc="top", fontsize=9)
        right = mega.E[0] + 1.0
        blocks = [
            ("ADS1115 16-bit ADC\n33k/11k dividers ×4", 2.4, "I²C"),
            ("DS18B20 ×4\n1-Wire", 0.9, "D2"),
            ("Bleed relays K1–K4\n47 Ω per cell", -0.6, "D22–25"),
            ("SC relays K5–K8\n3 × 470 µF ladder", -2.1, "D26–29"),
            ("Fault LED, alert LED,\nbuzzer, stop button", -3.6, "D13 D9 D8 D3"),
        ]
        for text, y, pin in blocks:
            b = flow.Box(w=3.4, h=1.1).label(text).at((right + 1.6, y))
            d += b
            d += flow.Line().at((mega.E[0], y)).to(b.W).label(pin, loc="top", fontsize=9)
        pack = flow.Box(w=2.4, h=5.4).label("4S Li-ion\npack\n18650\n≈15.9 V").at((right + 6.4, 0.15))
        d += pack
        for y in (2.4, 0.9, -0.6, -2.1):
            d += flow.Line().at((right + 5.0, y)).to((pack.W[0], y))
        save(d, "block_diagram")


# --------------------------------------------------------------------------- 4. flowchart
def flowchart():
    with schemdraw.Drawing(show=False) as d:
        d.config(fontsize=10, unit=1.1)
        d += (start := flow.Start(w=3.2, h=1).label("Every 1 s (tick)"))
        d += flow.Arrow().down()
        d += (meas := flow.Box(w=4.6, h=1.2).label("Read 4 cell voltages (ADS1115)\nand 4 temperatures (DS18B20)"))
        d += flow.Arrow().down()
        d += (fchk := flow.Decision(w=6.4, h=2.6, E="yes", S="no").label("OV > 4.35 V, UV < 2.80 V,\nT > 55 °C, sensor fail\nor STOP?"))
        d += flow.Arrow().right(1.4).at(fchk.E)
        d += (latch := flow.Box(w=4.0, h=1.6).label("Latch FAULT\nall outputs off\nLED solid, buzzer on"))
        d += flow.Arrow().down().at(fchk.S)
        d += (alrt := flow.Box(w=4.6, h=1.4).label("Alerts → WARN: cell < 3.30 V,\nT > 45 °C, jump > 30 mV\n(blink LED, alert light, chirp)"))
        d += flow.Arrow().down()
        d += (mode := flow.Decision(w=4.0, h=1.8, E="OFF", S="PASSIVE or ACTIVE").label("Mode?"))
        d += flow.Arrow().right(1.4).at(mode.E)
        d += (idle := flow.Box(w=3.6, h=1.0).label("IDLE: monitor only"))
        d += flow.Arrow().down().at(mode.S)
        d += (ph := flow.Decision(w=4.0, h=1.8, E="RUN", S="REST / IDLE").label("Phase?"))
        d += flow.Arrow().right(1.4).at(ph.E)
        d += (run := flow.Box(w=4.4, h=1.6).label("Keep outputs on\n(passive 10 s, active 30 s)\nthen outputs off → REST"))
        d += flow.Arrow().down().at(ph.S)
        d += (dec := flow.Decision(w=5.6, h=2.4, E="no", S="yes").label("Rested ≥ 3 s and\nspread > 15 mV?\n(stop at ≤ 10 mV)"))
        d += flow.Arrow().right(1.4).at(dec.E)
        d += (wait := flow.Box(w=4.0, h=1.2).label("IDLE:\nbalanced or blocked"))
        d += flow.Arrow().down().at(dec.S)
        d += (go := flow.Box(w=6.2, h=1.6).label("Passive: bleed cells > 15 mV above min\nActive: shuttle C1–C3 every 500 ms\nphase → RUN"))
        d += flow.Arrow().down()
        d += (log := flow.Box(w=4.6, h=1.0).label("Log CSV row (22 columns)"))
        # side boxes return to the log box
        for b in (latch, idle, run, wait):
            d += flow.Line().at(b.E).right(0.6)
            d += flow.Line().toy(log.E[1])
            d += flow.Arrow().tox(log.E[0])
        save(d, "flowchart")


if __name__ == "__main__":
    measurement_passive()
    active_ladder()
    block_diagram()
    flowchart()
