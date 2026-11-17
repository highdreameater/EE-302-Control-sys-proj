%% run_all.m — entry point for the EE302 PS-3 battery-balancing simulation
%
% Builds the Simulink/Simscape models from code (models/), runs every
% experiment and the switched-capacitor characterisation, and writes all
% tables, raw time series and figures to results/. Takes about 2 minutes.
%
% Requires MATLAB R2026a (or newer) with Simulink, Simscape,
% Simscape Electrical and Simscape Battery. Stateflow is NOT needed.
%
% To use your own component values, edit src/params_4cell.m and run this
% file again. See ../../README.md for the parameter table.

root = fileparts(mfilename('fullpath'));
addpath(fullfile(root, 'src'), fullfile(root, 'build'), fullfile(root, 'experiments'));
run(fullfile(root, 'experiments', 'run_experiments.m'));
