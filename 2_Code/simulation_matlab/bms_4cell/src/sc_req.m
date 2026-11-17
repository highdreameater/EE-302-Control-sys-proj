function Req = sc_req(f, C, Rloop, D)
%SC_REQ  Equivalent resistance of a 2-phase switched-capacitor cell equaliser.
%
%   Req = sc_req(f_sw, C_fly, R_loop)        50 % duty per phase (no dead time)
%   Req = sc_req(f_sw, C_fly, R_loop, D)     each phase conducts D*T (D < 0.5 with dead time)
%
% The flying capacitor C is connected alternately across cell k and cell
% k+1. Each phase loop has resistance R_loop (2 x MOSFET Ron + capacitor
% ESR + cell internal resistance). The average current moved from cell k
% to cell k+1 is
%       I = (V_k - V_k+1) / Req,
%       Req = 1/(f C) * (1 + e^-x) / (1 - e^-x),   x = D / (f R_loop C)
% Limits:  slow switching (x >> 1)  Req -> 1/(f C)         (SSL)
%          fast switching (x << 1)  Req -> 2 R_loop / D    (FSL, = 4 R_loop at D = 0.5)
% The power lost in the converter is I^2 * Req = I * dV, so efficiency of a
% single transfer is V_k+1 / V_k: the closer the cells, the less is lost.
% Verified against the switch-level model in sc_characterize.m.
if nargin < 4, D = 0.5; end
x   = D ./ (f .* Rloop .* C);
Req = 1 ./ (f .* C) .* (1 + exp(-x)) ./ (1 - exp(-x));
end
