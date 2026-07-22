function steady = frf_select_steady_state(aligned, metadata)
%FRF_SELECT_STEADY_STATE Select samples after the ramp and one-cycle guard.

STEADY_MARGIN_CYCLES = 1.0;
MIN_FIT_SAMPLES = 20;

frequencyHz = double(metadata.frequency_hz);
duration = double(metadata.duration_s);
rampTime = double(metadata.ramp_time_s);

steadyStart = rampTime + STEADY_MARGIN_CYCLES / frequencyHz;
steadyEnd = duration - rampTime - STEADY_MARGIN_CYCLES / frequencyHz;
rows = aligned.time_s > steadyStart ...
    & aligned.time_s < steadyEnd ...
    & isfinite(aligned.input_accel_mm_s2) ...
    & isfinite(aligned.output_accel_mm_s2);

if nnz(rows) < MIN_FIT_SAMPLES
    error("Only %d steady-state samples in %s; at least %d are required.", ...
        nnz(rows), aligned.point_dir, MIN_FIT_SAMPLES);
end

steady = struct();
steady.start_s = steadyStart;
steady.end_s = steadyEnd;
steady.time_s = aligned.time_s(rows);
steady.input_accel_mm_s2 = aligned.input_accel_mm_s2(rows);
steady.output_accel_mm_s2 = aligned.output_accel_mm_s2(rows);
end
