function [amplitude, phase] = frf_fit_harmonic(t, y, omega)
%FRF_FIT_HARMONIC Fit y = b*sin(omega*t) + c*cos(omega*t) + d.
%
% The equivalent cosine form has amplitude A = sqrt(b^2 + c^2) and
% phase phi = atan2(-b, c).

t = t(:);
y = y(:);
if numel(t) ~= numel(y) || numel(t) < 3
    error("A harmonic fit requires matching vectors with at least three samples.");
end

coefficients = [sin(omega * t), cos(omega * t), ones(size(t))] \ y;
amplitude = hypot(coefficients(1), coefficients(2));
phase = atan2(-coefficients(1), coefficients(2));
end
