function [bal, mode, alerts, faults, balanced, Vrest, act] = bms_controller(Vm, Tc, Tr, mode_req, stop_btn, C)
%BMS_CONTROLLER  4-cell monitoring + passive/active balancing controller (one Ts tick).
%
% Called once per control period C.Ts from the Simulink MATLAB Function
% block. Written in plain procedural style so it ports line-by-line to the
% Arduino loop() (persistent variables -> static/global variables).
%
% Inputs  Vm(4)     measured cell voltages, V      (after ADC model)
%         Tc(4)     measured cell temperatures, degC
%         Tr(4)     measured bleed-resistor temperatures, degC
%         mode_req  0 = monitor only, 1 = passive balancing, 2 = active balancing
%         stop_btn  manual stop (latched until reset/power cycle)
% Outputs bal(4)    bleed MOSFET gate commands (0/1)
%         mode      0 MONITOR, 1 PASSIVE, 2 ACTIVE, 3 FAULT, 4 STOP
%         alerts    bit0 low voltage, bit1 cell temp warn, bit2 resistor temp warn
%         faults    bit0 under-voltage, bit1 over-voltage, bit2 cell over-temp,
%                   bit3 resistor over-temp   (latched)
%         balanced  1 when the last rested measurement was within dV_on
%         Vrest(4)  last rested (no-current) voltage average used for decisions
%         act(3)    switched-capacitor pair gating 0..1 (pair k = cells k and k+1);
%                   fractions < 1 = burst-mode PWM gating for current limiting
%
% Both balancing modes use the same measure-at-rest cycle:
%   every (n_rest + n_on) s all balancing switches are off for n_rest s, the
%   rested readings are averaged, then a decision is taken for the next
%   n_on s window.
% PASSIVE, for each cell i (hysteresis):
%       V_i - V_min >  dV_on   -> bleed ON
%       V_i - V_min <= dV_off  -> bleed OFF
%       otherwise              -> keep previous decision
%   and never bleed a cell below V_bal_min. Low-voltage alert inhibits it.
% ACTIVE (switched capacitor, charge moves from high to low cell):
%       spread >  dV_on  -> enable all 3 pairs
%       spread <= dV_off -> disable
%   Pair current is |dV_k|/R_eq, so each pair is gated to
%       g_k = min(1, I_sc_max * R_eq / |dV_k|)   (current limit)
%   Allowed during a low-voltage alert because it does not drain the pack.

MONITOR = 0; PASSIVE = 1; ACTIVE = 2; FAULT = 3; STOP = 4;
REST = 0; RUN = 1;

persistent st phase tick sel act_on gate Vh fault_latch bal_flag acc nacc
if isempty(st)
    st = MONITOR; phase = REST; tick = 0;
    sel = zeros(4, 1); act_on = 0; gate = ones(3, 1); Vh = zeros(4, 1); fault_latch = 0; bal_flag = 0;
    acc = zeros(4, 1); nacc = 0;
end

Vm = Vm(:); Tc = Tc(:); Tr = Tr(:);
bal = zeros(4, 1); act = zeros(3, 1);

%% 1. Safety checks (every tick, every mode)
f = 0;
if any(Vm < C.V_uv),       f = bitor(f, 1); end
if any(Vm > C.V_ov),       f = bitor(f, 2); end
if any(Tc > C.T_cell_max), f = bitor(f, 4); end
if any(Tr > C.T_res_max),  f = bitor(f, 8); end
fault_latch = bitor(fault_latch, f);

a = 0;
if min(Vm) < C.V_lv,        a = bitor(a, 1); end
if max(Tc) > C.T_cell_warn, a = bitor(a, 2); end
if max(Tr) > C.T_res_warn,  a = bitor(a, 4); end
lowV = bitand(a, 1) ~= 0;

%% 2. Mode transitions (STOP and FAULT are latched, highest priority)
if stop_btn > 0.5
    st = STOP;
elseif fault_latch > 0 && st ~= STOP
    st = FAULT;
end

if st == MONITOR
    if mode_req == 1 && ~lowV
        st = PASSIVE; phase = REST; tick = 0; sel(:) = 0;
    elseif mode_req == 2
        st = ACTIVE;  phase = REST; tick = 0; act_on = 0;
    end
elseif st == PASSIVE && (mode_req ~= 1 || lowV)
    st = MONITOR;
elseif st == ACTIVE && mode_req ~= 2
    st = MONITOR;
end

%% 3. Balancing cycle (measure at rest, then run for n_on ticks)
if st == PASSIVE || st == ACTIVE
    if phase == REST
        tick = tick + 1;
        % average rested readings; skip tick 1 because commands reach the
        % switches one tick late
        if tick >= 2 || C.n_rest < 2
            acc = acc + Vm; nacc = nacc + 1;
        end
        if tick >= C.n_rest
            Vh = acc / max(nacc, 1);
            acc(:) = 0; nacc = 0;
            Vmin = min(Vh);  spread = max(Vh) - Vmin;
            if st == PASSIVE
                for i = 1:4
                    d = Vh(i) - Vmin;
                    if d > C.dV_on && Vh(i) > C.V_bal_min
                        sel(i) = 1;
                    elseif d <= C.dV_off || Vh(i) <= C.V_bal_min
                        sel(i) = 0;
                    end
                end
            else
                if spread > C.dV_on
                    act_on = 1;
                elseif spread <= C.dV_off
                    act_on = 0;
                end
                for k = 1:3
                    gate(k) = min(1, C.I_sc_max * C.R_eq / max(abs(Vh(k) - Vh(k+1)), 1e-6));
                end
            end
            bal_flag = double(spread <= C.dV_on);
            phase = RUN; tick = 0;
        end
    end
    if phase == RUN
        if st == PASSIVE, bal = sel; else, act = act_on * gate; end
        tick = tick + 1;
        if tick > C.n_on
            phase = REST; tick = 0;
            bal(:) = 0; act(:) = 0;
        end
    end
else
    sel(:) = 0; act_on = 0;      % MONITOR, FAULT, STOP: everything off
end

mode     = double(st);
alerts   = double(a);
faults   = double(fault_latch);
balanced = bal_flag;
Vrest    = Vh;
end
