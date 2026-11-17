function [P, C] = params_4cell(plant)
%PARAMS_4CELL  Parameters for the 4-cell passive balancing model (EE302 PS-3).
%
%   [P, C] = params_4cell('cell')      4 x 18650 Li-ion cells (default)
%   [P, C] = params_4cell('emulator')  4 x supercapacitor test emulator
%
%   P : plant parameters (cells, bleed circuit, thermal, sensors, scenario)
%   C : controller parameters (passed to bms_controller and adc_measure)
%       C is written so it maps 1:1 to #defines in the Arduino firmware.
%
% HOW TO USE YOUR OWN VALUES: change numbers in this file only, then run
% run_all.m. No other code needs editing. check_params.m runs first and
% warns when values do not fit together (thresholds vs ADC resolution,
% resistor power/temperature, controller overshoot, run length).
% Every value marked [MEASURE] should be replaced by your measured value
% once the hardware exists (resistor value, MOSFET Ron, cell capacity ...).

if nargin < 1, plant = 'cell'; end
P.plant = plant;
P.N     = 4;                         % cells in series

%% ---------------- Cells: generic 18650 NMC Li-ion ----------------------
P.AH      = 2.5;                     % Ah per cell            [MEASURE]
P.V_nom   = 3.7;                     % V  nominal cell voltage (pack energy = N*AH*V_nom)
P.SOC_vec = [0 0.1 0.25 0.5 0.75 0.9 1];
P.T_vec   = [278 293 313];           % K
% Open-circuit voltage vs SOC (rows) and temperature (cols), V
% (3.7 V-nominal Li-ion; for LiFePO4 use ~2.5..3.65 V and change C.V_* limits)
P.V0_mat  = repmat([3.0; 3.4; 3.6; 3.7; 3.8; 4.0; 4.2], 1, 3);
% Series resistance, Ohm (typical 18650 ~30-40 mOhm)          [MEASURE]
P.R0_mat  = 4 * [.0117 .0085 .0090; .0110 .0085 .0090; .0114 .0087 .0092;
                 .0107 .0082 .0088; .0107 .0083 .0091; .0113 .0085 .0089;
                 .0116 .0085 .0089];
P.SOC0    = [0.80 0.65 0.75 0.70];   % initial SOC, cell 1 = bottom of stack
P.Cth_cell = 45;                     % J/K  (45 g x ~1000 J/kg/K)
P.A_cell   = 4.2e-3;                 % m^2  18650 surface area
P.h_conv   = 10;                     % W/m^2/K natural convection

%% ---------------- Supercapacitor emulator (safe first test) ------------
% Design rule: the voltage drop during one bleed window must be smaller
% than dV_on, i.e.  V/(R_bleed*C_emu) * n_on < dV_on, or the controller
% overshoots and "chases" the minimum cell down (seen with 10 F / 10 s).
P.C_emu   = 100;                     % F per cell                 [MEASURE]
P.V_rated_emu = 2.7;                 % V  supercapacitor voltage rating
P.ESR_emu = 0.05;                    % Ohm
P.Vc0_emu = [2.50 2.20 2.40 2.30];   % V initial

%% ---------------- Passive bleed circuit (per cell) ---------------------
P.R_bleed = 22;                      % Ohm                        [MEASURE]
P.P_res_rating = 2;                  % W  bleed-resistor power rating [MEASURE]
P.R_on    = 0.05;                    % Ohm, logic-level MOSFET Rds(on)
P.Rth_res = 70;                      % K/W  resistor hot-spot to ambient
P.tau_res = 90;                      % s    resistor thermal time constant
P.T_amb   = 25;                      % degC

%% ---------------- Active: switched-capacitor equaliser ------------------
% One flying capacitor per adjacent pair (3 for 4 cells), 4 MOSFETs each,
% driven with complementary PWM at f_sw (Arduino timer + gate drivers).
P.C_fly   = 2.2e-3;                  % F   low-ESR flying capacitor   [MEASURE]
P.ESR_fly = 0.02;                    % Ohm                            [MEASURE]
P.R_on_sc = 0.01;                    % Ohm per MOSFET (2 in each phase loop)
P.f_sw    = 2000;                    % Hz  switching frequency
P.duty_sc = 0.48;                    % conduction fraction per phase (2 % dead time)
P.R0_cell = P.R0_mat(4, 2);          % Ohm cell resistance at 50 % SOC, 20 C

%% ---------------- Sensors / ADC model ----------------------------------
% Arduino 10-bit ADC, 5 V reference, one differential amplifier per cell
% (gain 1). Use lsb = 6.144/32768 for an ADS1115 16-bit ADC instead.
C.lsb        = 5 / 1024;             % V per count
C.gain_err   = [0 0 0 0];            % per-cell gain error (from calibration)
C.offset_err = [0 0 0 0];            % per-cell offset error, V
P.noise_V    = 1e-3;                 % V rms noise on each voltage reading
P.seed       = [11 12 13 14];        % noise seeds (change for repeatability runs)
C.T_lsb      = 0.25;                 % degC per count (thermistor + ADC)

%% ---------------- Controller (voltage based) ---------------------------
C.Ts        = 1;                     % s   control loop period (Arduino loop)
% Thresholds must be several ADC counts wide: with a 10-bit ADC (4.9 mV)
% a 5 mV stop threshold = 1 count, and noise on the minimum cell can stop
% bleeding ~13 mV early (see run 'adc10_tight'). Use >= 2 / 4 counts.
C.dV_on     = 0.020;                 % V   start bleeding a cell above V_min + dV_on  (4 LSB)
C.dV_off    = 0.010;                 % V   stop when within dV_off of V_min           (2 LSB)
C.n_on      = 60;                    % s   bleed window
C.n_rest    = 5;                     % s   all switches off before measuring
C.V_bal_min = 3.30;                  % V   never bleed a cell below this
C.V_lv      = 3.30;                  % V   low-voltage alert -> inhibit balancing
C.V_uv      = 3.00;                  % V   under-voltage fault
C.V_ov      = 4.25;                  % V   over-voltage fault
C.T_cell_warn = 40;  C.T_cell_max = 45;   % degC
C.T_res_warn  = 85;  C.T_res_max  = 100;  % degC
C.I_sc_max  = 0.5;                   % A   switched-capacitor pair current limit

%% ---------------- Scenario defaults ------------------------------------
P.mode_req  = 1;                     % 0 monitor only, 1 passive, 2 active
P.t_stop    = inf;                   % s  manual-stop button press time
P.StopTime  = 4 * 3600;              % s
P.log_dt    = 5;                     % s  logging interval
P.R_sweep   = [10 22 47 100];        % Ohm bleed values for the resistor sweep
P.R_overtemp = 4.7;                  % Ohm deliberately undersized bleed for the over-temp fault test

%% ---------------- Emulator overrides -----------------------------------
if strcmp(plant, 'emulator')
    C.V_bal_min = 1.0;  C.V_lv = 1.0;  C.V_uv = 0.5;  C.V_ov = 2.75;
    C.n_on  = 5;        C.n_rest = 2;    % 2.5 V/(22*100) * 5 s = 5.7 mV < dV_on
    P.StopTime = 1200;  P.log_dt = 1;
end

%% ---------------- Derived ----------------------------------------------
if strcmp(plant, 'emulator'), Rsrc = P.ESR_emu; else, Rsrc = P.R0_cell; end
P.R_loop = 2 * P.R_on_sc + P.ESR_fly + Rsrc;   % one phase loop
P.R_eq   = sc_req(P.f_sw, P.C_fly, P.R_loop, P.duty_sc);   % averaged-model resistance
C.R_eq   = P.R_eq;                       % controller copy (current limit)
end
