function point = frf_extract_point(pointDir, includeTimeSeries)
%FRF_EXTRACT_POINT Estimate one FRF value from one frequency test.

metadata = jsondecode(fileread(fullfile(pointDir, "metadata.json")));
axisName = upper(string(metadata.axis));
frequencyHz = double(metadata.frequency_hz);
omega = 2.0 * pi * frequencyHz;

aligned = frf_align_signals(pointDir, metadata);
steady = frf_select_steady_state(aligned, metadata);
[inputAmplitude, inputPhase] = frf_fit_harmonic( ...
    steady.time_s, steady.input_accel_mm_s2, omega);
[outputAmplitude, outputPhase] = frf_fit_harmonic( ...
    steady.time_s, steady.output_accel_mm_s2, omega);

frfMagnitude = outputAmplitude / inputAmplitude;
frfPhase = outputPhase - inputPhase;
frfPhase = atan2(sin(frfPhase), cos(frfPhase));
frfValue = frfMagnitude * exp(1i * frfPhase);
if ~isfinite(frfValue)
    error("The harmonic fit produced a non-finite FRF in %s.", pointDir);
end

displacementAmplitude = double(metadata.amplitude_mm);
withinStepResolution = 2.0 * displacementAmplitude ...
    >= configuredStepDistance(axisName);

point = struct();
point.axis = axisName;
point.frequency_hz = frequencyHz;
point.duration_s = double(metadata.duration_s);
point.ramp_time_s = double(metadata.ramp_time_s);
point.motion_start_s = 0.0;
point.steady_start_s = steady.start_s;
point.steady_end_s = steady.end_s;
point.frf = frfValue;
point.within_step_resolution = withinStepResolution;

point.time_s = [];
point.accel_mm_s2 = [];
point.input_segment_time_s = [];
point.input_segment_accel_mm_s2 = [];
if includeTimeSeries
    point.time_s = aligned.time_s;
    point.accel_mm_s2 = aligned.output_accel_mm_s2;
    point.input_segment_time_s = aligned.input_segment_time_s;
    point.input_segment_accel_mm_s2 = aligned.input_segment_accel_mm_s2;
end
end


function stepDistance = configuredStepDistance(axisName)
%CONFIGUREDSTEPDISTANCE Return one configured microstep in millimetres.

if axisName == "X"
    stepDistance = 0.0125;
elseif axisName == "Y"
    stepDistance = 0.01875;
else
    error("Only X and Y axes are supported.");
end
end
