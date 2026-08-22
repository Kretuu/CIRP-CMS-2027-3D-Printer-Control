function analysis = sine_tracking_analyze_capture( ...
        capture, specification, configuration)
%SINE_TRACKING_ANALYZE_CAPTURE Validate one capture and analyze its passes.

samples = sortrows(capture.toolhead, "time");
requiredVariables = ["time", "device_time_us", "sample_sequence", ...
    "flags", "desired_x_position", "desired_x_acceleration", ...
    "observed_x_position", "observer_valid", "reference_valid"];
missingVariables = setdiff( ...
    requiredVariables, string(samples.Properties.VariableNames));
if ~isempty(missingVariables)
    error("Capture is missing column(s): %s", strjoin(missingVariables, ", "));
end

time = double(samples.time);
deviceTimeUs = double(samples.device_time_us);
sequence = double(samples.sample_sequence);
desiredPosition = double(samples.desired_x_position);
desiredAcceleration = double(samples.desired_x_acceleration);
observedPosition = double(samples.observed_x_position);
referenceValid = double(samples.reference_valid) ~= 0;
observerValid = double(samples.observer_valid) ~= 0;
toolheadValid = bitand(uint32(samples.flags), uint32(2)) ~= 0;

if numel(time) < 2 || any(diff(time) <= 0) || any(diff(deviceTimeUs) <= 0)
    error("Toolhead sample timestamps are not strictly increasing.");
end

samplePeriodS = median(diff(deviceTimeUs)) * 1e-6;
sampleRateHz = 1.0 / samplePeriodS;
sequenceBreaks = nnz(diff(sequence) ~= 1);
gapThresholdUs = configuration.maximum_sample_gap_periods ...
    * samplePeriodS * 1e6;
largeSampleGaps = nnz(diff(deviceTimeUs) > gapThresholdUs);
maximumGapMs = max(diff(deviceTimeUs)) * 1e-3;
invalidReferences = nnz(~referenceValid);
invalidObservers = nnz(~observerValid);
invalidToolheadFlags = nnz(~toolheadValid);

expectedDurationS = configuration.cycles_per_pass ...
    / specification.nominal_frequency_hz;
activity = abs(desiredAcceleration) ...
    > configuration.command_activity_threshold_mm_s2 ...
    & referenceValid & observerValid & toolheadValid;
groups = findActivityGroups( ...
    time(activity), configuration.activity_group_gap_s);

minimumDuration = configuration.minimum_group_duration_fraction ...
    * expectedDurationS;
maximumDuration = configuration.maximum_group_duration_fraction ...
    * expectedDurationS;
durations = arrayfun(@(group) group.end_time - group.start_time, groups);
candidateGroups = groups(durations >= minimumDuration ...
    & durations <= maximumDuration);
if numel(candidateGroups) > configuration.expected_pass_count
    candidateGroups = candidateGroups( ...
        end - configuration.expected_pass_count + 1:end);
end

passCount = numel(candidateGroups);
failureReasons = strings(0, 1);
if passCount ~= configuration.expected_pass_count
    failureReasons(end + 1) = sprintf( ...
        "found %d/%d sine passes", passCount, ...
        configuration.expected_pass_count);
end
passRows = struct([]);
seriesCell = cell(passCount, 1);
for passIndex = 1:passCount
    group = candidateGroups(passIndex);
    [passRow, seriesCell{passIndex}] = analyzePass( ...
        time, deviceTimeUs, sequence, desiredPosition, observedPosition, ...
        referenceValid, observerValid, toolheadValid, group, passIndex, ...
        specification, configuration, samplePeriodS);
    if isempty(passRows)
        passRows = passRow;
    else
        passRows(end + 1) = passRow; %#ok<AGROW>
    end
end
if passCount
    series = vertcat(seriesCell{:});
else
    series = struct([]);
end

if isempty(passRows)
    passTable = table();
    passGapCount = 0;
else
    passTable = struct2table(passRows);
    passGapCount = sum(passTable.sample_gap_count);
    weakPositionPasses = nnz( ...
        passTable.position_fundamental_fraction ...
        < configuration.minimum_position_fundamental_fraction);
    if weakPositionPasses > 0
        failureReasons(end + 1) = sprintf( ...
            "%d pass(es) have a weak desired-position fundamental", ...
            weakPositionPasses);
    end
    invalidEvaluatedRows = sum(passTable.invalid_reference_count) ...
        + sum(passTable.invalid_observer_count) ...
        + sum(passTable.invalid_toolhead_flag_count);
    if invalidEvaluatedRows > 0
        failureReasons(end + 1) = sprintf( ...
            "%d invalid row(s) occur inside evaluated intervals", ...
            invalidEvaluatedRows);
    end
end

completedPrint = any( ...
    capture.events.filename == specification.gcode_filename ...
    & capture.events.state == "complete");
if ~completedPrint
    failureReasons(end + 1) = "matching print did not reach complete state";
end
[hybridUsable, hybridReason] = validateHybridStatus(capture, specification);
if ~hybridUsable
    failureReasons(end + 1) = hybridReason;
end

diagnosticErrorCount = streamDiagnosticErrorCount(capture.diagnostics);
firmwareLossCount = firmwareLossCountFromDiagnostics(capture.diagnostics);
usable = isempty(failureReasons) ...
    && passCount == configuration.expected_pass_count;
clean = usable ...
    && sequenceBreaks == 0 ...
    && largeSampleGaps == 0 ...
    && passGapCount == 0 ...
    && diagnosticErrorCount == 0 ...
    && firmwareLossCount == 0;

analysis = struct();
analysis.path = capture.path;
analysis.usable = usable;
analysis.clean = clean;
analysis.failure_reason = strjoin(failureReasons, "; ");
analysis.n_samples = height(samples);
analysis.capture_duration_s = time(end) - time(1);
analysis.sample_rate_hz = sampleRateHz;
analysis.sequence_breaks = sequenceBreaks;
analysis.large_sample_gaps = largeSampleGaps;
analysis.maximum_gap_ms = maximumGapMs;
analysis.invalid_references = invalidReferences;
analysis.invalid_observers = invalidObservers;
analysis.invalid_toolhead_flags = invalidToolheadFlags;
analysis.stream_diagnostic_errors = diagnosticErrorCount;
analysis.firmware_loss_count = firmwareLossCount;
analysis.completed_print = completedPrint;
analysis.pass_count = passCount;
analysis.pass_gap_count = passGapCount;
analysis.pass_metrics = passTable;
analysis.series = series;
end


function groups = findActivityGroups(commandActivityTimes, maximumGapS)
%FINDACTIVITYGROUPS Group desired-acceleration events into sine passes.

groups = struct("start_time", {}, "end_time", {});
if isempty(commandActivityTimes)
    return;
end
starts = [1; find(diff(commandActivityTimes) > maximumGapS) + 1];
ends = [starts(2:end) - 1; numel(commandActivityTimes)];
for groupIndex = 1:numel(starts)
    indices = starts(groupIndex):ends(groupIndex);
    groups(groupIndex) = struct( ... %#ok<AGROW>
        "start_time", commandActivityTimes(indices(1)), ...
        "end_time", commandActivityTimes(indices(end)));
end
end


function [row, series] = analyzePass( ...
        time, deviceTimeUs, sequence, desiredPosition, observedPosition, ...
        referenceValid, observerValid, toolheadValid, group, passIndex, ...
        specification, configuration, samplePeriodS)
%ANALYZEPASS Compute tracking metrics for one central steady sine interval.

nominalFrequencyHz = specification.nominal_frequency_hz;
groupRows = time >= group.start_time & time <= group.end_time;
frequencyHz = estimatePositionFrequency( ...
    time(groupRows), desiredPosition(groupRows), ...
    nominalFrequencyHz, configuration);

groupCentre = 0.5 * (group.start_time + group.end_time);
evaluationDurationS = configuration.central_fraction ...
    * (group.end_time - group.start_time);
evaluationStart = groupCentre - 0.5 * evaluationDurationS;
evaluationEnd = groupCentre + 0.5 * evaluationDurationS;
rows = time >= evaluationStart & time <= evaluationEnd;

sampleTime = time(rows);
sampleDesired = desiredPosition(rows);
sampleObserved = observedPosition(rows);
sampleSequence = sequence(rows);
sampleDeviceTimeUs = deviceTimeUs(rows);
desiredAmplitude = harmonicAmplitude( ...
    sampleTime, sampleDesired, frequencyHz);
positionErrorMm = sampleDesired - sampleObserved;
positionRmsErrorUm = 1000.0 * sqrt(mean(positionErrorMm.^2));

% A missing sample normally triggers both tests above; count the affected
% boundaries once rather than twice.
sampleGapCount = max(nnz(diff(sampleSequence) ~= 1), ...
    nnz(diff(sampleDeviceTimeUs) ...
    > configuration.maximum_sample_gap_periods * samplePeriodS * 1e6));

row = struct();
row.condition = string(specification.key);
row.pass_index = passIndex;
row.group_start_print_time_s = group.start_time;
row.group_end_print_time_s = group.end_time;
row.group_duration_s = group.end_time - group.start_time;
row.evaluation_start_print_time_s = sampleTime(1);
row.evaluation_end_print_time_s = sampleTime(end);
row.evaluation_sample_count = numel(sampleTime);
row.actual_frequency_hz = frequencyHz;
row.position_fundamental_fraction = ...
    desiredAmplitude / configuration.position_amplitude_mm;
row.position_rms_error_um = positionRmsErrorUm;
row.sample_gap_count = sampleGapCount;
row.invalid_reference_count = nnz(~referenceValid(rows));
row.invalid_observer_count = nnz(~observerValid(rows));
row.invalid_toolhead_flag_count = nnz(~toolheadValid(rows));

series = struct();
series.time_s = sampleTime - sampleTime(1);
series.position_error_um = 1000.0 * positionErrorMm;
end


function frequencyHz = estimatePositionFrequency( ...
        time, desiredPosition, nominalFrequencyHz, configuration)
%ESTIMATEPOSITIONFREQUENCY Find the desired-position frequency near nominal.

lowerFrequency = configuration.frequency_search_lower_fraction ...
    * nominalFrequencyHz;
upperFrequency = configuration.frequency_search_upper_fraction ...
    * nominalFrequencyHz;
frequencyGrid = linspace(lowerFrequency, upperFrequency, ...
    configuration.frequency_search_points);
amplitude = zeros(size(frequencyGrid));
for frequencyIndex = 1:numel(frequencyGrid)
    amplitude(frequencyIndex) = harmonicAmplitude( ...
        time, desiredPosition, frequencyGrid(frequencyIndex));
end
[~, peakIndex] = max(amplitude);

if peakIndex == 1 || peakIndex == numel(frequencyGrid)
    frequencyHz = frequencyGrid(peakIndex);
    return;
end
left = frequencyGrid(peakIndex - 1);
right = frequencyGrid(peakIndex + 1);
objective = @(frequency) -harmonicAmplitude( ...
    time, desiredPosition, frequency);
frequencyHz = fminbnd(objective, left, right, ...
    optimset("Display", "off", "TolX", 1e-6));
end


function [usable, reason] = validateHybridStatus(capture, specification)
%VALIDATEHYBRIDSTATUS Confirm that a hybrid-named print used hybrid previews.

usable = true;
reason = "";
if specification.controller_mode ~= "hybrid"
    return;
end
events = capture.events;
rows = events.filtered_bspline_mode == "hybrid";
if ~any(rows)
    usable = false;
    reason = "capture contains no hybrid-controller status";
    return;
end

required = ["hybrid_x_active", "hybrid_x_solves", ...
    "hybrid_x_measurement_errors", "hybrid_x_solve_fallbacks", ...
    "hybrid_y_active", "hybrid_y_solves", ...
    "hybrid_y_measurement_errors", "hybrid_y_solve_fallbacks", ...
    "hybrid_python_observation_errors", "hybrid_worker_drops"];
if ~all(ismember(required, string(events.Properties.VariableNames)))
    usable = false;
    reason = "capture is missing required hybrid status fields";
    return;
end

activeAndSolved = events.hybrid_x_active(rows) > 0 ...
    & events.hybrid_y_active(rows) > 0 ...
    & events.hybrid_x_solves(rows) > 0 ...
    & events.hybrid_y_solves(rows) > 0;
if ~any(activeAndSolved)
    usable = false;
    reason = "both hybrid axes were not active with successful preview solves";
    return;
end
errors = [events.hybrid_x_measurement_errors(rows); ...
    events.hybrid_y_measurement_errors(rows); ...
    events.hybrid_x_solve_fallbacks(rows); ...
    events.hybrid_y_solve_fallbacks(rows); ...
    events.hybrid_python_observation_errors(rows)];
if any(errors(isfinite(errors)) ~= 0) || ~any(isfinite(errors))
    usable = false;
    reason = "hybrid measurement, fallback, or Python errors are nonzero";
    return;
end
drops = events.hybrid_worker_drops(rows);
if any(drops(isfinite(drops)) ~= 0) || ~any(isfinite(drops))
    usable = false;
    reason = "hybrid worker-drop status is missing or nonzero";
end
end


function amplitude = harmonicAmplitude(time, signal, frequencyHz)
%HARMONICAMPLITUDE Return only the fitted sinusoidal amplitude.

omega = 2.0 * pi * frequencyHz;
design = [sin(omega * time), cos(omega * time), ones(size(time))];
coefficient = design \ signal;
amplitude = hypot(coefficient(1), coefficient(2));
end


function count = streamDiagnosticErrorCount(diagnostics)
%STREAMDIAGNOSTICERRORCOUNT Sum cumulative host-side error counters.

fields = ["host_queue_drops", "frame_errors", ...
    "packet_sequence_errors", "sync_timeouts", "read_errors", ...
    "motion_lookup_errors"];
count = 0;
for field = fields
    value = diagnostics.(char(field));
    if ~isfinite(value)
        count = count + 1;
    else
        count = count + double(value);
    end
end
end


function count = firmwareLossCountFromDiagnostics(diagnostics)
%FIRMWARELOSSCOUNTFROMDIAGNOSTICS Sum firmware loss and overrun counters.

count = 0;
if ~isstruct(diagnostics.firmware) || isempty(fieldnames(diagnostics.firmware))
    count = 1;
    return;
end
fields = ["dropped", "transport_dropped", "overruns"];
for field = fields
    name = char(field);
    if ~isfield(diagnostics.firmware, name)
        count = count + 1;
    else
        count = count + double(diagnostics.firmware.(name));
    end
end
end
