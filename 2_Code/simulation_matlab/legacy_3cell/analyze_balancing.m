%% analyze_balancing.m  —  cost metrics for the passive cell-balancing model
%
% Run this file from MATLAB (model saved in R2026a). It will:
%   1. load CellBalancing.slx from this folder
%   2. run the simulation
%   3. compute the cost of passive balancing:
%        - energy burned in each bleed resistor (Wh) and in total
%        - that loss as % of full-pack energy and of energy stored at t = 0
%        - balancing time (spread falls to the controller threshold)
%        - initial / final SOC of every cell and final SOC spread
%        - usable pack capacity before vs after (series pack)
%   4. save figures, a metrics table (CSV) and the raw logged data (MAT)
%      into ./results
%
% Signals logged by the model (To Workspace, every 10 s, Timeseries):
%   SOC, SOC_spread_pct, V_cell, P_bleed_W, E_loss_Wh, E_total_Wh,
%   BalCmd, BalActive.   Column order everywhere: [80% cell, 65% cell, 75% cell]

clear; clc;
here    = fileparts(mfilename('fullpath'));
mdl     = 'CellBalancing';
slx     = fullfile(here, [mdl '.slx']);
assert(isfile(slx), 'Model not found: %s', slx);

%% 1-2. Read parameters straight from the model
load_system(slx);
cellNames = {'Cell 1 (80%)', 'Cell 2 (65%)', 'Cell 3 (75%)'};
batt = [mdl '/Battery' newline '80% SOC'];
pcb  = [mdl '/Passive Cell Balancing'];

AH     = str2double(get_param(batt, 'AH'));            % Ah per cell
socVec = str2num(get_param(batt, 'SOC_vec'));          %#ok<ST2NM>
Tvec   = str2num(get_param(batt, 'T_vec'));            %#ok<ST2NM>
V0mat  = str2num(get_param(batt, 'V0_mat'));           %#ok<ST2NM>
Tcell  = str2double(get_param(batt, 'temperature'));   % K
Rbleed = str2double(get_param([mdl '/Resistor'], 'R'));% ohm
thr    = str2double(get_param(pcb, 'Threshold'));      % SOC fraction
nCell  = numel(cellNames);

% open-circuit voltage curve at the cell temperature
ocvAtT = interp1(Tvec, V0mat.', min(max(Tcell, Tvec(1)), Tvec(end))).';
ocv    = @(s) interp1(socVec, ocvAtT, s, 'linear');
EcellWh = @(s1, s2) AH * integral(ocv, s1, s2);       % Wh between two SOCs

%% 3. Simulate
fprintf('Simulating (stop time %s s) ...\n', get_param(mdl, 'StopTime'));
tic; out = sim(mdl); fprintf('Done in %.1f s\n', toc);

[t,  soc]    = getLog(out, 'SOC');
[~,  spread] = getLog(out, 'SOC_spread_pct');
[~,  vcell]  = getLog(out, 'V_cell');
[~,  pW]     = getLog(out, 'P_bleed_W');
[~,  eWh]    = getLog(out, 'E_loss_Wh');
[~,  eTot]   = getLog(out, 'E_total_Wh');
[~,  cmd]    = getLog(out, 'BalCmd');
[~,  active] = getLog(out, 'BalActive');
th = t / 3600;                                         % hours

%% 4. Metrics
soc0 = soc(1, :);   socF = soc(end, :);
sp0  = spread(1);   spF  = spread(end);

iDone = find(spread <= 100*thr, 1, 'first');
if isempty(iDone), tBal = NaN; else, tBal = th(iDone); end
iAct = find(active > 0.5, 1, 'last');
if isempty(iAct), tActive = 0; else, tActive = th(min(iAct + 1, numel(th))); end
onHours = sum(cmd > 0.5, 1) * median(diff(t)) / 3600;   % bleed-on hours per cell

ElossCell = eWh(end, :);
ElossTot  = eTot(end);
EfullPack = nCell * EcellWh(0, 1);
Estored0  = sum(arrayfun(@(s) EcellWh(0, s), soc0));
EfromSOC  = sum(arrayfun(@(a, b) EcellWh(b, a), soc0, socF));   % cross-check

% only samples where cell 1's bleed switch is ON (pW > 0 also catches ~1e-10 W
% numerical noise after turn-off, which previously dragged the mean down)
Iavg = sqrt(mean(pW(cmd(:,1) > 0.5, 1)) / Rbleed);               % A, cell 1
Ppk  = max(pW, [], 1);

% Series pack: usable Ah over a full cycle = AH * (1 - SOC spread)
QuseBefore = AH * (1 - (max(soc0) - min(soc0)));
QuseAfter  = AH * (1 - (max(socF) - min(socF)));

%% 5. Report
fprintf('\n================ PASSIVE BALANCING — COST METRICS ================\n');
fprintf('Cell capacity %.0f Ah | bleed resistor %.0f ohm | threshold %.1f %%\n', AH, Rbleed, 100*thr);
fprintf('%-14s %9s %9s %11s %11s %11s\n', 'Cell', 'SOC0 %', 'SOCend %', 'E lost Wh', 'P peak W', 'bleed h');
for k = 1:nCell
    fprintf('%-14s %9.2f %9.2f %11.2f %11.3f %11.1f\n', cellNames{k}, 100*soc0(k), ...
        100*socF(k), ElossCell(k), Ppk(k), onHours(k));
end
fprintf('------------------------------------------------------------------\n');
fprintf('Total energy burned as heat     : %.2f Wh\n', ElossTot);
fprintf('  as %% of full-pack energy      : %.1f %%  (pack = %.1f Wh)\n', 100*ElossTot/EfullPack, EfullPack);
fprintf('  as %% of energy stored at t=0  : %.1f %%  (stored = %.1f Wh)\n', 100*ElossTot/Estored0, Estored0);
fprintf('  cross-check from SOC drop     : %.2f Wh\n', EfromSOC);
fprintf('Average bleed current (cell 1)  : %.1f mA\n', 1000*Iavg);
fprintf('SOC spread                      : %.2f %% -> %.2f %%\n', sp0, spF);
fprintf('Balancing time (spread <= %.1f%%) : %s\n', 100*thr, fmtH(tBal));
fprintf('Controller last active at       : %s\n', fmtH(tActive));
fprintf('Usable pack capacity (series)   : %.2f Ah -> %.2f Ah  (+%.2f Ah, +%.1f %%)\n', ...
    QuseBefore, QuseAfter, QuseAfter - QuseBefore, 100*(QuseAfter/QuseBefore - 1));
fprintf('Charge available to discharge now: %.2f Ah -> %.2f Ah (limited by weakest cell)\n', ...
    AH*min(soc0), AH*min(socF));
fprintf('==================================================================\n\n');

%% 6. Save results
resDir = fullfile(here, 'results');
if ~isfolder(resDir), mkdir(resDir); end

Metric = {'Total energy lost (Wh)'; 'Loss vs full-pack energy (%)'; ...
    'Loss vs stored energy at t0 (%)'; 'Balancing time (h)'; ...
    'Initial SOC spread (%)'; 'Final SOC spread (%)'; ...
    'Usable capacity before (Ah)'; 'Usable capacity after (Ah)'; ...
    'Usable capacity gain (%)'; 'Average bleed current (mA)'; ...
    'Dischargeable charge before (Ah)'; 'Dischargeable charge after (Ah)'};
Value = [ElossTot; 100*ElossTot/EfullPack; 100*ElossTot/Estored0; tBal; ...
    sp0; spF; QuseBefore; QuseAfter; 100*(QuseAfter/QuseBefore - 1); 1000*Iavg; ...
    AH*min(soc0); AH*min(socF)];
writetable(table(Metric, Value), fullfile(resDir, 'metrics_summary.csv'));
perCell = table(cellNames.', 100*soc0.', 100*socF.', ElossCell.', Ppk.', onHours.', ...
    'VariableNames', {'Cell', 'SOC_start_pct', 'SOC_end_pct', 'Energy_lost_Wh', ...
    'Peak_power_W', 'Bleed_hours'});
writetable(perCell, fullfile(resDir, 'metrics_per_cell.csv'));
save(fullfile(resDir, 'balancing_logs.mat'), 't', 'soc', 'spread', 'vcell', 'pW', ...
    'eWh', 'eTot', 'cmd', 'active', 'AH', 'Rbleed', 'thr', 'cellNames');

%% 7. Figures
f1 = figure('Name', 'SOC', 'Color', 'w');
plot(th, 100*soc, 'LineWidth', 1.5); grid on; hold on;
if ~isnan(tBal), xline(tBal, '--k', sprintf('balanced @ %.1f h', tBal)); end
xlabel('Time (h)'); ylabel('State of charge (%)'); legend(cellNames, 'Location', 'best');
title('Cell SOC during passive balancing');

f2 = figure('Name', 'SOC spread', 'Color', 'w');
plot(th, spread, 'LineWidth', 1.5); grid on; hold on;
yline(100*thr, '--r', 'threshold');
xlabel('Time (h)'); ylabel('max SOC - min SOC (%)'); title('SOC spread');

f3 = figure('Name', 'Energy loss', 'Color', 'w');
subplot(2, 1, 1); plot(th, pW, 'LineWidth', 1.2); grid on;
ylabel('Bleed power (W)'); legend(cellNames, 'Location', 'best');
title('Power dissipated in bleed resistors');
subplot(2, 1, 2); plot(th, eWh, th, eTot, 'k', 'LineWidth', 1.5); grid on;
xlabel('Time (h)'); ylabel('Energy lost (Wh)');
legend([cellNames, {'Total'}], 'Location', 'best'); title('Cumulative energy lost as heat');

f4 = figure('Name', 'Cell voltage', 'Color', 'w');
plot(th, vcell, 'LineWidth', 1.5); grid on;
xlabel('Time (h)'); ylabel('Terminal voltage (V)'); legend(cellNames, 'Location', 'best');
title('Cell voltage during passive balancing');

% R2025a+ applies the desktop dark theme to figures; force light for the report
for f = [f1 f2 f3 f4]
    try, theme(f, 'light'); catch, end
end
exportgraphics(f1, fullfile(resDir, 'fig_soc.png'), 'Resolution', 300);
exportgraphics(f2, fullfile(resDir, 'fig_soc_spread.png'), 'Resolution', 300);
exportgraphics(f3, fullfile(resDir, 'fig_energy_loss.png'), 'Resolution', 300);
exportgraphics(f4, fullfile(resDir, 'fig_voltage.png'), 'Resolution', 300);
fprintf('Saved figures, CSV tables and MAT data to %s\n', resDir);

%% helpers
function [t, d] = getLog(out, name)
    ts = out.get(name);
    t  = ts.Time(:);
    d  = double(ts.Data);
    if ndims(d) == 3, d = permute(d, [3 1 2]); d = reshape(d, size(d, 1), []); end
    if size(d, 1) ~= numel(t), d = d.'; end
end

function s = fmtH(h)
    if isnan(h), s = 'not reached within stop time';
    else, s = sprintf('%.2f h (%.0f s)', h, 3600*h); end
end
