function [Vm, Tcm, Trm] = adc_measure(V, Tc, Tr, noise, C)
%ADC_MEASURE  Model of the measurement chain: gain/offset error, noise and
% ADC quantisation. Gain/offset errors come from the calibration against
% the multimeter (PS requirement 1); set them to the residual errors left
% AFTER calibration to see their effect on balancing accuracy.
Vm  = V(:) .* (1 + C.gain_err(:)) + C.offset_err(:) + noise(:);
Vm  = round(Vm / C.lsb) * C.lsb;
Tcm = round(Tc(:) / C.T_lsb) * C.T_lsb;
Trm = round(Tr(:) / C.T_lsb) * C.T_lsb;
end
