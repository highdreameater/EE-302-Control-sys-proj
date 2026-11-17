function [est, msgs] = check_params(P, C, verbose)
%CHECK_PARAMS  Sanity-check a parameter set and estimate run lengths.
%
%   [est, msgs] = check_params(P, C)        prints the checks
%   [est, msgs] = check_params(P, C, false) silent
%
% Changing values in params_4cell.m needs no code changes, but some values
% are coupled. This function checks those couplings and prints a WARNING or
% an ERROR when a combination does not make sense (e.g. thresholds below the
% ADC resolution, a bleed resistor that will overheat, a run too short to
% finish balancing). Errors mean results would be meaningless.
%
%   est.I_bleed_A     bleed current at nominal voltage
%   est.t_passive_s   time to bleed the highest cell down to the lowest
%   est.T_res_ss_C    steady-state bleed-resistor temperature
%   est.SOC_lowV      SOC whose OCV sits between V_uv and V_lv (low-voltage test)

if nargin < 3, verbose = true; end
msgs = {};
isCell = strcmp(P.plant, 'cell');

%% Voltages
if isCell
    ocv  = P.V0_mat(:, 2);                       % 20 C column
    V0   = interp1(P.SOC_vec, ocv, P.SOC0);
    Vmax = max(ocv);  Vnom = P.V_nom;
else
    V0 = P.Vc0_emu;  Vmax = P.V_rated_emu;  Vnom = mean(P.Vc0_emu);
end
if any(diff(P.SOC_vec) <= 0) || (isCell && any(diff(ocv) < 0))
    msgs{end+1} = fmtmsg('ERROR', 'SOC_vec must increase and the OCV table must not decrease with SOC');
end
if ~(C.V_uv < C.V_lv && C.V_lv <= C.V_bal_min && C.V_bal_min < C.V_ov)
    msgs{end+1} = fmtmsg('ERROR', 'limits must satisfy V_uv < V_lv <= V_bal_min < V_ov (now %.2f / %.2f / %.2f / %.2f V)', ...
        C.V_uv, C.V_lv, C.V_bal_min, C.V_ov);
end
if any(V0 <= C.V_uv) || any(V0 >= C.V_ov)
    msgs{end+1} = fmtmsg('ERROR', 'initial cell voltages %s V are outside the fault limits', mat2str(V0, 3));
end
if isCell && max(ocv) >= C.V_ov
    msgs{end+1} = fmtmsg('WARNING', 'OCV at 100%% SOC (%.2f V) reaches the over-voltage limit (%.2f V)', max(ocv), C.V_ov);
end

%% Measurement vs thresholds
if C.dV_on <= C.dV_off
    msgs{end+1} = fmtmsg('ERROR', 'dV_on (%.1f mV) must be larger than dV_off (%.1f mV)', 1e3*C.dV_on, 1e3*C.dV_off);
end
if C.dV_off < 2*C.lsb || C.dV_on < 4*C.lsb
    msgs{end+1} = fmtmsg('WARNING', 'thresholds %.1f / %.1f mV are below 4 / 2 ADC counts (%.2f mV per count): noise can stall balancing', ...
        1e3*C.dV_on, 1e3*C.dV_off, 1e3*C.lsb);
end

%% Bleed resistor
I  = Vnom / (P.R_bleed + P.R_on);
Pw = Vmax^2 / P.R_bleed;
Tss = P.T_amb + P.Rth_res * Pw;
est.I_bleed_A = I; est.T_res_ss_C = Tss;
if Pw > P.P_res_rating
    msgs{end+1} = fmtmsg('ERROR', 'bleed resistor dissipates %.2f W at %.2f V but is rated %.2f W', Pw, Vmax, P.P_res_rating);
elseif Pw > 0.5 * P.P_res_rating
    msgs{end+1} = fmtmsg('WARNING', 'bleed resistor runs at %.0f%% of its %.1f W rating (keep below ~50%%)', 100*Pw/P.P_res_rating, P.P_res_rating);
end
if Tss > C.T_res_max
    msgs{end+1} = fmtmsg('WARNING', 'bleed resistor would reach ~%.0f C > T_res_max %.0f C: passive balancing will trip the fault', Tss, C.T_res_max);
elseif Tss > C.T_res_warn
    msgs{end+1} = fmtmsg('WARNING', 'bleed resistor reaches ~%.0f C (> warning level %.0f C)', Tss, C.T_res_warn);
end

%% Discrete control: voltage drop in one bleed window must be < dV_on
if isCell
    slope = max(diff(ocv(:)) ./ diff(P.SOC_vec(:)));          % V per unit SOC (steepest)
    dVwin = slope * I * C.n_on / (P.AH * 3600);
else
    dVwin = I * C.n_on / P.C_emu;
end
if dVwin >= C.dV_on
    msgs{end+1} = fmtmsg('ERROR', 'one %d s bleed window drops up to %.1f mV >= dV_on %.1f mV: controller will overshoot (shorten n_on or raise R/C)', ...
        C.n_on, 1e3*dVwin, 1e3*C.dV_on);
end

%% Run length estimate (passive, to full equalisation, with rest duty)
duty = C.n_on / (C.n_on + C.n_rest + 1);
if isCell
    dQ = (max(P.SOC0) - min(P.SOC0)) * P.AH * 3600;            % C
else
    dQ = (max(P.Vc0_emu) - min(P.Vc0_emu)) * P.C_emu;
end
est.t_passive_s = dQ / I / duty;
if est.t_passive_s > P.StopTime
    msgs{end+1} = fmtmsg('WARNING', 'passive balancing needs ~%.1f h but StopTime is %.1f h (run_experiments sizes runs automatically)', ...
        est.t_passive_s/3600, P.StopTime/3600);
end

%% Active stage
dVadj = abs(diff(V0));
Ipk = max(dVadj) / P.R_eq;
if Ipk > C.I_sc_max
    msgs{end+1} = fmtmsg('INFO', 'SC pair would start at %.2f A; burst gating limits it to %.2f A', Ipk, C.I_sc_max);
end

%% SOC for the low-voltage test: OCV halfway between V_uv and V_lv
if isCell
    est.SOC_lowV = interp1(ocv, P.SOC_vec, (C.V_uv + C.V_lv) / 2);
else
    est.SOC_lowV = NaN;
end

if verbose
    fprintf('Parameter check (%s): I_bleed %.0f mA, resistor ~%.0f C, passive ~%.2f h, R_eq %.3f Ohm\n', ...
        P.plant, 1e3*I, Tss, est.t_passive_s/3600, P.R_eq);
    if isempty(msgs), fprintf('  all checks passed\n'); else, fprintf('  %s\n', msgs{:}); end
end
end

function s = fmtmsg(lvl, fmt, varargin)
s = sprintf(['%-8s ' fmt], [lvl ':'], varargin{:});
end
