%% run_experiments.m — simulated version of the PS-3 experiment plan
%
% Normally started from ../run_all.m. Rebuilds the models, runs every
% scenario, computes the metrics asked for in the problem statement and
% writes everything to ../results:
%
%   A  no_balancing     baseline, same initial conditions        (PS req. 5)
%   B  passive          passive balancing                        (PS req. 3, 5)
%   C  repeat_1..3      passive, new noise seed + +-0.5 % SOC     (repeatability)
%   D  manual_stop      stop button pressed at 30 min            (PS req. 2)
%   E  over_temp        undersized bleed (P.R_overtemp) -> over-temp fault (PS req. 2)
%   F  low_voltage      one cell nearly empty -> alert, inhibit  (PS req. 2)
%   G  emulator         supercapacitor test emulator             (safety req.)
%   H  sweep_R*         bleed resistors from P.R_sweep           (design trade-off)
%   I  adc10_tight/adc16 ADC resolution and threshold choice      (uncertainty)
%   J  active           switched-capacitor balancing             (PS req. 4, 5)
%   K  active_repeat_*  repeatability of active
%   L  active_low_volt  active with a nearly empty cell (current limit)
%   M  active_emulator  active on the supercapacitor emulator
%   + sc_characterize   switch-level characterisation of one SC stage
%
% Outputs:
%   results/tables/      metrics_summary.csv (one row per run), metrics_per_cell_passive.csv,
%                        repeatability.csv, sc_characterisation_*.csv
%   results/timeseries/  raw time series of the key runs (CSV)
%   results/figures/     fig_*.png (300 dpi)
%   results/metrics.mat  metrics structs of every run (re-run to regenerate full logs)

clear; clc;
root   = fileparts(fileparts(mfilename('fullpath')));      % simulation/bms_4cell
addpath(fullfile(root, 'src'), fullfile(root, 'build'), fullfile(root, 'experiments'));
resDir = fullfile(root, 'results');
figDir = fullfile(resDir, 'figures'); tabDir = fullfile(resDir, 'tables'); tsDir = fullfile(resDir, 'timeseries');
for dd = {resDir, figDir, tabDir, tsDir}, if ~isfolder(dd{1}), mkdir(dd{1}); end, end
% raw time series are written only for these runs (the rest are in metrics_summary.csv)
keyRuns = {'no_balancing','passive','active','emulator','active_emulator', ...
           'manual_stop','over_temp','low_voltage','active_low_volt'};

%% Check the parameter sets and size the runs from them (no hand-tuned lengths)
[P0, C0] = params_4cell('cell');     [e0, w0] = check_params(P0, C0);
[Pe, Ce] = params_4cell('emulator'); [estE, we] = check_params(Pe, Ce);
fid = fopen(fullfile(tabDir, 'param_checks.txt'), 'w');
fprintf(fid, 'cell:\n'); fprintf(fid, '  %s\n', w0{:}); fprintf(fid, 'emulator:\n'); fprintf(fid, '  %s\n', we{:}); fclose(fid);
if any(startsWith([w0 we], 'ERROR')), error('Parameter check failed - fix params_4cell.m (see messages above)'); end
rnd = @(t) 600 * ceil(t / 600);                          % round up to 10 min
T_pas  = rnd(max(1800, 1.7 * e0.t_passive_s));          % passive run length
T_act  = rnd(max(3600, 5.0 * e0.t_passive_s));          % active decays exponentially: longer
T_pasE = rnd(max(600,  1.7 * estE.t_passive_s));
T_actE = rnd(max(1200, 5.0 * estE.t_passive_s));
t_btn  = rnd(0.25 * T_pas);                              % manual-stop press time
SOC_low = [P0.SOC0(1:3), e0.SOC_lowV];                   % cell 4 between V_uv and V_lv
fprintf('Run lengths: passive %.1f h, active %.1f h, emulator %.0f / %.0f s\n', T_pas/3600, T_act/3600, T_pasE, T_actE);

build_4cell_model('cell');
build_4cell_model('emulator');

%% Scenario list:  name, plant, modifier function @(P,C) -> [P,C]
% (P.StopTime is preset to T_pas / T_pasE before the modifier runs)
S = {
 'no_balancing', 'cell',     @(P,C) deal(setf(P,'mode_req',0), C)
 'passive',      'cell',     @(P,C) deal(P, C)
 'repeat_1',     'cell',     @(P,C) deal(rep(P,1), C)
 'repeat_2',     'cell',     @(P,C) deal(rep(P,2), C)
 'repeat_3',     'cell',     @(P,C) deal(rep(P,3), C)
 'manual_stop',  'cell',     @(P,C) deal(setf(setf(P,'t_stop',t_btn),'StopTime',2*t_btn), C)
 'over_temp',    'cell',     @(P,C) deal(setf(setf(P,'R_bleed',P.R_overtemp),'StopTime',1800), C)
 'low_voltage',  'cell',     @(P,C) deal(setf(setf(P,'SOC0',SOC_low),'StopTime',1800), C)
 'emulator',     'emulator', @(P,C) deal(P, C)
 'adc10_tight',  'cell',     @(P,C) deal(P, setf(setf(C,'dV_on',0.015),'dV_off',0.005))
 'adc16',        'cell',     @(P,C) deal(P, setf(setf(setf(C,'lsb',6.144/32768),'dV_on',0.010),'dV_off',0.003))
 'active',       'cell',     @(P,C) deal(act(P,T_act), C)
 'active_repeat_1','cell',   @(P,C) deal(act(rep(P,1),T_act), C)
 'active_repeat_2','cell',   @(P,C) deal(act(rep(P,2),T_act), C)
 'active_repeat_3','cell',   @(P,C) deal(act(rep(P,3),T_act), C)
 'active_low_volt','cell',   @(P,C) deal(act(setf(P,'SOC0',SOC_low),T_act), C)
 'active_emulator','emulator',@(P,C) deal(act(P,T_actE), C)
};
% resistor sweep: one run per value in P.R_sweep, each sized to finish
for Rk = P0.R_sweep
    Pk = P0; Pk.R_bleed = Rk; ek = check_params(Pk, C0, false);
    S(end+1, :) = {rname(Rk), 'cell', @(P,C) deal(setf(setf(P,'R_bleed',Rk),'StopTime',rnd(max(1800, 1.7*ek.t_passive_s))), C)}; %#ok<SAGROW>
end

R = struct();  rows = {};
for k = 1:size(S, 1)
    name = S{k,1}; plant = S{k,2};
    [P, C] = params_4cell(plant);
    P.StopTime = ternary(strcmp(plant, 'cell'), T_pas, T_pasE);
    [P, C] = S{k,3}(P, C);
    assignin('base', 'P', P); assignin('base', 'C', C);
    mdl = ternary(strcmp(plant, 'cell'), 'BMS4Cell', 'BMS4Cell_Emulator');
    fprintf('[%2d/%d] %-13s ... ', k, size(S,1), name); tic;
    out = sim(mdl);
    d = collect(out, P, C);
    m = metrics(d, P, C);
    fprintf('%5.1f s | spread %5.1f -> %5.1f mV | t_bal %s | E_loss %.3f Wh | Tres_max %.1f C | %s\n', ...
        toc, m.spread0_mV, m.spreadF_mV, fmtH(m.t_bal_h), m.E_loss_Wh, m.Tres_max_C, m.final_mode);
    R.(name) = struct('d', d, 'm', m, 'P', P, 'C', C);
    rows(end+1, :) = {name, P.R_bleed, P.mode_req, m.spread0_mV, m.spreadF_mV, m.socSpread0_pct, ...
        m.socSpreadF_pct, m.t_bal_h, m.E_res_Wh, m.E_sc_Wh, m.E_loss_Wh, m.E_loss_pct_pack, m.I_on_mA, m.I_sc_peak_mA, ...
        m.Tres_max_C, m.Tcell_max_C, m.Q_dis_before_Ah, m.Q_dis_after_Ah, m.Q_cyc_before_Ah, ...
        m.Q_cyc_after_Ah, m.final_mode, m.faults, m.alerts, m.t_event_s}; %#ok<SAGROW>
    if ismember(name, keyRuns), writetable(tsTable(d), fullfile(tsDir, [name '.csv'])); end
end

%% Tables
T = cell2table(rows, 'VariableNames', {'run','R_bleed_ohm','mode_req','V_spread0_mV', ...
    'V_spreadF_mV','SOC_spread0_pct','SOC_spreadF_pct','t_balance_h','E_resistors_Wh', ...
    'E_sc_loss_Wh','E_loss_total_Wh','E_loss_pct_of_pack','I_bleed_mean_mA','I_sc_peak_mA','T_res_max_C','T_cell_max_C', ...
    'Q_dischargeable_before_Ah','Q_dischargeable_after_Ah','Q_cycle_usable_before_Ah', ...
    'Q_cycle_usable_after_Ah','final_mode','faults','alerts','t_fault_or_stop_s'});
writetable(T, fullfile(tabDir, 'metrics_summary.csv'));
writetable(R.passive.m.perCell, fullfile(tabDir, 'metrics_per_cell_passive.csv'));

grp = {'Passive', {'passive','repeat_1','repeat_2','repeat_3'}; 'Active', {'active','active_repeat_1','active_repeat_2','active_repeat_3'}};
fprintf('\n');
rows2 = {};
for g = 1:2
    rp = cellfun(@(n) R.(n).m, grp{g,2});
    fprintf('Repeatability %-7s (4 runs): t_bal = %.2f +- %.2f h, E_loss = %.3f +- %.3f Wh, final spread = %.1f +- %.1f mV\n', ...
        grp{g,1}, mean([rp.t_bal_h]), std([rp.t_bal_h]), mean([rp.E_loss_Wh]), std([rp.E_loss_Wh]), ...
        mean([rp.spreadF_mV]), std([rp.spreadF_mV]));
    rows2(end+1, :) = {grp{g,1}, mean([rp.t_bal_h]), std([rp.t_bal_h]), mean([rp.E_loss_Wh]), std([rp.E_loss_Wh]), ...
        mean([rp.spreadF_mV]), std([rp.spreadF_mV])}; %#ok<AGROW>
end
writetable(cell2table(rows2, 'VariableNames', {'method','t_bal_mean_h','t_bal_std_h','E_loss_mean_Wh', ...
    'E_loss_std_Wh','V_spreadF_mean_mV','V_spreadF_std_mV'}), fullfile(tabDir, 'repeatability.csv'));
M = structfun(@(r) r.m, R, 'UniformOutput', false);
save(fullfile(resDir, 'metrics.mat'), 'M', 'T');
disp(T(:, {'run','t_balance_h','E_loss_total_Wh','I_sc_peak_mA','T_res_max_C','V_spreadF_mV','Q_dischargeable_after_Ah','final_mode'}));

%% Figures + switch-level characterisation of the SC stage
makeFigures(R, figDir);
sc_characterize();
fprintf('Results written to %s\n', resDir);

%% ======================================================================
function d = collect(out, P, C)
names = {'V_cell','I_bleed','SOC','T_cell','P_res','T_res','E_res_Wh','E_drawn_Wh', ...
         'V_meas','bal_cmd','mode','alerts','faults','balanced','V_rest','I_act','E_act_loss_Wh','act_cmd'};
for n = names
    ts = out.get(n{1});
    x = double(squeeze(ts.Data));
    if size(x, 1) ~= numel(ts.Time), x = x.'; end
    d.(n{1}) = x; d.(['t_' n{1}]) = ts.Time(:);
end
d.t  = d.t_V_cell;  d.tc = d.t_mode;  % continuous / controller time bases
d.P = P; d.C = C;
end

function m = metrics(d, P, C)
V0 = d.V_cell(1, :);   SOC0 = d.SOC(1, :);   SOCF = d.SOC(end, :);
m.spread0_mV = 1e3 * (max(V0) - min(V0));
% final spread: true no-load value = add back the I*R0 drop of bleed + SC currents
Ia = [d.I_act(end, :) 0] - [0 d.I_act(end, :)];                 % net SC discharge per cell
Vend = d.V_cell(end, :) + (d.I_bleed(end, :) + Ia) .* P.R0_cell;
m.spreadF_mV = 1e3 * (max(Vend) - min(Vend));
m.socSpread0_pct = 100 * (max(SOC0) - min(SOC0));
m.socSpreadF_pct = 100 * (max(SOCF) - min(SOCF));
i = find(d.balanced > 0.5, 1);   m.t_bal_h = ifelse(isempty(i), NaN, d.tc(min(i, end)) / 3600);
m.E_res_Wh   = sum(d.E_res_Wh(end, :));
m.E_sc_Wh    = d.E_act_loss_Wh(end);
m.E_loss_Wh  = m.E_res_Wh + m.E_sc_Wh;
if strcmp(P.plant, 'cell'), packWh = P.N * P.AH * P.V_nom; else, packWh = sum(0.5 * P.C_emu * P.Vc0_emu.^2) / 3600; end
m.E_loss_pct_pack = 100 * m.E_loss_Wh / packWh;
m.I_sc_peak_mA = 1e3 * max(abs(d.I_act(:)));
on = d.I_bleed > 1e-3;
m.I_on_mA   = 1e3 * mean(d.I_bleed(on));  if isnan(m.I_on_mA), m.I_on_mA = 0; end
m.Tres_max_C  = max(d.T_res(:));
m.Tcell_max_C = max(d.T_cell(:));
m.Q_dis_before_Ah = P.AH * min(SOC0);       m.Q_dis_after_Ah = P.AH * min(SOCF);
m.Q_cyc_before_Ah = P.AH * (1 - (max(SOC0) - min(SOC0)));
m.Q_cyc_after_Ah  = P.AH * (1 - (max(SOCF) - min(SOCF)));
modes = {'MONITOR','PASSIVE','ACTIVE','FAULT','STOP'};
m.final_mode = modes{d.mode(end) + 1};
m.faults = d.faults(end);  m.alerts = max(d.alerts);
j = find(d.mode >= 3, 1);  m.t_event_s = ifelse(isempty(j), NaN, d.tc(min(j, end)));
dt = median(diff(d.t));
m.perCell = table((1:4).', 100*SOC0.', 100*SOCF.', V0.', Vend.', d.E_res_Wh(end, :).', ...
    sum(on, 1).' * dt / 3600, max(d.T_res, [], 1).', 1e3 * P.AH * (SOC0 - SOCF).', ...
    'VariableNames', {'cell','SOC_start_pct','SOC_end_pct','V_start','V_end_noload', ...
    'E_resistor_Wh','bleed_hours','T_res_max_C','charge_removed_mAh'});
end

function makeFigures(R, resDir)
cols = [0 0.447 0.741; 0.85 0.325 0.098; 0.929 0.694 0.125; 0.494 0.184 0.556];
lbl  = {'Cell 1','Cell 2','Cell 3','Cell 4'};
nb = R.no_balancing.d; pb = R.passive.d;
h = @(t) t / 3600;

% 1. Cell voltages: no balancing vs passive
f = fig('Cell voltages'); tiledlayout(1, 2, 'TileSpacing', 'compact');
nexttile; plotc(h(nb.t), nb.V_cell, cols); title('No balancing'); ylabel('Cell voltage (V)'); xlabel('Time (h)');
nexttile; plotc(h(pb.t), pb.V_cell, cols); title('Passive balancing'); xlabel('Time (h)'); legend(lbl, 'Location', 'best');
save300(f, resDir, 'fig_voltage_compare');

% 2. Voltage spread (rested measurement) and SOC
f = fig('Spread'); tiledlayout(2, 1, 'TileSpacing', 'compact');
nexttile; hold on; grid on;
plot(h(nb.tc), 1e3 * (max(nb.V_meas, [], 2) - min(nb.V_meas, [], 2)), 'Color', [.5 .5 .5], 'LineWidth', 1.5);
vr = pb.V_rest; ok = all(vr > 0, 2);
stairs(h(pb.tc(ok)), 1e3 * (max(vr(ok,:), [], 2) - min(vr(ok,:), [], 2)), 'Color', cols(1,:), 'LineWidth', 1.5);
yline(1e3 * pb.C.dV_on, '--r', 'dV_{on}'); yline(1e3 * pb.C.dV_off, ':r', 'dV_{off}');
ylabel('Voltage spread (mV)'); legend('No balancing', 'Passive (rested reading)', 'Location', 'northeast');
title('Cell-voltage spread');
nexttile; plotc(h(pb.t), 100 * pb.SOC, cols); ylabel('SOC (%)'); xlabel('Time (h)');
title('SOC during passive balancing'); legend(lbl, 'Location', 'best');
save300(f, resDir, 'fig_spread_soc');

% 3. Current, energy
f = fig('Energy'); tiledlayout(2, 1, 'TileSpacing', 'compact');
nexttile; plotc(h(pb.t), 1e3 * pb.I_bleed, cols); ylabel('Bleed current (mA)'); xlim([0 0.5]);
title('Bleed current, first 30 min (60 s on / 5 s rest cycles)'); legend(lbl, 'Location', 'best');
nexttile; plotc(h(pb.t), pb.E_res_Wh, cols); hold on;
plot(h(pb.t), sum(pb.E_res_Wh, 2), 'k', 'LineWidth', 1.8);
ylabel('Energy dissipated (Wh)'); xlabel('Time (h)'); legend([lbl, {'Total'}], 'Location', 'best');
title('Cumulative energy dissipated in bleed resistors');
save300(f, resDir, 'fig_current_energy');

% 4. Temperature
f = fig('Temperature'); tiledlayout(1, 2, 'TileSpacing', 'compact');
nexttile; plotc(h(pb.t), pb.T_res, cols); yline(pb.C.T_res_warn, '--', 'warn'); yline(pb.C.T_res_max, '--r', 'fault');
ylabel('Temperature (\circC)'); xlabel('Time (h)'); title('Bleed resistor hot-spot');
nexttile; plotc(h(pb.t), pb.T_cell, cols); ylabel('Temperature (\circC)'); xlabel('Time (h)');
title('Cell surface'); legend(lbl, 'Location', 'best');
save300(f, resDir, 'fig_temperature');

% 5. Fault handling: manual stop, over-temp, low voltage
f = fig('Faults'); tiledlayout(3, 1, 'TileSpacing', 'compact');
sc = {'manual_stop', sprintf('Manual stop pressed at %g min', R.manual_stop.P.t_stop/60); ...
      'over_temp', sprintf('Over-temperature: %g \\Omega bleed resistor', R.over_temp.P.R_bleed); ...
      'low_voltage', sprintf('Low-voltage alert: cell 4 at %.0f %% SOC', 100*R.low_voltage.P.SOC0(4))};
for k = 1:3
    d = R.(sc{k,1}).d; nexttile; yyaxis left;
    if k == 2, plotc(d.t / 60, d.T_res, cols); ylabel('T_{res} (\circC)'); yline(d.C.T_res_max, '--r');
    else, plotc(d.t / 60, 1e3 * d.I_bleed, cols); ylabel('I_{bleed} (mA)'); end
    yyaxis right; stairs(d.tc / 60, d.mode, 'k', 'LineWidth', 1.2); ylim([-0.5 4.5]);
    yticks(0:4); yticklabels({'MON','PAS','ACT','FLT','STOP'}); title(sc{k,2});
end
xlabel('Time (min)');
save300(f, resDir, 'fig_fault_handling');

% 6. Emulator
d = R.emulator.d;
f = fig('Emulator'); tiledlayout(2, 1, 'TileSpacing', 'compact');
nexttile; plotc(d.t, d.V_cell, cols); ylabel('Capacitor voltage (V)'); legend(lbl, 'Location', 'best');
title(sprintf('Supercapacitor emulator (%g F, %g \\Omega)', d.P.C_emu, d.P.R_bleed));
nexttile; stairs(d.tc, d.bal_cmd + (0:3) * 1.5, 'LineWidth', 1.2); yticks((0:3) * 1.5 + 0.5); yticklabels(lbl);
xlabel('Time (s)'); title('Bleed switch commands'); grid on;
save300(f, resDir, 'fig_emulator');

% 7. Resistor sweep trade-off
Rv = R.passive.P.R_sweep; tb = zeros(size(Rv)); Tm = tb; Eb = tb;
for k = 1:4
    m = R.(rname(Rv(k))).m; tb(k) = m.t_bal_h; Tm(k) = m.Tres_max_C; Eb(k) = m.E_res_Wh;
end
f = fig('Sweep'); yyaxis left; plot(Rv, tb, '-o', 'LineWidth', 1.5); ylabel('Balancing time (h)');
yyaxis right; plot(Rv, Tm, '-s', 'LineWidth', 1.5); ylabel('Peak resistor temperature (\circC)');
xlabel('Bleed resistor (\Omega)'); grid on; set(gca, 'XScale', 'log'); xticks(Rv);
for k = find(isnan(tb)), text(Rv(k), Tm(k), '  over-temp fault', 'Color', 'r'); end
title(sprintf('Bleed resistor trade-off (energy dissipated ~%.2f Wh whenever balancing completes)', ...
    mean(Eb(~isnan(tb)))));
save300(f, resDir, 'fig_resistor_sweep');

% 8. Measurement resolution: ADC / threshold choice vs true SOC spread
runs = {'passive', '10-bit ADC, 20/10 mV (default)'; 'adc10_tight', '10-bit ADC, 15/5 mV'; ...
        'adc16', '16-bit ADS1115, 10/3 mV'};
f = fig('ADC'); hold on; grid on;
for k = 1:3
    d = R.(runs{k,1}).d;
    plot(h(d.t), 100 * (max(d.SOC, [], 2) - min(d.SOC, [], 2)), 'LineWidth', 1.6, 'Color', cols(k, :));
end
xlabel('Time (h)'); ylabel('True SOC spread (%)'); legend(runs(:, 2), 'Location', 'northeast');
title('Effect of ADC resolution and thresholds on balancing');
save300(f, resDir, 'fig_adc_resolution');

% 9. Method comparison: no balancing vs passive vs active (same initial state)
ac = R.active.d;
M  = {'no_balancing', 'No balancing', [.5 .5 .5]; 'passive', sprintf('Passive (%g \\Omega bleed)', pb.P.R_bleed), cols(1,:); ...
      'active', sprintf('Active (SC, %g mF, %g kHz)', 1e3*ac.P.C_fly, ac.P.f_sw/1e3), cols(2,:)};
f = fig('Comparison'); f.Position = [100 100 1300 850]; tiledlayout(2, 2, 'TileSpacing', 'compact');
nexttile; hold on; grid on;
for k = 1:3
    d = R.(M{k,1}).d;  Ia = [d.I_act zeros(size(d.t))] - [zeros(size(d.t)) d.I_act];
    Vnl = d.V_cell + (d.I_bleed + Ia) * d.P.R0_cell;                  % no-load voltage
    plot(h(d.t), 1e3 * (max(Vnl, [], 2) - min(Vnl, [], 2)), 'LineWidth', 1.6, 'Color', M{k,3});
end
yline(1e3 * pb.C.dV_on, '--r', 'dV_{on}'); xlabel('Time (h)'); ylabel('Voltage spread (mV)');
legend(M(:,2), 'Location', 'northeast'); title('Balancing progress'); xlim([0 ac.P.StopTime/3600]);
nexttile; hold on; grid on;
for k = 2:3
    d = R.(M{k,1}).d;
    plot(h(d.t), sum(d.E_res_Wh, 2) + d.E_act_loss_Wh, 'LineWidth', 1.6, 'Color', M{k,3});
end
xlabel('Time (h)'); ylabel('Energy lost as heat (Wh)'); legend(M(2:3,2), 'Location', 'east');
title('Energy dissipated'); xlim([0 ac.P.StopTime/3600]);
nexttile; b = bar(categorical(lbl), 100 * [R.no_balancing.d.SOC(end,:); pb.SOC(end,:); ac.SOC(end,:)].');
for k = 1:3, b(k).FaceColor = M{k,3}; end
ylabel('Final SOC (%)'); grid on; legend(M(:,2), 'Location', 'northeast');
title('Where the charge ends up');
nexttile; mm = [R.no_balancing.m, R.passive.m, R.active.m];
Y = [[mm.Q_dis_after_Ah]; [mm.Q_cyc_after_Ah]].';
b = bar(categorical({'None','Passive','Active'}, {'None','Passive','Active'}), Y); grid on;
b(1).FaceColor = [.3 .6 .3]; b(2).FaceColor = [.6 .8 .6];
ylabel('Ah'); legend('Dischargeable now (min SOC)', 'Usable per cycle (1 - spread)', 'Location', 'southeast');
title('Pack capacity after balancing'); ylim([0 2.6]);
save300(f, resDir, 'fig_method_comparison');

% 10. Active balancing detail: pair currents, gating, low-voltage case with current limit
f = fig('Active'); tiledlayout(2, 2, 'TileSpacing', 'compact');
pl = {'Pair 1-2', 'Pair 2-3', 'Pair 3-4'};
cyc = @(d, x) movmean(x, round((d.C.n_on + d.C.n_rest + 1) / median(diff(d.t))));   % cycle average
nexttile; plotc(h(ac.t), 1e3 * cyc(ac, ac.I_act), cols); ylabel('Cycle-average current (mA)'); xlabel('Time (h)');
legend(pl, 'Location', 'best'); title('Active: average SC pair currents (+ = up the stack)'); xlim([0 ac.P.StopTime/3600]);
nexttile; plotc(h(ac.t), ac.V_cell, cols); ylabel('Cell voltage (V)'); xlabel('Time (h)');
legend(lbl, 'Location', 'best'); title('Active: cell voltages'); xlim([0 ac.P.StopTime/3600]);
lv = R.active_low_volt.d;
nexttile; plotc(h(lv.t), 1e3 * lv.I_act, cols); yline(1e3 * lv.C.I_sc_max, '--r', 'limit');
ylabel('Transfer current (mA)'); xlabel('Time (h)'); legend(pl, 'Location', 'best');
title('Nearly empty cell 4: current limited by PWM gating');
nexttile; plotc(h(lv.t), 100 * lv.SOC, cols); ylabel('SOC (%)'); xlabel('Time (h)');
legend(lbl, 'Location', 'best'); title('Nearly empty cell 4 is recharged from the others');
save300(f, resDir, 'fig_active');
end

%% ---------------------------------------------------------------- helpers
function P = setf(P, f, v), P.(f) = v; end
function n = rname(R), n = strrep(sprintf('sweep_R%g', R), '.', 'p'); end
function P = act(P, tEnd), P.mode_req = 2; P.StopTime = tEnd; end
function P = rep(P, k)
rng(100 + k); P.seed = P.seed + 10 * k;
P.SOC0 = P.SOC0 + 0.005 * (2 * rand(1, 4) - 1);
end
function y = ternary(c, a, b), if c, y = a; else, y = b; end, end
function y = ifelse(c, a, b), if c, y = a; else, y = b; end, end
function s = fmtH(x), if isnan(x), s = '   --  '; else, s = sprintf('%5.2f h', x); end, end
function f = fig(n)
f = figure('Name', n, 'Color', 'w', 'Position', [100 100 1100 700], 'Visible', 'off');
try, theme(f, 'light'); catch, end
end
function plotc(t, Y, cols)
hold on; grid on;
for k = 1:size(Y, 2), plot(t, Y(:, k), 'Color', cols(k, :), 'LineWidth', 1.4); end
end
function save300(f, d, n), exportgraphics(f, fullfile(d, [n '.png']), 'Resolution', 300); close(f); end
function T = tsTable(d)
% raw data at the controller rate interpolated onto the continuous log grid
T = array2table([d.t, d.V_cell, 1e3 * d.I_bleed, d.SOC, d.T_cell, d.T_res, d.E_res_Wh, ...
    interp1(d.tc, d.bal_cmd, d.t, 'previous', 'extrap'), interp1(d.tc, d.mode, d.t, 'previous', 'extrap')], ...
    'VariableNames', [{'t_s'}, pre('V', 'V'), pre('I', 'mA'), pre('SOC', ''), pre('Tcell', 'C'), ...
    pre('Tres', 'C'), pre('E', 'Wh'), pre('bal', ''), {'mode'}]);
end
function c = pre(a, u), c = arrayfun(@(k) sprintf('%s%d%s', a, k, ifelse(isempty(u), '', ['_' u])), 1:4, 'uni', 0); end
