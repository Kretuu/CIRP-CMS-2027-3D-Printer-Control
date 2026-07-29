function controllerModel = frf_controller_model(model)
%FRF_CONTROLLER_MODEL Convert an identified FRF model for Klipper use.
%
% The measured acceleration FRF describes the axis dynamics over the tested
% frequency range, but a commanded stationary position must produce the same
% stationary tool position. The numerator is therefore scaled to unity DC gain
% before zero-order-hold discretisation at the controller's fixed 1 ms period.

SAMPLE_TIME_S = 0.001;

dcGain = model.numerator(end) / model.denominator(end);
if ~isfinite(dcGain) || abs(dcGain) < 1e-12
    error("The %s-axis model has no usable DC gain.", model.axis);
end

unityDcNumerator = model.numerator / dcGain;
discreteSystem = c2d( ...
    tf(unityDcNumerator, model.denominator), SAMPLE_TIME_S, "zoh");
if ~isstable(discreteSystem)
    error("The discrete %s-axis controller model is unstable.", model.axis);
end
[numerator, denominator] = tfdata(discreteSystem, "v");

controllerModel = struct();
controllerModel.sample_time_s = SAMPLE_TIME_S;
controllerModel.numerator = numerator;
controllerModel.denominator = denominator;
controllerModel.dc_gain = sum(numerator) / sum(denominator);
end
