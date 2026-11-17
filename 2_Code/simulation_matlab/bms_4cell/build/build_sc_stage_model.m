function build_sc_stage_model(mdl)
%BUILD_SC_STAGE_MODEL  Switch-level model of ONE switched-capacitor stage
% between two adjacent cells -> models/<mdl>.slx (default SC_Stage_Detail).
%
%     n2 ──┬── Sb1 ──┐            phase A: Sa1 + Sa2 on  -> Cf across cell 1
%     cell2│         a            phase B: Sb1 + Sb2 on  -> Cf across cell 2
%     n1 ──┼── Sa1 ──┘  Cf        (duty P.duty_sc each, rest is dead time)
%          ├── Sb2 ──┐
%     cell1│         b
%     n0 ──┴── Sa2 ──┘
%
% Cells are emulator supercapacitors. Parameters come from the base
% workspace struct Pd (set by sc_characterize: Pd.f, Pd.V1, Pd.V2, Pd.Tend).
if nargin < 1, mdl = 'SC_Stage_Detail'; end
modelDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'models');
if ~isfolder(modelDir), mkdir(modelDir); end
if bdIsLoaded(mdl), close_system(mdl, 0); end
f = fullfile(modelDir, [mdl '.slx']); if isfile(f), delete(f); end
new_system(mdl); load_system(mdl);
ph = @(b) get_param([mdl '/' b], 'PortHandles');
pc = @(a, b) add_line(mdl, a, b, 'autorouting', 'on');
E = 'fl_lib/Electrical/';
add_block([E 'Electrical Elements/Electrical Reference'], [mdl '/GND'], 'Position', [100 600 130 630]);
add_block('nesl_utility/Solver Configuration', [mdl '/Solver'], 'Position', [20 600 70 630]);
pc(ph('Solver').RConn, ph('GND').LConn);
% two emulator cells (big supercaps: voltage ~ constant over a few ms)
add_block([E 'Electrical Elements/Capacitor'], [mdl '/Cell1'], 'c', 'Pd.C_emu', 'r', 'Pd.ESR_emu', 'g', '0', ...
    'vc_specify', 'on', 'vc_priority', 'High', 'vc', 'Pd.V1', 'Position', [100 400 140 460]);
add_block([E 'Electrical Elements/Capacitor'], [mdl '/Cell2'], 'c', 'Pd.C_emu', 'r', 'Pd.ESR_emu', 'g', '0', ...
    'vc_specify', 'on', 'vc_priority', 'High', 'vc', 'Pd.V2', 'Position', [100 200 140 260]);
c1 = ph('Cell1'); c2 = ph('Cell2');
n0 = c1.RConn; n1 = c1.LConn; pc(n0, ph('GND').LConn); pc(n1, c2.RConn); n2 = c2.LConn;
% current sensors at the cell-1 and cell-2 taps of the stage
add_block([E 'Electrical Sensors/Current Sensor'], [mdl '/CS_in'], 'Position', [250 380 290 420]);
add_block([E 'Electrical Sensors/Current Sensor'], [mdl '/CS_out'], 'Position', [250 180 290 220]);
add_block([E 'Electrical Sensors/Current Sensor'], [mdl '/CS_cf'], 'Position', [700 280 740 320]);
add_block([E 'Electrical Elements/Capacitor'], [mdl '/Cf'], 'c', 'Pd.C_fly', 'r', 'Pd.ESR_fly', 'g', '0', ...
    'vc_specify', 'on', 'vc_priority', 'High', 'vc', '(Pd.V1+Pd.V2)/2', 'Position', [800 280 840 340]);
add_block([E 'Electrical Sensors/Voltage Sensor'], [mdl '/VS_cf'], 'Position', [900 280 940 320]);
sw = {'Sa1', 'Sa2', 'Sb1', 'Sb2'};
for k = 1:4
    add_block('ee_lib/Semiconductors & Converters/Ideal Semiconductor Switch', [mdl '/' sw{k}], ...
        'Ron', 'Pd.R_on_sc', 'Goff', '1e-9', 'Vth', '0.5', 'Position', [450 100+120*k 490 140+120*k]);
end
add_block('nesl_utility/Simulink-PS Converter', [mdl '/gA'], 'Position', [380 120 400 140]);
add_block('nesl_utility/Simulink-PS Converter', [mdl '/gB'], 'Position', [380 160 400 180]);
add_block('simulink/Sources/Pulse Generator', [mdl '/PWM A'], 'Period', '1/Pd.f', 'PulseWidth', 'Pd.duty_sc*100', ...
    'PhaseDelay', '0', 'Position', [260 110 300 140]);
add_block('simulink/Sources/Pulse Generator', [mdl '/PWM B'], 'Period', '1/Pd.f', 'PulseWidth', 'Pd.duty_sc*100', ...
    'PhaseDelay', '0.5/Pd.f', 'Position', [260 160 300 190]);
add_line(mdl, 'PWM A/1', 'gA/1'); add_line(mdl, 'PWM B/1', 'gB/1');
s = @(n) ph(n);
pc(s('gA').RConn, s('Sa1').LConn); pc(s('gA').RConn, s('Sa2').LConn);
pc(s('gB').RConn, s('Sb1').LConn); pc(s('gB').RConn, s('Sb2').LConn);
cf = ph('Cf'); csin = ph('CS_in'); csout = ph('CS_out'); cscf = ph('CS_cf');
% node a = Cf top (through CS_cf), node b = Cf bottom
pc(cscf.RConn(2), cf.LConn); a = cscf.LConn(1); b = cf.RConn;
pc(n1, csin.LConn(1));  pc(csin.RConn(2), s('Sa1').RConn(1)); pc(s('Sa1').RConn(2), a);   % n1 -> a
pc(n0, s('Sa2').RConn(1)); pc(s('Sa2').RConn(2), b);                                      % n0 -> b
pc(n2, s('Sb1').RConn(1)); pc(s('Sb1').RConn(2), a);                                      % n2 -> a
pc(n1, csout.LConn(1)); pc(csout.RConn(2), s('Sb2').RConn(2)); pc(s('Sb2').RConn(1), b);  % n1 -> b: cell-2 charging current returns to Cf
vs = ph('VS_cf'); pc(cf.LConn, vs.LConn(1)); pc(b, vs.RConn(2));
% signals: charge drawn from cell 1 at n1 in phase A, charge returned to n1 in phase B
conv = {'i_in', csin.RConn(1), 'A'; 'i_out', csout.RConn(1), 'A'; 'i_cf', cscf.RConn(1), 'A'; 'v_cf', vs.RConn(1), 'V'};
for k = 1:4
    add_block('nesl_utility/PS-Simulink Converter', [mdl '/ps ' conv{k,1}], 'Unit', conv{k,3}, ...
        'Position', [1000 100+60*k 1020 120+60*k]);
    pc(conv{k,2}, ph(['ps ' conv{k,1}]).LConn);
end
% q_in: charge leaving cell 1 through Sa1 ; q_out: charge entering the cell-2/cell-1 node through Sb2
% e_in = int(V1 * i_in), e_out = int(V2 * i_out)  (cell voltages ~ constant)
add_block('simulink/Continuous/Integrator', [mdl '/q_in'], 'Position', [1100 160 1130 190]);
add_block('simulink/Continuous/Integrator', [mdl '/q_out'], 'Position', [1100 220 1130 250]);
add_block('simulink/Math Operations/Gain', [mdl '/xV1'], 'Gain', 'Pd.V1', 'Position', [1160 160 1200 190]);
add_block('simulink/Math Operations/Gain', [mdl '/xV2'], 'Gain', 'Pd.V2', 'Position', [1160 220 1200 250]);
add_line(mdl, 'ps i_in/1', 'q_in/1'); add_line(mdl, 'ps i_out/1', 'q_out/1');
add_line(mdl, 'q_in/1', 'xV1/1'); add_line(mdl, 'q_out/1', 'xV2/1');
names = {'q_in', 'q_in/1'; 'q_out', 'q_out/1'; 'e_in', 'xV1/1'; 'e_out', 'xV2/1'; 'i_cf', 'ps i_cf/1'; 'v_cf', 'ps v_cf/1'};
for k = 1:size(names, 1)
    add_block('simulink/Sinks/To Workspace', [mdl '/log ' names{k,1}], 'VariableName', names{k,1}, ...
        'SaveFormat', 'Timeseries', 'Position', [1300 100+50*k 1360 120+50*k]);
    add_line(mdl, names{k,2}, ['log ' names{k,1} '/1'], 'autorouting', 'on');
end
set_param(mdl, 'StopTime', 'Pd.Tend', 'Solver', 'daessc', 'MaxStep', '1/(50*Pd.f)', 'RelTol', '1e-5', ...
    'ReturnWorkspaceOutputs', 'on');
save_system(mdl, f);
end
