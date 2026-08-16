function aligned = frf_align_signals(pointDir, metadata)
%FRF_ALIGN_SIGNALS Put commanded input and measured output on one time axis.
% Internal helper for the FRF-identification workflow.

RAW_TO_MM_S2 = 10.0;         % BNO055: 1 LSB = 0.01 m/s^2 = 10 mm/s^2.
EXPECTED_SYNC_SAMPLES = 40;
SYNC_RTT_TOLERANCE_S = 1e-3; % Experiment-specific USB RTT margin.

axisName = upper(string(metadata.axis));
[sensorChip, sensorColumn] = sensorForAxis(axisName);

samples = readtable(fullfile(pointDir, "samples.csv"), "TextType", "string");
sync = readtable(fullfile(pointDir, "sync.csv"), "TextType", "string");
input = readtable(fullfile(pointDir, "input.csv"), "TextType", "string");

clockModel = fitClockModel(sync, EXPECTED_SYNC_SAMPLES, ...
    SYNC_RTT_TOLERANCE_S);
[samplePrintTime, outputAccel] = readOutputSamples(samples, clockModel, ...
    sensorChip, sensorColumn, RAW_TO_MM_S2);
inputAccel = sampleInputAcceleration(input, samplePrintTime);

inputStartPrintTime = double(input.print_time_s(1));
aligned = struct();
aligned.point_dir = string(pointDir);
aligned.time_s = samplePrintTime - inputStartPrintTime;
aligned.output_accel_mm_s2 = outputAccel;
aligned.input_accel_mm_s2 = inputAccel;
aligned.input_segment_time_s = double(input.relative_t_s);
aligned.input_segment_accel_mm_s2 = double(input.accel_mm_s2);
aligned.clock_model = clockModel;
end


function clock = fitClockModel(sync, expectedSyncSamples, rttTolerance)
%FITCLOCKMODEL Estimate print_time = theta0 + theta1 * Trinkey time.

trinkeyTime = double(sync.trinkey_t_us) * 1e-6;
printTime = double(sync.print_time_mid_s);
rtt = double(sync.rtt_s);
phase = string(sync.phase);
valid = isfinite(trinkeyTime) & isfinite(printTime) & isfinite(rtt);
trinkeyTime = trinkeyTime(valid);
printTime = printTime(valid);
rtt = rtt(valid);
phase = phase(valid);

if numel(trinkeyTime) ~= expectedSyncSamples
    error("Expected %d valid sync samples, found %d.", ...
        expectedSyncSamples, numel(trinkeyTime));
end

rttMinimum = min(rtt);
rttLimit = rttMinimum + rttTolerance;
accepted = rtt <= rttLimit;
if nnz(accepted) < 3
    error("RTT filter retained only %d sync samples; at least 3 are required.", ...
        nnz(accepted));
end
if ~any(phase == "pre") || ~any(phase == "post")
    error("Synchronization data must contain both pre and post samples.");
end
if ~any(phase(accepted) == "pre") || ~any(phase(accepted) == "post")
    error("RTT filter must retain at least one pre and one post sample.");
end

trinkeyTime = trinkeyTime(accepted);
printTime = printTime(accepted);
theta = [ones(size(trinkeyTime)), trinkeyTime] \ printTime;

clock = struct();
clock.theta0_print_time_s = theta(1);
clock.theta1_print_s_per_trinkey_s = theta(2);
clock.sync_samples_total = numel(accepted);
clock.sync_samples_accepted = nnz(accepted);
clock.rtt_minimum_s = rttMinimum;
clock.rtt_limit_s = rttLimit;
clock.rtt_tolerance_s = rttTolerance;
end


function [printTime, accel] = readOutputSamples(samples, clock, sensorChip, ...
    sensorColumn, rawToMmS2)
%READOUTPUTSAMPLES Select one accelerometer channel and map its timestamps.

sampleRows = string(samples.chip_id) == sensorChip;
if ~any(sampleRows)
    error("No samples for chip %s.", sensorChip);
end

tUs = double(samples.t_us(sampleRows));
rawAccel = double(samples.(char(sensorColumn))(sampleRows));
valid = isfinite(tUs) & isfinite(rawAccel);
tUs = tUs(valid);
rawAccel = rawAccel(valid);
[tUs, order] = sort(tUs);
rawAccel = rawAccel(order);

trinkeyTime = tUs * 1e-6;
printTime = clock.theta0_print_time_s ...
    + clock.theta1_print_s_per_trinkey_s * trinkeyTime;
accel = rawToMmS2 * rawAccel;
end


function inputAccel = sampleInputAcceleration(input, samplePrintTime)
%SAMPLEINPUTACCELERATION Evaluate logged piecewise-constant input at samples.

segmentStart = double(input.print_time_s);
segmentEnd = segmentStart + double(input.dt_s);
segmentAccel = double(input.accel_mm_s2);

% Zero order hold
inputAccel = interp1(segmentStart, segmentAccel, samplePrintTime, ...
    "previous", NaN);
inputAccel(samplePrintTime < segmentStart(1)) = NaN;
inputAccel(samplePrintTime >= segmentEnd(end)) = NaN;
end


function [sensorChip, sensorColumn] = sensorForAxis(axisName)
%SENSORFORAXIS Return the dissertation-specific sensor channel for X or Y.

if axisName == "X"
    sensorChip = "toolhead";
    sensorColumn = "ax_raw";
elseif axisName == "Y"
    sensorChip = "base";
    sensorColumn = "ay_raw";
else
    error("Only X and Y axes are supported.");
end
end
