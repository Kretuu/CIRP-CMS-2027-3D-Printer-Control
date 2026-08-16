function model = frf_identify_model(axisResult)
%FRF_IDENTIFY_MODEL Fit a continuous-time model using INVFREQS.
% Internal helper for the FRF-identification workflow.
%
% The model orders follow the printer models used by Duan et al.: fifth-order
% numerator and sixth-order denominator for X, and sixth-order numerator and
% seventh-order denominator for Y. Frequencies are normalised during fitting to
% avoid ill-conditioning, then the coefficients are converted back to rad/s.

ITERATIONS = 5;
TOLERANCE = 1e-6;

if axisResult.axis == "X"
    numeratorOrder = 5;
    denominatorOrder = 6;
elseif axisResult.axis == "Y"
    numeratorOrder = 6;
    denominatorOrder = 7;
else
    error("Only X and Y axes are supported.");
end

rows = axisResult.used_for_frf;
omega = 2.0 * pi * axisResult.frequency_hz(rows);
measuredFrf = axisResult.frf(rows);
omegaScale = sqrt(min(omega) * max(omega));
normalisedOmega = omega / omegaScale;

% Give lower frequencies greater influence, as in the reference printer fit.
weights = sqrt(min(omega) ./ omega);
[normalisedNumerator, normalisedDenominator] = invfreqs( ...
    measuredFrf, normalisedOmega, numeratorOrder, denominatorOrder, ...
    weights, ITERATIONS, TOLERANCE);

denominator = normalisedDenominator ...
    .* omegaScale .^ (0:denominatorOrder);
numerator = normalisedNumerator ...
    .* omegaScale .^ ((denominatorOrder - numeratorOrder):denominatorOrder);
fittedFrf = freqs(numerator, denominator, omega);

model = struct();
model.axis = axisResult.axis;
model.numerator_order = numeratorOrder;
model.denominator_order = denominatorOrder;
model.numerator = numerator;
model.denominator = denominator;
model.poles = roots(denominator);
model.minimum_omega_rad_s = min(omega);
model.maximum_omega_rad_s = max(omega);
model.relative_rms_error = norm(measuredFrf - fittedFrf) / norm(measuredFrf);

if any(real(model.poles) >= 0.0)
    error("INVFREQS produced an unstable %s-axis model.", axisResult.axis);
end

model.controller = frf_controller_model(model);
end
