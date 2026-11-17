function Rs = sc_characterize()
%SC_CHARACTERIZE  Switch-level model of ONE switched-capacitor stage between
% two adjacent cells (PS requirement 4: charge transfer + characterisation).
%
% Circuit (emulator cells = supercapacitors, the safe first bench test):
%
%     n2 ──┬── Sb1 ──┐            phase A: Sa1 + Sa2 on  -> Cf across cell 1
%     cell2│         a            phase B: Sb1 + Sb2 on  -> Cf across cell 2
%     n1 ──┼── Sa1 ──┘  Cf        (48 % duty each, 2 % dead time)
%          ├── Sb2 ──┐
%     cell1│         b
%     n0 ──┴── Sa2 ──┘
%
% Measurements (what you would do on the bench with a scope + shunt):
%   1. average transfer current vs switching frequency at fixed dV
%   2. average transfer current vs dV at the design frequency
%   3. efficiency  P_out / P_in
%   4. waveforms of the flying-capacitor current and voltage
% and compares them with the averaged-model formula in sc_req.m that the
% 4-cell model uses.

root = fileparts(fileparts(mfilename('fullpath')));       % simulation/bms_4cell
figDir = fullfile(root, 'results', 'figures'); tabDir = fullfile(root, 'results', 'tables');
if ~isfolder(figDir), mkdir(figDir); end; if ~isfolder(tabDir), mkdir(tabDir); end
[P, ~] = params_4cell('emulator');
mdl = 'SC_Stage_Detail';
build_sc_stage_model(mdl);

V1 = 2.40;                                   % cell 1 (source) voltage
fs  = round(logspace(1, 5, 13));             % Hz
dVs = [0.02 0.05 0.1 0.2 0.3];               % V
ncyc = 40;

% 1. frequency sweep
I_f = zeros(size(fs)); eta_f = I_f;
for k = 1:numel(fs)
    [I_f(k), eta_f(k)] = runPoint(mdl, P, fs(k), V1, V1 - 0.1, ncyc);
end
% 2. dV sweep
I_v = zeros(size(dVs)); eta_v = I_v;
for k = 1:numel(dVs)
    [I_v(k), eta_v(k)] = runPoint(mdl, P, P.f_sw, V1, V1 - dVs(k), ncyc);
end
% 3. waveforms at design frequency
[~, ~, w] = runPoint(mdl, P, P.f_sw, V1, V1 - 0.1, 10);

% theory
ff = logspace(1, 5, 200);
Req_th = sc_req(ff, P.C_fly, P.R_loop, P.duty_sc);
Req_meas = 0.1 ./ I_f;
err = 100 * (Req_meas - sc_req(fs, P.C_fly, P.R_loop, P.duty_sc)) ./ sc_req(fs, P.C_fly, P.R_loop, P.duty_sc);
p = polyfit(dVs, I_v, 1);
fprintf('\nSwitched-capacitor stage (C_fly %.1f mF, R_loop %.0f mOhm)\n', 1e3*P.C_fly, 1e3*P.R_loop);
fprintf('  f_sw (Hz)   I_avg (mA)   R_eq meas (Ohm)   R_eq theory (Ohm)   error %%   efficiency %%\n');
for k = 1:numel(fs)
    fprintf('  %8d   %9.1f   %14.3f   %16.3f   %7.1f   %8.1f\n', fs(k), 1e3*I_f(k), Req_meas(k), ...
        sc_req(fs(k), P.C_fly, P.R_loop, P.duty_sc), err(k), 100*eta_f(k));
end
fprintf('  dV sweep at %d Hz: I = %.3f A/V * dV %+.4f A  ->  R_eq = %.3f Ohm (theory %.3f)\n', ...
    P.f_sw, p(1), p(2), 1/p(1), P.R_eq);

T = table(fs(:), 1e3*I_f(:), Req_meas(:), sc_req(fs(:), P.C_fly, P.R_loop, P.duty_sc), err(:), 100*eta_f(:), ...
    'VariableNames', {'f_sw_Hz','I_avg_mA','R_eq_meas_ohm','R_eq_theory_ohm','error_pct','efficiency_pct'});
writetable(T, fullfile(tabDir, 'sc_characterisation_freq.csv'));
writetable(table(dVs(:), 1e3*I_v(:), 100*eta_v(:), 'VariableNames', {'dV_V','I_avg_mA','efficiency_pct'}), ...
    fullfile(tabDir, 'sc_characterisation_dV.csv'));

% figure
f = figure('Color', 'w', 'Position', [100 100 1200 800], 'Visible', 'off'); try, theme(f, 'light'); catch, end
tiledlayout(2, 2, 'TileSpacing', 'compact');
nexttile; loglog(ff, Req_th, 'k-', 'LineWidth', 1.3); hold on; grid on;
loglog(ff, 1 ./ (ff * P.C_fly), 'k:', ff, 2 * P.R_loop / P.duty_sc * ones(size(ff)), 'k--');
loglog(fs, Req_meas, 'o', 'MarkerFaceColor', [0 .447 .741], 'MarkerSize', 7);
xline(P.f_sw, ':', 'design');
xlabel('Switching frequency (Hz)'); ylabel('R_{eq} (\Omega)');
legend('theory (sc\_req)', 'SSL 1/(fC)', 'FSL 2R_{loop}/D', 'switch-level sim', 'Location', 'southwest');
title('Equivalent resistance vs frequency');
nexttile; plot(1e3 * dVs, 1e3 * I_v, 'o-', 'LineWidth', 1.4); grid on; hold on;
plot(1e3 * dVs, 1e3 * dVs / P.R_eq, 'k--');
xlabel('\DeltaV between cells (mV)'); ylabel('Average transfer current (mA)');
legend('switch-level sim', '\DeltaV / R_{eq} (averaged model)', 'Location', 'northwest');
title(sprintf('Transfer current at %d Hz', P.f_sw));
nexttile([1 2]); yyaxis left; plot(1e3 * w.t, w.icf, 'LineWidth', 1.2); ylabel('Flying-cap current (A)');
yyaxis right; plot(1e3 * w.t, w.vcf, 'LineWidth', 1.2); ylabel('Flying-cap voltage (V)');
xlabel('Time (ms)'); grid on;
title(sprintf('Waveforms: %g mF flying capacitor, %d Hz, \\DeltaV = 100 mV', 1e3 * P.C_fly, P.f_sw));
exportgraphics(f, fullfile(figDir, 'fig_sc_characterisation.png'), 'Resolution', 300); close(f);
Rs = struct('f', fs, 'I_f', I_f, 'eta_f', eta_f, 'dV', dVs, 'I_v', I_v, 'err', err);
close_system(mdl, 0);
end

%% -------------------------------------------------------------------------
function [Iavg, eta, w] = runPoint(mdl, P, f, V1, V2, ncyc)
Pd = P; Pd.f = f; Pd.V1 = V1; Pd.V2 = V2; Pd.Tend = ncyc / f;
assignin('base', 'Pd', Pd);
out = sim(mdl);
t = out.tout; q1 = out.get('q_in').Data(:); e1 = out.get('e_in').Data(:); e2 = out.get('e_out').Data(:);
q2 = out.get('q_out').Data(:);
t0 = Pd.Tend / 2;                              % ignore the first half (start-up)
k0 = find(t >= t0, 1);
Iavg = (q2(end) - q2(k0)) / (t(end) - t(k0));  % average current delivered into cell 2
eta  = (e2(end) - e2(k0)) / (e1(end) - e1(k0));
w.t = t - t(1); w.icf = out.get('i_cf').Data(:); w.vcf = out.get('v_cf').Data(:);
end
