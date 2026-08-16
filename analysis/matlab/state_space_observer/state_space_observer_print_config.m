function state_space_observer_print_config(observers)
%STATE_SPACE_OBSERVER_PRINT_CONFIG Print Klipper observer configuration.
%
%   observers = state_space_observer_design(models, 250);
%   state_space_observer_print_config(observers);

if nargin ~= 1 || ~isfield(observers, "x") || ~isfield(observers, "y")
    error("Pass the result returned by state_space_observer_design.");
end

sampleRateX = 1.0 / observers.x.sample_time_s;
sampleRateY = 1.0 / observers.y.sample_time_s;
if abs(sampleRateX - sampleRateY) > 1e-9
    error("X and Y observers must use the same sample rate.");
end

fprintf("observer_enabled: True\n");
fprintf("observer_sample_rate: %.16g\n", sampleRateX);
fprintf("observer_bias_samples: 100\n");
fprintf("observer_x_accel_sign: -1\n");
fprintf("observer_y_accel_sign: 1\n");
printAxis("x", observers.x);
printAxis("y", observers.y);
end


function printAxis(axisName, observer)
%PRINTAXIS Print one flat, row-major set of runtime matrices.

fprintf("observer_%s_state_count: %d\n", axisName, observer.state_count);
printList("observer_" + axisName + "_fo", reshape(observer.Fo.', 1, []));
printList("observer_" + axisName + "_gu", observer.Gu);
printList("observer_" + axisName + "_gv", observer.Gv);
printList("observer_" + axisName + "_ga", observer.Ga);
printList("observer_" + axisName + "_ho", observer.Ho);
printList("observer_" + axisName + "_x0_per_mm", observer.x0_per_mm);
end


function printList(name, values)
%PRINTLIST Print a Klipper-compatible comma-separated coefficient list.

values = values(:).';
fprintf("%s:\n    %.17g", name, values(1));
fprintf(",\n    %.17g", values(2:end));
fprintf("\n");
end
