function observers = state_space_observer_design(models, sampleRateHz)
%STATE_SPACE_OBSERVER_DESIGN Design the X/Y acceleration Kalman filters.

% Ratios selected by replaying the 35 Hz capture. They are the strongest
% gains that do not amplify acceleration-to-position correction above unity.
Q_OVER_R_X = 1.0e-13;
Q_OVER_R_Y = 3.0e-13;

if nargin < 2
    sampleRateHz = 250.0;
end
if nargin < 1 || ~isfield(models, "x") || ~isfield(models, "y")
    error("Pass the models structure returned by frf_sweep_analysis.");
end

sampleTimeS = 1.0 / sampleRateHz;
observers.x = state_space_observer_axis( ...
    models.x, Q_OVER_R_X, sampleTimeS);
observers.y = state_space_observer_axis( ...
    models.y, Q_OVER_R_Y, sampleTimeS);

printSummary(observers.x);
printSummary(observers.y);
end


function printSummary(observer)
fprintf("\n%s-axis discrete Kalman observer\n", observer.axis);
fprintf("  states: %d\n", observer.state_count);
fprintf("  Q/R: %.3g\n", observer.process_measurement_ratio);
fprintf("  sample rate: %.1f Hz\n", 1.0 / observer.sample_time_s);
fprintf("  largest pole magnitude: %.6f\n", max(abs(observer.poles)));
end
