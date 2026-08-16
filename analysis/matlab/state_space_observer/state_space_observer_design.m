function observers = state_space_observer_design(models, sampleRateHz)
%STATE_SPACE_OBSERVER_DESIGN Design the X/Y acceleration observers.
%
% This follows the observer-design sequence used in the ELE460 laboratory:
% define the state-space plant, check observability, calculate L by dual pole
% placement, and verify the achieved observer poles.
%
% The input is the models structure returned by frf_sweep_analysis:
%
%   [~, models] = frf_sweep_analysis(runDirs);
%   observers = state_space_observer_design(models, 250);

OBSERVER_BANDWIDTH_HZ = 5.0;

if nargin < 2
    sampleRateHz = 250.0;
end
if nargin < 1 || ~isfield(models, "x") || ~isfield(models, "y")
    error("Pass the models structure returned by frf_sweep_analysis.");
end
if ~isscalar(sampleRateHz) || ~isfinite(sampleRateHz) || sampleRateHz <= 0.0
    error("The observer sample rate must be a positive scalar.");
end

sampleTimeS = 1.0 / sampleRateHz;

observers.x = state_space_observer_axis( ...
    models.x, OBSERVER_BANDWIDTH_HZ, sampleTimeS);
observers.y = state_space_observer_axis( ...
    models.y, OBSERVER_BANDWIDTH_HZ, sampleTimeS);

printSummary(observers.x);
printSummary(observers.y);
end


function printSummary(observer)
%PRINTSUMMARY Display the checks that matter before exporting the matrices.

fprintf("\n%s-axis state-space acceleration observer\n", observer.axis);
fprintf("  states: %d\n", observer.state_count);
fprintf("  acceleration-observable order: %d/%d\n", ...
    observer.observable_order, observer.state_count);
fprintf("  observer bandwidth: %.1f Hz\n", observer.bandwidth_hz);
fprintf("  sample rate: %.1f Hz\n", 1.0 / observer.sample_time_s);
fprintf("  pole-placement relative error: %.3g\n", ...
    observer.pole_relative_error);
fprintf("  largest discrete pole magnitude: %.6f\n", ...
    max(abs(eig(observer.Fo))));
end
