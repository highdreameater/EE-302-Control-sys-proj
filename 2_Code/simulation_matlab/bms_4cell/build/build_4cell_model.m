function mdl = build_4cell_model(plant)
%BUILD_4CELL_MODEL  Build the 4-cell monitoring + passive/active balancing model.
%
%   build_4cell_model('cell')      -> models/BMS4Cell.slx           (18650 cells)
%   build_4cell_model('emulator')  -> models/BMS4Cell_Emulator.slx  (supercap emulator)
%
% The model is generated from code so it can always be rebuilt identically.
% Block parameters reference the structs P and C (see params_4cell.m);
% the model InitFcn creates them if they are not in the base workspace.
%
% Top level:
%   Mode request, Manual stop  -> BMS Controller
%   Battery Pack + Bleed Circuit (Simscape, incl. averaged SC equaliser) -> V, I, SOC, T_cell, I_sc
%   Resistor Thermal Model, Energy Metrics (Simulink)
%   ZOH -> ADC / Sensors -> BMS Controller -> 1-tick delay -> gate drives

if nargin < 1, plant = 'cell'; end
isCell = strcmp(plant, 'cell');
if isCell, mdl = 'BMS4Cell'; else, mdl = 'BMS4Cell_Emulator'; end
root = fileparts(fileparts(mfilename('fullpath')));      % simulation/bms_4cell
modelDir = fullfile(root, 'models'); if ~isfolder(modelDir), mkdir(modelDir); end
[P, C] = params_4cell(plant);
assignin('base', 'P', P); assignin('base', 'C', C);

if bdIsLoaded(mdl), close_system(mdl, 0); end
f = fullfile(modelDir, [mdl '.slx']); if isfile(f), delete(f); end
new_system(mdl); load_system(mdl);
N = 4;

%% ======================= Plant subsystem (Simscape) ======================
pk = [mdl '/Battery Pack + Bleed Circuit'];   % also holds the switched-capacitor equaliser
add_block('simulink/Ports & Subsystems/Subsystem', pk, 'Position', [520 300 720 460]);
delete_line(pk, 'In1/1', 'Out1/1'); delete_block([pk '/In1']); delete_block([pk '/Out1']);
add_block('simulink/Sources/In1', [pk '/gate'], 'Position', [20 400 50 414]);
add_block('simulink/Signal Routing/Demux', [pk '/Demux'], 'Outputs', '4', 'Position', [90 330 95 480]);
add_line(pk, 'gate/1', 'Demux/1');
add_block('simulink/Sources/In1', [pk '/act_en'], 'Position', [1700 100 1730 114]);
add_block('simulink/Signal Routing/Demux', [pk '/Demux_act'], 'Outputs', '3', 'Position', [1770 60 1775 160]);
add_line(pk, 'act_en/1', 'Demux_act/1');
outs = {'V_cell', 'I_bleed', 'SOC', 'T_cell', 'I_act'};
for k = 1:5
    y = 120 + 200*k;
    add_block('simulink/Signal Routing/Mux', [pk '/Mux_' outs{k}], 'Inputs', num2str(4 - (k == 5)), ...
        'Position', [1500 y 1505 y+120]);
    add_block('simulink/Sinks/Out1', [pk '/' outs{k}], 'Position', [1560 y+53 1590 y+67]);
    add_line(pk, ['Mux_' outs{k} '/1'], [outs{k} '/1']);
end

ph = @(b) get_param([pk '/' b], 'PortHandles');
pc = @(a, b) add_line(pk, a, b, 'autorouting', 'on');

add_block('fl_lib/Electrical/Electrical Elements/Electrical Reference', [pk '/GND'], 'Position', [300 1900 330 1930]);
add_block('nesl_utility/Solver Configuration', [pk '/Solver Configuration'], 'Position', [180 1900 230 1930]);
pc(ph('Solver Configuration').RConn, ph('GND').LConn);

if isCell
    % ambient temperature node
    add_block('fl_lib/Thermal/Thermal Elements/Thermal Reference', [pk '/TREF'], 'Position', [1300 1900 1330 1930]);
    add_block('fl_lib/Thermal/Thermal Sources/Ideal Temperature Source', [pk '/Ambient'], 'Position', [1150 1820 1190 1860]);
    add_block('simulink/Sources/Constant', [pk '/T_amb'], 'Value', 'P.T_amb', 'Position', [950 1825 1000 1855]);
    add_block('nesl_utility/Simulink-PS Converter', [pk '/S-PS T_amb'], 'Position', [1050 1830 1070 1850]);
    set_param([pk '/S-PS T_amb'], 'Unit', 'degC', 'AffineConversion', 'on');
    add_line(pk, 'T_amb/1', 'S-PS T_amb/1');
    pc(ph('S-PS T_amb').RConn, ph('Ambient').RConn(1));     % S
    pc(ph('Ambient').RConn(2), ph('TREF').LConn);           % B -> reference, A = ambient node
end

prevPos = ph('GND').LConn;                                  % stack bottom
for i = 1:N
    y0 = 1700 - 400*i;  s = num2str(i);
    cb = ['Cell' s];
    if isCell
        add_block('batteryecm_lib/Battery (Table-Based)', [pk '/' cb], 'Position', [300 y0 380 y0+80]);
        set_param([pk '/' cb], ...
            'SOC_port', 'simscape.enum.tablebattery.enable.yes', ...
            'thermal_port', 'simscape.enum.thermaleffects.model', ...
            'T_dependence', 'simscape.enum.tablebattery.temperature_dependence.yes', ...
            'prm_dir', 'simscape.enum.tablebattery.prm_dir.noCurrentDirectionality', ...
            'prm_dyn', 'simscape.enum.tablebattery.prm_dyn.off', ...
            'AH', 'P.AH', 'SOC_vec', 'P.SOC_vec', 'T_vec', 'P.T_vec', 'T_vec_unit', 'K', ...
            'V0_mat', 'P.V0_mat', 'R0_mat', 'P.R0_mat', ...
            'thermal_mass', 'P.Cth_cell', ...
            'stateOfCharge_specify', 'on', 'stateOfCharge_priority', 'High', ...
            'stateOfCharge', sprintf('P.SOC0(%d)', i), ...
            'cell_temperature_specify', 'on', 'cell_temperature_priority', 'High', ...
            'cell_temperature', 'P.T_amb + 273.15', 'cell_temperature_unit', 'K');
        bp = ph(cb); pPos = bp.LConn(1); pNeg = bp.RConn(1); pSOC = bp.LConn(2); pH = bp.RConn(2);
    else
        add_block('fl_lib/Electrical/Electrical Elements/Capacitor', [pk '/' cb], 'Position', [300 y0 340 y0+60]);
        set_param([pk '/' cb], 'c', 'P.C_emu', 'r', 'P.ESR_emu', 'g', '0', ...
            'vc_specify', 'on', 'vc_priority', 'High', 'vc', sprintf('P.Vc0_emu(%d)', i));
        bp = ph(cb); pPos = bp.LConn(1); pNeg = bp.RConn(1);
    end
    pc(prevPos, pNeg); prevPos = pPos;                       % series stack
    posH(i) = pPos; negH(i) = pNeg;                          %#ok<AGROW>

    % voltage sensor across the cell
    add_block('fl_lib/Electrical/Electrical Sensors/Voltage Sensor', [pk '/VS' s], 'Position', [520 y0 560 y0+40]);
    vs = ph(['VS' s]); pc(pPos, vs.LConn(1)); pc(pNeg, vs.RConn(2));
    vOut(i) = vs.RConn(1);                                   %#ok<AGROW>
    addPS2SL(pk, ['V' s], vs.RConn(1), 'V', [600 y0+10], 'Mux_V_cell', i);

    % bleed branch:  + -> R_bleed -> current sensor -> MOSFET -> -
    add_block('fl_lib/Electrical/Electrical Elements/Resistor', [pk '/R_bleed' s], 'R', 'P.R_bleed', 'Position', [700 y0+100 740 y0+120]);
    add_block('fl_lib/Electrical/Electrical Sensors/Current Sensor', [pk '/CS' s], 'Position', [800 y0+90 840 y0+130]);
    add_block('ee_lib/Semiconductors & Converters/Ideal Semiconductor Switch', [pk '/Q' s], 'Position', [900 y0+90 940 y0+130]);
    set_param([pk '/Q' s], 'Ron', 'P.R_on', 'Goff', '1e-6', 'Vth', '0.5');
    rb = ph(['R_bleed' s]); cs = ph(['CS' s]); q = ph(['Q' s]);
    pc(pPos, rb.LConn); pc(rb.RConn, cs.LConn(1)); pc(cs.RConn(2), q.RConn(1)); pc(q.RConn(2), pNeg);
    addPS2SL(pk, ['I' s], cs.RConn(1), 'A', [880 y0+170], 'Mux_I_bleed', i);
    add_block('nesl_utility/Simulink-PS Converter', [pk '/S-PS gate' s], 'Position', [820 y0+40 840 y0+60]);
    add_line(pk, sprintf('Demux/%d', i), ['S-PS gate' s '/1'], 'autorouting', 'on');
    pc(ph(['S-PS gate' s]).RConn, q.LConn);

    if isCell
        addPS2SL(pk, ['SOC' s], pSOC, '1', [450 y0-40], 'Mux_SOC', i);
        add_block('fl_lib/Thermal/Thermal Elements/Convective Heat Transfer', [pk '/Conv' s], ...
            'area', 'P.A_cell', 'heat_tr_coeff', 'P.h_conv', 'Position', [1100 y0+200 1140 y0+230]);
        add_block('fl_lib/Thermal/Thermal Sensors/Ideal Temperature Sensor', [pk '/TS' s], 'Position', [1100 y0+260 1140 y0+300]);
        cv = ph(['Conv' s]); ts = ph(['TS' s]); amb = ph('Ambient');
        pc(pH, cv.LConn); pc(cv.RConn, amb.LConn);               % cell -> convection -> ambient
        pc(pH, ts.LConn); pc(ts.RConn(1), ph('TREF').LConn);
        addPS2SL(pk, ['Tc' s], ts.RConn(2), 'degC', [1200 y0+270], 'Mux_T_cell', i);
    end
end
% ---- Active balancing: averaged switched-capacitor equaliser -------------
% Pair k moves I_k = en_k * (V_k - V_k+1) / R_eq from cell k to cell k+1
% (see sc_req.m). Modelled as one controlled current source across each
% cell carrying its net balancing discharge current:
%   cell1: I1   cell2: I2 - I1   cell3: I3 - I2   cell4: -I3
% Done in the physical-signal domain to avoid an algebraic loop.
PSb = 'fl_lib/Physical Signals/Functions/';
for k = 1:3
    x0 = 1850; y0 = 60 + 260*k; s = num2str(k);
    add_block([PSb 'PS Subtract'], [pk '/dV' s], 'Position', [x0 y0 x0+30 y0+30]);
    add_block('nesl_utility/Simulink-PS Converter', [pk '/S-PS en' s], 'Position', [x0 y0+60 x0+20 y0+80]);
    add_block([PSb 'PS Product'], [pk '/en x dV' s], 'Position', [x0+80 y0+20 x0+110 y0+50]);
    add_block([PSb 'PS Gain'], [pk '/1 over Req' s], 'gain', '1/P.R_eq', 'gain_unit', '1/Ohm', ...
        'Position', [x0+160 y0+20 x0+200 y0+50]);
    d = ph(['dV' s]); e = ph(['S-PS en' s]); m = ph(['en x dV' s]); g = ph(['1 over Req' s]);
    pc(vOut(k), d.LConn(1)); pc(vOut(k+1), d.LConn(2));
    add_line(pk, sprintf('Demux_act/%d', k), ['S-PS en' s '/1'], 'autorouting', 'on');
    pc(d.RConn, m.LConn(1)); pc(e.RConn, m.LConn(2)); pc(m.RConn, g.LConn);
    Ik(k) = g.RConn;                                          %#ok<AGROW>
    addPS2SL(pk, ['Iact' s], g.RConn, 'A', [x0+260 y0+25], 'Mux_I_act', k);
end
for i = 1:N
    x0 = 2300; y0 = 60 + 260*i; s = num2str(i);
    add_block('fl_lib/Electrical/Electrical Sources/Controlled Current Source', [pk '/I_sc' s], ...
        'Position', [x0+120 y0 x0+160 y0+40]);
    cs = ph(['I_sc' s]);
    if i == 1
        pc(Ik(1), cs.RConn(1));
    elseif i == N
        add_block([PSb 'PS Gain'], [pk '/neg I3'], 'gain', '-1', 'Position', [x0 y0 x0+40 y0+30]);
        pc(Ik(3), ph('neg I3').LConn); pc(ph('neg I3').RConn, cs.RConn(1));
    else
        add_block([PSb 'PS Subtract'], [pk '/net' s], 'Position', [x0 y0 x0+30 y0+30]);
        n = ph(['net' s]); pc(Ik(i), n.LConn(1)); pc(Ik(i-1), n.LConn(2)); pc(n.RConn, cs.RConn(1));
    end
    pc(posH(i), cs.RConn(2)); pc(cs.LConn, negH(i));        % positive signal discharges the cell
end

if ~isCell
    % emulator: SOC := V / V_rated_emu (fraction of rated voltage), T_cell = ambient
    add_block('simulink/Math Operations/Gain', [pk '/V to frac'], 'Gain', '1/P.V_rated_emu', 'Position', [1400 360 1440 390]);
    add_line(pk, 'Mux_V_cell/1', 'V to frac/1', 'autorouting', 'on');
    delete_line(pk, 'Mux_SOC/1', 'SOC/1'); delete_block([pk '/Mux_SOC']);
    add_line(pk, 'V to frac/1', 'SOC/1', 'autorouting', 'on');
    delete_line(pk, 'Mux_T_cell/1', 'T_cell/1'); delete_block([pk '/Mux_T_cell']);
    add_block('simulink/Sources/Constant', [pk '/T_amb x4'], 'Value', 'P.T_amb*ones(4,1)', 'Position', [1400 1000 1460 1030]);
    add_line(pk, 'T_amb x4/1', 'T_cell/1', 'autorouting', 'on');
end

%% ======================= Resistor thermal model ==========================
rt = [mdl '/Resistor Thermal Model'];
mkSub(rt, [820 520 1000 600], {'I_bleed'}, {'P_res', 'T_res'});
add_block('simulink/Math Operations/Product', [rt '/I_sq'], 'Inputs', '2', 'Multiplication', 'Element-wise(.*)', 'Position', [120 40 150 80]);
add_block('simulink/Math Operations/Gain', [rt '/R_bleed'], 'Gain', 'P.R_bleed', 'Position', [200 45 250 75]);
add_block('simulink/Math Operations/Gain', [rt '/Rth'], 'Gain', 'P.Rth_res', 'Position', [300 45 350 75]);
add_block('simulink/Math Operations/Sum', [rt '/Sum'], 'Inputs', '+-', 'Position', [400 50 420 70]);
add_block('simulink/Math Operations/Gain', [rt '/inv_tau'], 'Gain', '1/P.tau_res', 'Position', [460 45 510 75]);
add_block('simulink/Continuous/Integrator', [rt '/dT rise'], 'Position', [560 45 590 75]);
add_block('simulink/Math Operations/Bias', [rt '/+T_amb'], 'Bias', 'P.T_amb', 'Position', [640 45 690 75]);
L = @(a, b) add_line(rt, a, b, 'autorouting', 'on');
L('I_bleed/1', 'I_sq/1'); L('I_bleed/1', 'I_sq/2'); L('I_sq/1', 'R_bleed/1'); L('R_bleed/1', 'Rth/1');
L('R_bleed/1', 'P_res/1'); L('Rth/1', 'Sum/1'); L('Sum/1', 'inv_tau/1'); L('inv_tau/1', 'dT rise/1');
L('dT rise/1', 'Sum/2'); L('dT rise/1', '+T_amb/1'); L('+T_amb/1', 'T_res/1');

%% ======================= Energy metrics ==================================
em = [mdl '/Energy Metrics'];
mkSub(em, [820 640 1000 760], {'P_res', 'V_cell', 'I_bleed', 'I_act'}, {'E_res_Wh', 'E_res_total_Wh', 'E_drawn_Wh', 'E_act_loss_Wh'});
add_block('simulink/Continuous/Integrator', [em '/Int P_res'], 'Position', [150 30 180 60]);
add_block('simulink/Math Operations/Gain', [em '/J to Wh'], 'Gain', '1/3600', 'Position', [230 30 270 60]);
add_block('simulink/Math Operations/Sum of Elements', [em '/Total'], 'Position', [320 80 350 110]);
add_block('simulink/Math Operations/Product', [em '/VxI'], 'Inputs', '2', 'Multiplication', 'Element-wise(.*)', 'Position', [100 150 130 190]);
add_block('simulink/Continuous/Integrator', [em '/Int P_drawn'], 'Position', [150 155 180 185]);
add_block('simulink/Math Operations/Gain', [em '/J to Wh 2'], 'Gain', '1/3600', 'Position', [230 155 270 185]);
L = @(a, b) add_line(em, a, b, 'autorouting', 'on');
L('P_res/1', 'Int P_res/1'); L('Int P_res/1', 'J to Wh/1'); L('J to Wh/1', 'E_res_Wh/1');
L('J to Wh/1', 'Total/1'); L('Total/1', 'E_res_total_Wh/1');
L('V_cell/1', 'VxI/1'); L('I_bleed/1', 'VxI/2'); L('VxI/1', 'Int P_drawn/1');
L('Int P_drawn/1', 'J to Wh 2/1'); L('J to Wh 2/1', 'E_drawn_Wh/1');
% switched-capacitor loss: P = R_eq * sum(I_k^2)
add_block('simulink/Math Operations/Product', [em '/Iact_sq'], 'Inputs', '2', 'Multiplication', 'Element-wise(.*)', 'Position', [100 330 130 370]);
add_block('simulink/Math Operations/Sum of Elements', [em '/Sum Iact_sq'], 'Position', [160 335 190 365]);
add_block('simulink/Math Operations/Gain', [em '/R_eq'], 'Gain', 'P.R_eq', 'Position', [220 335 260 365]);
add_block('simulink/Continuous/Integrator', [em '/Int P_act'], 'Position', [300 335 330 365]);
add_block('simulink/Math Operations/Gain', [em '/J to Wh 3'], 'Gain', '1/3600', 'Position', [380 335 420 365]);
L('I_act/1', 'Iact_sq/1'); L('I_act/1', 'Iact_sq/2'); L('Iact_sq/1', 'Sum Iact_sq/1'); L('Sum Iact_sq/1', 'R_eq/1');
L('R_eq/1', 'Int P_act/1'); L('Int P_act/1', 'J to Wh 3/1'); L('J to Wh 3/1', 'E_act_loss_Wh/1');

%% ======================= Sensors (ADC) + Controller ======================
add_block('simulink/Discrete/Zero-Order Hold', [mdl '/ZOH V'], 'SampleTime', 'C.Ts', 'Position', [820 300 850 330]);
add_block('simulink/Discrete/Zero-Order Hold', [mdl '/ZOH Tc'], 'SampleTime', 'C.Ts', 'Position', [820 420 850 450]);
add_block('simulink/Discrete/Zero-Order Hold', [mdl '/ZOH Tr'], 'SampleTime', 'C.Ts', 'Position', [1060 560 1090 590]);
add_block('simulink/Sources/Random Number', [mdl '/ADC noise'], 'Mean', 'zeros(4,1)', ...
    'Variance', 'P.noise_V^2*ones(4,1)', 'Seed', 'P.seed', 'SampleTime', 'C.Ts', 'Position', [1060 180 1100 210]);

adc = [mdl '/Sensors (ADC model)'];
add_block('simulink/User-Defined Functions/MATLAB Function', adc, 'Position', [1160 280 1320 440]);
setMLFcn(adc, sprintf(['function [Vm, Tcm, Trm] = sensors(V, Tc, Tr, noise, C)\n' ...
    '%% Measurement chain: calibration error + noise + ADC quantisation\n' ...
    '[Vm, Tcm, Trm] = adc_measure(V, Tc, Tr, noise, C);\n']), {'C'});

ctl = [mdl '/BMS Controller'];
add_block('simulink/User-Defined Functions/MATLAB Function', ctl, 'Position', [1420 280 1620 480]);
setMLFcn(ctl, sprintf(['function [bal, mode, alerts, faults, balanced, Vrest, act] = controller(Vm, Tc, Tr, mode_req, stop_btn, C)\n' ...
    '%% Monitoring, passive/active balancing, alerts, faults, manual stop (see bms_controller.m)\n' ...
    '[bal, mode, alerts, faults, balanced, Vrest, act] = bms_controller(Vm, Tc, Tr, mode_req, stop_btn, C);\n']), {'C'});

add_block('simulink/Sources/Constant', [mdl '/Mode request'], 'Value', 'P.mode_req', 'Position', [1250 500 1310 530]);
add_block('simulink/Sources/Clock', [mdl '/Clock'], 'Position', [1160 560 1180 580]);
add_block('simulink/Sources/Constant', [mdl '/t_stop'], 'Value', 'P.t_stop', 'Position', [1160 600 1200 620]);
add_block('simulink/Logic and Bit Operations/Relational Operator', [mdl '/Manual stop'], 'Operator', '>=', ...
    'Position', [1250 560 1290 610]);
add_block('simulink/Discrete/Unit Delay', [mdl '/1-tick delay'], 'SampleTime', 'C.Ts', ...
    'InitialCondition', 'zeros(4,1)', 'Position', [1700 290 1740 320]);
add_block('simulink/Discrete/Unit Delay', [mdl '/1-tick delay act'], 'SampleTime', 'C.Ts', ...
    'InitialCondition', 'zeros(3,1)', 'Position', [1700 460 1740 490]);

L = @(a, b) add_line(mdl, a, b, 'autorouting', 'on');
plantB = 'Battery Pack + Bleed Circuit';
L([plantB '/1'], 'ZOH V/1'); L([plantB '/4'], 'ZOH Tc/1');
L([plantB '/2'], 'Resistor Thermal Model/1'); L('Resistor Thermal Model/2', 'ZOH Tr/1');
L('Resistor Thermal Model/1', 'Energy Metrics/1'); L([plantB '/1'], 'Energy Metrics/2'); L([plantB '/2'], 'Energy Metrics/3');
L('ZOH V/1', 'Sensors (ADC model)/1'); L('ZOH Tc/1', 'Sensors (ADC model)/2');
L('ZOH Tr/1', 'Sensors (ADC model)/3'); L('ADC noise/1', 'Sensors (ADC model)/4');
for k = 1:3, L(sprintf('Sensors (ADC model)/%d', k), sprintf('BMS Controller/%d', k)); end
L('Mode request/1', 'BMS Controller/4');
L('Clock/1', 'Manual stop/1'); L('t_stop/1', 'Manual stop/2'); L('Manual stop/1', 'BMS Controller/5');
L('BMS Controller/1', '1-tick delay/1'); L('1-tick delay/1', [plantB '/1']);
L('BMS Controller/7', '1-tick delay act/1'); L('1-tick delay act/1', [plantB '/2']);
L([plantB '/5'], 'Energy Metrics/4');

%% ======================= Logging =========================================
logs = { ...   % name, source, sample time
    'V_cell',      [plantB '/1'],              'P.log_dt'
    'I_bleed',     [plantB '/2'],              'P.log_dt'
    'SOC',         [plantB '/3'],              'P.log_dt'
    'T_cell',      [plantB '/4'],              'P.log_dt'
    'P_res',       'Resistor Thermal Model/1', 'P.log_dt'
    'T_res',       'Resistor Thermal Model/2', 'P.log_dt'
    'E_res_Wh',    'Energy Metrics/1',         'P.log_dt'
    'E_res_tot_Wh','Energy Metrics/2',         'P.log_dt'
    'E_drawn_Wh',  'Energy Metrics/3',         'P.log_dt'
    'E_act_loss_Wh','Energy Metrics/4',        'P.log_dt'
    'I_act',       [plantB '/5'],              'P.log_dt'
    'V_meas',      'Sensors (ADC model)/1',    'C.Ts'
    'bal_cmd',     'BMS Controller/1',         'C.Ts'
    'mode',        'BMS Controller/2',         'C.Ts'
    'alerts',      'BMS Controller/3',         'C.Ts'
    'faults',      'BMS Controller/4',         'C.Ts'
    'balanced',    'BMS Controller/5',         'C.Ts'
    'V_rest',      'BMS Controller/6',         'C.Ts'
    'act_cmd',     'BMS Controller/7',         'C.Ts'};
for k = 1:size(logs, 1)
    y = 820 + 45*k;
    add_block('simulink/Sinks/To Workspace', [mdl '/log ' logs{k, 1}], 'VariableName', logs{k, 1}, ...
        'SaveFormat', 'Timeseries', 'SampleTime', logs{k, 3}, 'Position', [1900 y 1990 y+25]);
    L(logs{k, 2}, ['log ' logs{k, 1} '/1']);
end

%% ======================= Annotations & configuration =====================
note = Simulink.Annotation([mdl '/model_note']);       % text set below ('/' is not allowed in the name)
note.Text = sprintf(['EE302 PS-3: 4-cell monitoring + passive & active balancing (%s plant)\n' ...
    'Parameters: src/params_4cell.m  |  Controller: src/bms_controller.m  |  Run: run_all.m'], plant);
note.Position = [520 200 1300 240]; note.FontSize = 14;

set_param(mdl, 'StopTime', 'P.StopTime', 'Solver', 'daessc', 'MaxStep', '10', 'RelTol', '1e-4', ...
    'ReturnWorkspaceOutputs', 'on', 'AlgebraicLoopMsg', 'error', ...
    'InitFcn', sprintf(['addpath(fullfile(fileparts(get_param(bdroot, ''FileName'')), ''..'', ''src'')); ' ...
    'if ~exist(''P'',''var'') || ~exist(''C'',''var''), [P, C] = params_4cell(''%s''); end'], plant));
save_system(mdl, f);
fprintf('Built %s\n', f);
end

%% ---------------------------------------------------------------- helpers
function addPS2SL(sys, name, psPort, unit, xy, mux, idx)
blk = [sys '/PS-S ' name];
add_block('nesl_utility/PS-Simulink Converter', blk, 'Position', [xy(1) xy(2) xy(1)+20 xy(2)+20]);
set_param(blk, 'Unit', unit);
if strcmp(unit, 'degC'), set_param(blk, 'AffineConversion', 'on'); end
h = get_param(blk, 'PortHandles');
add_line(sys, psPort, h.LConn, 'autorouting', 'on');
add_line(sys, ['PS-S ' name '/1'], sprintf('%s/%d', mux, idx), 'autorouting', 'on');
end

function mkSub(path, pos, ins, outs)
add_block('simulink/Ports & Subsystems/Subsystem', path, 'Position', pos);
delete_line(path, 'In1/1', 'Out1/1'); delete_block([path '/In1']); delete_block([path '/Out1']);
for k = 1:numel(ins)
    add_block('simulink/Sources/In1', [path '/' ins{k}], 'Position', [20 40+110*(k-1) 50 54+110*(k-1)]);
end
for k = 1:numel(outs)
    add_block('simulink/Sinks/Out1', [path '/' outs{k}], 'Position', [760 40+110*(k-1) 790 54+110*(k-1)]);
end
end

function setMLFcn(blk, code, params)
ch = find(sfroot, '-isa', 'Stateflow.EMChart', 'Path', blk);
ch.Script = code;
for k = 1:numel(params)
    d = ch.find('-isa', 'Stateflow.Data', 'Name', params{k});
    d.Scope = 'Parameter';
end
end
