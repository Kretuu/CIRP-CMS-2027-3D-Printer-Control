function report = sine_tracking_analysis(dataDirectory, outputDirectory)
%SINE_TRACKING_ANALYSIS Compare uncompensated and standard-FBF sine prints.
%
% Run from the repository root:
%
%   addpath("analysis/matlab/sine_tracking");
%   report = sine_tracking_analysis();
%
% The function discovers the newest run number for each 10/35 Hz and
% uncompensated/standard-FBF condition.  If the newest capture does not contain
% all six sine passes, it records the rejection and falls back to the newest
% analyzable capture.  Capture integrity and fallback decisions are written to
% sine_tracking_capture_review.csv.
%
% The evaluation is deliberately limited to directly measured acceleration
% tracking error.  For each pass it reports RMS error and NRMSE, where the
% latter permits a fair relative comparison between the 10 and 35 Hz cases.
% Complete position trajectory error is not estimated by this script.

scriptDirectory = string(fileparts(mfilename("fullpath")));
repositoryRoot = string(fileparts(fileparts(fileparts(scriptDirectory))));
if nargin < 1 || strlength(string(dataDirectory)) == 0
    dataDirectory = fullfile(repositoryRoot, "data", "motan");
end
if nargin < 2 || strlength(string(outputDirectory)) == 0
    outputDirectory = fullfile( ...
        repositoryRoot, "data", "processed", "sine_tracking");
end
dataDirectory = string(dataDirectory);
outputDirectory = string(outputDirectory);
if ~isfolder(dataDirectory)
    error("Motan data directory does not exist: %s", dataDirectory);
end
if ~isfolder(outputDirectory)
    mkdir(outputDirectory);
end

configuration = analysisConfiguration();
specifications = conditionSpecifications();
selectedCell = cell(numel(specifications), 1);
reviewRows = struct([]);

for specificationIndex = 1:numel(specifications)
    specification = specifications(specificationIndex);
    candidates = discoverCandidates(dataDirectory, specification.pattern);
    if isempty(candidates)
        error("No captures match %s in %s.", ...
            specification.pattern, dataDirectory);
    end

    foundUsable = false;
    for candidateIndex = 1:numel(candidates)
        candidate = candidates(candidateIndex);
        try
            capture = motan_lightweight_load(candidate.path);
            analysis = analyzeCapture(capture, specification, configuration);
        catch exception
            analysis = failedAnalysis(candidate.path, exception.message);
        end

        row = captureReviewRow( ...
            specification, candidate, analysis, candidateIndex == 1);
        row.selected = analysis.usable;
        reviewRows = appendStruct(reviewRows, row);

        if analysis.usable
            analysis.condition = specification;
            analysis.run_number = candidate.run_number;
            analysis.is_latest = candidateIndex == 1;
            selectedCell{specificationIndex} = analysis;
            foundUsable = true;
            break;
        end
    end

    if ~foundUsable
        reviewTable = struct2table(reviewRows);
        writetable(reviewTable, fullfile( ...
            outputDirectory, "sine_tracking_capture_review.csv"));
        error("No usable capture was found for %s.", specification.label);
    end
end

selected = vertcat(selectedCell{:});
reviewTable = struct2table(reviewRows);
passTable = concatenatePassTables(selected);
summaryTable = summarizeConditions(selected, passTable);

writetable(reviewTable, fullfile( ...
    outputDirectory, "sine_tracking_capture_review.csv"));
writetable(passTable, fullfile( ...
    outputDirectory, "sine_tracking_pass_metrics.csv"));
writetable(summaryTable, fullfile( ...
    outputDirectory, "sine_tracking_summary.csv"));

plotAccelerationErrorHistory(selected, outputDirectory);
plotAccelerationNrmse(passTable, outputDirectory);

printCaptureReview(reviewTable);
printSummary(summaryTable);
printPairedImprovements(summaryTable);

report = struct();
report.configuration = configuration;
report.capture_review = reviewTable;
report.pass_metrics = passTable;
report.summary = summaryTable;
report.selected = selected;
report.output_directory = outputDirectory;
end


function configuration = analysisConfiguration()
%ANALYSISCONFIGURATION Fixed reconstruction and measurement conventions.

configuration.position_amplitude_mm = 0.5;
configuration.cycles_per_pass = 100;
configuration.expected_pass_count = 6;
configuration.central_fraction = 0.8;
configuration.command_activity_threshold_mm_s2 = 1.0;
configuration.activity_group_gap_s = 1.0;
configuration.minimum_group_duration_fraction = 0.75;
configuration.maximum_group_duration_fraction = 1.30;
configuration.frequency_search_lower_fraction = 0.85;
configuration.frequency_search_upper_fraction = 1.02;
configuration.frequency_search_points = 341;
configuration.toolhead_x_sign = -1.0;
configuration.maximum_sample_gap_periods = 1.6;
configuration.minimum_command_fundamental_fraction = 0.20;
end


function specifications = conditionSpecifications()
%CONDITIONSPECIFICATIONS Describe the four experimental conditions.

specifications = struct( ...
    "key", {"sine10_uncomp", "sine10_comp", ...
            "sine35_uncomp", "sine35_comp"}, ...
    "label", {"10 Hz, no compensation", "10 Hz, standard FBF", ...
              "35 Hz, no compensation", "35 Hz, standard FBF"}, ...
    "short_label", {"No compensation", "Standard FBF", ...
                    "No compensation", "Standard FBF"}, ...
    "nominal_frequency_hz", {10, 10, 35, 35}, ...
    "compensated", {false, true, false, true}, ...
    "pattern", {"sine10_uncomp_r*.json.gz", ...
                "sine10_comp_r*.json.gz", ...
                "sine35_uncomp_r*.json.gz", ...
                "sine35_comp_r*.json.gz"}, ...
    "gcode_filename", {"sine_10hz_uncompensated.gcode", ...
                       "sine_10hz_filtered_bspline.gcode", ...
                       "sine_35hz_uncompensated.gcode", ...
                       "sine_35hz_filtered_bspline.gcode"});
end


function candidates = discoverCandidates(dataDirectory, pattern)
%DISCOVERCANDIDATES Return matching captures in descending run-number order.

listing = dir(fullfile(dataDirectory, pattern));
candidates = repmat(struct("path", "", "name", "", "run_number", NaN), ...
    numel(listing), 1);
candidateCount = 0;
for fileIndex = 1:numel(listing)
    name = string(listing(fileIndex).name);
    token = regexp(name, '_r(\d+)\.json\.gz$', "tokens", "once");
    if isempty(token)
        continue;
    end
    runNumber = str2double(token{1});
    candidateCount = candidateCount + 1;
    candidates(candidateCount) = struct( ...
        "path", string(fullfile(listing(fileIndex).folder, name)), ...
        "name", name, ...
        "run_number", runNumber);
end
candidates = candidates(1:candidateCount);
if isempty(candidates)
    return;
end
[~, order] = sort([candidates.run_number], "descend");
candidates = candidates(order);
end


function analysis = analyzeCapture(capture, specification, configuration)
%ANALYZECAPTURE Validate one capture and extract its six sine passes.

samples = sortrows(capture.toolhead, "time");
requiredVariables = ["time", "device_time_us", "sample_sequence", ...
    "x_acceleration", "flags", "command_x_acceleration", ...
    "reference_valid"];
missingVariables = setdiff(requiredVariables, string(samples.Properties.VariableNames));
if ~isempty(missingVariables)
    error("Capture is missing column(s): %s", strjoin(missingVariables, ", "));
end

time = double(samples.time);
deviceTimeUs = double(samples.device_time_us);
sequence = double(samples.sample_sequence);
command = double(samples.command_x_acceleration);
measured = configuration.toolhead_x_sign * double(samples.x_acceleration);
referenceValid = double(samples.reference_valid) ~= 0;
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
invalidToolheadFlags = nnz(~toolheadValid);

expectedDurationS = configuration.cycles_per_pass ...
    / specification.nominal_frequency_hz;
activity = abs(command) > configuration.command_activity_threshold_mm_s2 ...
    & referenceValid & toolheadValid;
xAccelerationEventTimes = time(activity);
groups = findActivityGroups( ...
    xAccelerationEventTimes, configuration.activity_group_gap_s);

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
if invalidReferences > 0
    failureReasons(end + 1) = sprintf( ...
        "%d command references are invalid", invalidReferences);
end
if invalidToolheadFlags > 0
    failureReasons(end + 1) = sprintf( ...
        "%d toolhead samples have invalid flags", invalidToolheadFlags);
end

passRows = struct([]);
seriesCell = cell(passCount, 1);
for passIndex = 1:passCount
    group = candidateGroups(passIndex);
    [passRow, seriesCell{passIndex}] = analyzePass( ...
        time, deviceTimeUs, sequence, command, measured, ...
        referenceValid, toolheadValid, group, passIndex, ...
        specification, configuration, samplePeriodS);
    passRows = appendStruct(passRows, passRow);
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
    weakCommandPasses = nnz( ...
        passTable.command_fundamental_fraction ...
        < configuration.minimum_command_fundamental_fraction);
    if weakCommandPasses > 0
        failureReasons(end + 1) = sprintf( ...
            "%d pass(es) have a weak command fundamental", ...
            weakCommandPasses);
    end
end

completedPrint = any( ...
    capture.events.filename == specification.gcode_filename ...
    & capture.events.state == "complete");
if ~completedPrint
    failureReasons(end + 1) = "matching print did not reach complete state";
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
analysis.invalid_toolhead_flags = invalidToolheadFlags;
analysis.stream_diagnostic_errors = diagnosticErrorCount;
analysis.firmware_loss_count = firmwareLossCount;
analysis.completed_print = completedPrint;
analysis.pass_count = passCount;
analysis.pass_gap_count = passGapCount;
analysis.pass_metrics = passTable;
analysis.series = series;
end


function groups = findActivityGroups(xAccelerationEventTimes, maximumGapS)
%FINDACTIVITYGROUPS Group command-acceleration events into longitudinal passes.

groups = struct("start_time", {}, "end_time", {}, "event_count", {});
if isempty(xAccelerationEventTimes)
    return;
end
starts = [1; find(diff(xAccelerationEventTimes) > maximumGapS) + 1];
ends = [starts(2:end) - 1; numel(xAccelerationEventTimes)];
for groupIndex = 1:numel(starts)
    indices = starts(groupIndex):ends(groupIndex);
    groups(groupIndex) = struct( ... %#ok<AGROW>
        "start_time", xAccelerationEventTimes(indices(1)), ...
        "end_time", xAccelerationEventTimes(indices(end)), ...
        "event_count", numel(indices));
end
end


function [row, series] = analyzePass( ...
        time, deviceTimeUs, sequence, command, measured, ...
        referenceValid, toolheadValid, group, passIndex, ...
        specification, configuration, samplePeriodS)
%ANALYZEPASS Compute tracking metrics for one central steady sine interval.

nominalFrequencyHz = specification.nominal_frequency_hz;
expectedDurationS = configuration.cycles_per_pass / nominalFrequencyHz;
groupRows = time >= group.start_time & time <= group.end_time;
frequencyHz = estimateCommandFrequency( ...
    time(groupRows), command(groupRows), nominalFrequencyHz, configuration);

groupCentre = 0.5 * (group.start_time + group.end_time);
evaluationDurationS = configuration.central_fraction * expectedDurationS;
evaluationStart = groupCentre - 0.5 * evaluationDurationS;
evaluationEnd = groupCentre + 0.5 * evaluationDurationS;
rows = time >= evaluationStart & time <= evaluationEnd;

sampleTime = time(rows);
sampleCommand = command(rows);
sampleMeasured = measured(rows);
sampleSequence = sequence(rows);
sampleDeviceTimeUs = deviceTimeUs(rows);
omega = 2.0 * pi * frequencyHz;

[commandAmplitude, commandPhaseRad] = harmonicFit( ...
    sampleTime, sampleCommand, frequencyHz);
desiredAmplitude = configuration.position_amplitude_mm * omega^2;
reference = desiredAmplitude * cos( ...
    omega * sampleTime + commandPhaseRad);
dynamicMeasured = sampleMeasured - mean(sampleMeasured);
accelerationError = reference - dynamicMeasured;
accelerationRmsError = sqrt(mean(accelerationError.^2));
referenceRms = sqrt(mean(reference.^2));

% A missing sample normally triggers both tests above; count the affected
% boundaries once rather than twice.
sampleGapCount = max(nnz(diff(sampleSequence) ~= 1), ...
    nnz(diff(sampleDeviceTimeUs) ...
    > configuration.maximum_sample_gap_periods * samplePeriodS * 1e6));

row = struct();
row.condition = string(specification.key);
row.label = string(specification.label);
row.nominal_frequency_hz = nominalFrequencyHz;
row.compensated = specification.compensated;
row.pass_index = passIndex;
row.group_start_print_time_s = group.start_time;
row.group_end_print_time_s = group.end_time;
row.group_duration_s = group.end_time - group.start_time;
row.group_command_event_count = group.event_count;
row.evaluation_start_print_time_s = sampleTime(1);
row.evaluation_end_print_time_s = sampleTime(end);
row.evaluation_sample_count = numel(sampleTime);
row.actual_frequency_hz = frequencyHz;
row.frequency_reduction_percent = ...
    100.0 * (1.0 - frequencyHz / nominalFrequencyHz);
row.desired_acceleration_amplitude_mm_s2 = desiredAmplitude;
row.command_fundamental_amplitude_mm_s2 = commandAmplitude;
row.command_fundamental_fraction = commandAmplitude / desiredAmplitude;
row.acceleration_rms_error_mm_s2 = accelerationRmsError;
row.acceleration_nrmse = accelerationRmsError / referenceRms;
row.sample_gap_count = sampleGapCount;
row.invalid_reference_count = nnz(~referenceValid(rows));
row.invalid_toolhead_flag_count = nnz(~toolheadValid(rows));

series = struct();
series.time_s = sampleTime - sampleTime(1);
series.acceleration_error_mm_s2 = accelerationError;
end


function frequencyHz = estimateCommandFrequency( ...
        time, command, nominalFrequencyHz, configuration)
%ESTIMATECOMMANDFREQUENCY Find the strongest command fundamental near nominal.

lowerFrequency = configuration.frequency_search_lower_fraction ...
    * nominalFrequencyHz;
upperFrequency = configuration.frequency_search_upper_fraction ...
    * nominalFrequencyHz;
frequencyGrid = linspace(lowerFrequency, upperFrequency, ...
    configuration.frequency_search_points);
amplitude = zeros(size(frequencyGrid));
for frequencyIndex = 1:numel(frequencyGrid)
    amplitude(frequencyIndex) = harmonicAmplitude( ...
        time, command, frequencyGrid(frequencyIndex));
end
[~, peakIndex] = max(amplitude);

if peakIndex == 1 || peakIndex == numel(frequencyGrid)
    frequencyHz = frequencyGrid(peakIndex);
    return;
end
left = frequencyGrid(peakIndex - 1);
right = frequencyGrid(peakIndex + 1);
objective = @(frequency) -harmonicAmplitude(time, command, frequency);
frequencyHz = fminbnd(objective, left, right, ...
    optimset("Display", "off", "TolX", 1e-6));
end


function amplitude = harmonicAmplitude(time, signal, frequencyHz)
%HARMONICAMPLITUDE Return only the fitted sinusoidal amplitude.

[amplitude, ~] = harmonicFit(time, signal, frequencyHz);
end


function [amplitude, phaseRad] = harmonicFit(time, signal, frequencyHz)
%HARMONICFIT Return amplitude and cosine-form phase of one sinusoid.

omega = 2.0 * pi * frequencyHz;
design = [sin(omega * time), cos(omega * time), ones(size(time))];
coefficient = design \ signal;
amplitude = hypot(coefficient(1), coefficient(2));
phaseRad = atan2(-coefficient(1), coefficient(2));
end


function count = streamDiagnosticErrorCount(diagnostics)
%STREAMDIAGNOSTICERRORCOUNT Sum cumulative host-side error counters.

fields = ["host_queue_drops", "frame_errors", ...
    "packet_sequence_errors", "sync_timeouts", "read_errors"];
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


function analysis = failedAnalysis(path, message)
%FAILEDANALYSIS Represent a capture that could not be parsed or analyzed.

analysis = struct();
analysis.path = string(path);
analysis.usable = false;
analysis.clean = false;
analysis.failure_reason = string(message);
analysis.n_samples = 0;
analysis.capture_duration_s = NaN;
analysis.sample_rate_hz = NaN;
analysis.sequence_breaks = NaN;
analysis.large_sample_gaps = NaN;
analysis.maximum_gap_ms = NaN;
analysis.invalid_references = NaN;
analysis.invalid_toolhead_flags = NaN;
analysis.stream_diagnostic_errors = NaN;
analysis.firmware_loss_count = NaN;
analysis.completed_print = false;
analysis.pass_count = 0;
analysis.pass_gap_count = NaN;
analysis.pass_metrics = table();
analysis.series = struct([]);
end


function row = captureReviewRow( ...
        specification, candidate, analysis, isLatest)
%CAPTUREREVIEWROW Flatten capture validation into one CSV-friendly record.

row = struct();
row.condition = string(specification.key);
row.label = string(specification.label);
row.capture = string(candidate.name);
row.run_number = candidate.run_number;
row.is_latest = isLatest;
row.selected = false;
row.usable = analysis.usable;
row.clean = analysis.clean;
row.completed_print = analysis.completed_print;
row.pass_count = analysis.pass_count;
row.sample_count = analysis.n_samples;
row.capture_duration_s = analysis.capture_duration_s;
row.sample_rate_hz = analysis.sample_rate_hz;
row.sequence_breaks = analysis.sequence_breaks;
row.large_sample_gaps = analysis.large_sample_gaps;
row.maximum_gap_ms = analysis.maximum_gap_ms;
row.invalid_references = analysis.invalid_references;
row.invalid_toolhead_flags = analysis.invalid_toolhead_flags;
row.stream_diagnostic_errors = analysis.stream_diagnostic_errors;
row.firmware_loss_count = analysis.firmware_loss_count;
row.evaluated_pass_gaps = analysis.pass_gap_count;
row.reason = captureReason(analysis);
end


function reason = captureReason(analysis)
%CAPTUREREASON Explain either rejection or a non-clean usable capture.

reasons = strings(0, 1);
if strlength(string(analysis.failure_reason)) > 0
    reasons(end + 1) = string(analysis.failure_reason);
end
if analysis.usable && ~analysis.clean
    if analysis.sequence_breaks > 0
        reasons(end + 1) = sprintf( ...
            "%d sample-sequence break(s)", ...
            analysis.sequence_breaks);
    end
    if analysis.large_sample_gaps > 0
        reasons(end + 1) = sprintf( ...
            "%d large sample gap(s)", analysis.large_sample_gaps);
    end
    if analysis.pass_gap_count > 0
        reasons(end + 1) = sprintf( ...
            "%d gap(s) inside evaluated pass intervals", ...
            analysis.pass_gap_count);
    end
    if analysis.stream_diagnostic_errors > 0
        reasons(end + 1) = sprintf( ...
            "%d host stream diagnostic error(s)", ...
            analysis.stream_diagnostic_errors);
    end
    if analysis.firmware_loss_count > 0
        reasons(end + 1) = sprintf( ...
            "%d firmware loss/overrun event(s)", ...
            analysis.firmware_loss_count);
    end
end
reason = strjoin(reasons, "; ");
end


function output = concatenatePassTables(selected)
%CONCATENATEPASSTABLES Add capture metadata and join all selected passes.

tables = cell(numel(selected), 1);
for conditionIndex = 1:numel(selected)
    current = selected(conditionIndex).pass_metrics;
    current.capture = repmat( ...
        string(selected(conditionIndex).path), height(current), 1);
    current.capture_run_number = repmat( ...
        selected(conditionIndex).run_number, height(current), 1);
    current.capture_clean = repmat( ...
        selected(conditionIndex).clean, height(current), 1);
    tables{conditionIndex} = current;
end
output = vertcat(tables{:});
end


function summary = summarizeConditions(selected, passTable)
%SUMMARIZECONDITIONS Aggregate six pass-level results per condition.

rows = struct([]);
for conditionIndex = 1:numel(selected)
    specification = selected(conditionIndex).condition;
    conditionRows = passTable.condition == specification.key;
    passes = passTable(conditionRows, :);

    row = struct();
    row.condition = string(specification.key);
    row.label = string(specification.label);
    row.nominal_frequency_hz = specification.nominal_frequency_hz;
    row.compensated = specification.compensated;
    [~, captureName, captureExtension] = fileparts(selected(conditionIndex).path);
    if captureExtension == ".gz"
        [~, captureStem, captureJsonExtension] = fileparts(captureName);
        captureName = captureStem + captureJsonExtension + captureExtension;
    else
        captureName = captureName + captureExtension;
    end
    row.selected_capture = string(captureName);
    row.selected_run_number = selected(conditionIndex).run_number;
    row.selected_latest_capture = selected(conditionIndex).is_latest;
    row.capture_clean = selected(conditionIndex).clean;
    row.sample_rate_hz = selected(conditionIndex).sample_rate_hz;
    row.pass_count = height(passes);
    row.actual_frequency_mean_hz = mean(passes.actual_frequency_hz);
    row.actual_frequency_std_hz = std(passes.actual_frequency_hz);
    row.frequency_reduction_mean_percent = ...
        mean(passes.frequency_reduction_percent);
    row.acceleration_rms_error_mean_mm_s2 = ...
        mean(passes.acceleration_rms_error_mm_s2);
    row.acceleration_rms_error_std_mm_s2 = ...
        std(passes.acceleration_rms_error_mm_s2);
    row.acceleration_nrmse_mean = mean(passes.acceleration_nrmse);
    row.acceleration_nrmse_std = std(passes.acceleration_nrmse);
    rows = appendStruct(rows, row);
end
summary = struct2table(rows);
end


function plotAccelerationErrorHistory(selected, outputDirectory)
%PLOTACCELERATIONERRORHISTORY Plot all six central pass errors like Figure 7.

figureHandle = figure( ...
    "Name", "Sine acceleration tracking-error histories", "Color", "w");
layout = tiledlayout(2, 1, "TileSpacing", "compact", "Padding", "compact");
frequencies = [10, 35];
for frequencyIndex = 1:numel(frequencies)
    frequency = frequencies(frequencyIndex);
    [uncompensated, compensated] = selectFrequencyPair(selected, frequency);
    [uncompensatedTime, uncompensatedError] = concatenateSeries( ...
        uncompensated.series, "acceleration_error_mm_s2");
    [compensatedTime, compensatedError] = concatenateSeries( ...
        compensated.series, "acceleration_error_mm_s2");

    axesHandle = nexttile(layout, frequencyIndex);
    hold(axesHandle, "on");
    yline(axesHandle, 0.0, "k-", "LineWidth", 0.8, ...
        "DisplayName", "Desired (zero error)");
    plot(axesHandle, uncompensatedTime, uncompensatedError / 1000.0, ...
        "Color", [0.85, 0.15, 0.15], "LineWidth", 0.65, ...
        "DisplayName", "No compensation");
    plot(axesHandle, compensatedTime, compensatedError / 1000.0, ...
        "Color", [0.05, 0.30, 0.85], "LineWidth", 0.65, ...
        "DisplayName", "Standard FBF");
    configurePlotAxes(axesHandle);
    status = "";
    if ~uncompensated.clean || ~compensated.clean
        status = " (provisional capture)";
    end
    title(axesHandle, sprintf("%g Hz sine passes%s", frequency, status));
    ylabel(axesHandle, "X acceleration error [m/s^2]");
    if frequencyIndex == 1
        legend(axesHandle, "Location", "best");
    end
end
xlabel(nexttile(layout, 2), "Concatenated central sine-motion time [s]");
title(layout, "Measured acceleration tracking-error histories");
fontsize(figureHandle, 12, "points");
exportFigure(figureHandle, outputDirectory, ...
    "sine_tracking_acceleration_error_history");
end


function plotAccelerationNrmse(passTable, outputDirectory)
%PLOTACCELERATIONNRMSE Show every pass plus mean and standard deviation.

figureHandle = figure( ...
    "Name", "Sine acceleration NRMSE comparison", "Color", "w");
layout = tiledlayout(1, 2, "TileSpacing", "compact", "Padding", "compact");
frequencies = [10, 35];
colors = [0.85, 0.15, 0.15; 0.05, 0.30, 0.85];
for frequencyIndex = 1:numel(frequencies)
    frequency = frequencies(frequencyIndex);
    axesHandle = nexttile(layout, frequencyIndex);
    hold(axesHandle, "on");
    conditionMeans = zeros(2, 1);

    for conditionIndex = 1:2
        compensated = conditionIndex == 2;
        rows = passTable.nominal_frequency_hz == frequency ...
            & passTable.compensated == compensated;
        values = passTable.acceleration_nrmse(rows);
        conditionMeans(conditionIndex) = mean(values);
        x = conditionIndex + linspace(-0.08, 0.08, numel(values)).';

        scatter(axesHandle, x, values, 34, colors(conditionIndex, :), ...
            "filled", "MarkerFaceAlpha", 0.65, ...
            "HandleVisibility", "off");
        errorbar(axesHandle, conditionIndex, mean(values), std(values), ...
            "Color", "k", "LineStyle", "none", "LineWidth", 1.3, ...
            "CapSize", 10, "HandleVisibility", "off");
        plot(axesHandle, conditionIndex, mean(values), "kd", ...
            "MarkerFaceColor", colors(conditionIndex, :), ...
            "MarkerSize", 8, "HandleVisibility", "off");
    end

    reductionPercent = 100.0 * (1.0 ...
        - conditionMeans(2) / conditionMeans(1));
    frequencyRows = passTable.nominal_frequency_hz == frequency;
    frequencyValues = passTable.acceleration_nrmse(frequencyRows);
    status = "";
    if any(~passTable.capture_clean(frequencyRows))
        status = " (provisional)";
    end
    configurePlotAxes(axesHandle);
    xlim(axesHandle, [0.55, 2.45]);
    ylim(axesHandle, [0.0, 1.1 * max(frequencyValues)]);
    xticks(axesHandle, [1, 2]);
    xticklabels(axesHandle, ["No compensation", "Standard FBF"]);
    ylabel(axesHandle, "Acceleration NRMSE [-]");
    title(axesHandle, sprintf( ...
        "%g Hz: %.1f%% reduction%s", ...
        frequency, reductionPercent, status));
end
title(layout, "Acceleration tracking error across six sine passes");
fontsize(figureHandle, 12, "points");
exportFigure(figureHandle, outputDirectory, ...
    "sine_tracking_acceleration_nrmse");
end


function [uncompensated, compensated] = selectFrequencyPair(selected, frequency)
%SELECTFREQUENCYPAIR Return the two controller conditions at one frequency.

conditionFrequency = arrayfun( ...
    @(entry) entry.condition.nominal_frequency_hz, selected);
conditionCompensated = arrayfun( ...
    @(entry) entry.condition.compensated, selected);
uncompensated = selected( ...
    conditionFrequency == frequency & ~conditionCompensated);
compensated = selected( ...
    conditionFrequency == frequency & conditionCompensated);
end


function [time, signal] = concatenateSeries(series, field)
%CONCATENATESERIES Join pass histories with NaN separators.

time = zeros(0, 1);
signal = zeros(0, 1);
offset = 0.0;
separatorDuration = 0.1;
for passIndex = 1:numel(series)
    passTime = series(passIndex).time_s;
    passSignal = series(passIndex).(field);
    time = [time; offset + passTime; NaN]; %#ok<AGROW>
    signal = [signal; passSignal; NaN]; %#ok<AGROW>
    offset = offset + passTime(end) + separatorDuration;
end
end


function configurePlotAxes(axesHandle)
%CONFIGUREPLOTAXES Apply consistent dissertation plot formatting.

grid(axesHandle, "on");
box(axesHandle, "on");
axesHandle.Layer = "top";
axesHandle.Toolbar.Visible = "off";
end


function exportFigure(figureHandle, outputDirectory, stem)
%EXPORTFIGURE Write both raster preview and vector PDF.

figureHandle.Position(3:4) = [1000, 700];
exportgraphics(figureHandle, fullfile(outputDirectory, stem + ".png"), ...
    "Resolution", 220);
exportgraphics(figureHandle, fullfile(outputDirectory, stem + ".pdf"), ...
    "ContentType", "vector");
close(figureHandle);
end


function printCaptureReview(review)
%PRINTCAPTUREREVIEW Print concise selection and rejection evidence.

fprintf("\nSine capture review\n");
for rowIndex = 1:height(review)
    row = review(rowIndex, :);
    state = "rejected";
    if row.selected
        state = "selected-clean";
        if ~row.clean
            state = "selected-with-warning";
        end
    end
    fprintf("  %-18s %-32s %-23s passes=%d samples=%d", ...
        row.condition, row.capture, state, row.pass_count, row.sample_count);
    if strlength(row.reason) > 0
        fprintf(" (%s)", row.reason);
    end
    fprintf("\n");
end
end


function printSummary(summary)
%PRINTSUMMARY Print the principal dissertation metrics.

fprintf("\nSine tracking summary (six central pass intervals)\n");
for rowIndex = 1:height(summary)
    row = summary(rowIndex, :);
    status = "";
    if ~row.capture_clean
        status = " [PROVISIONAL: capture warning]";
    end
    fprintf(['  %-18s executed=%6.3f Hz acceleration RMS=%8.3f m/s^2 ' ...
        'NRMSE=%6.3f%s\n'], ...
        row.condition, row.actual_frequency_mean_hz, ...
        row.acceleration_rms_error_mean_mm_s2 / 1000.0, ...
        row.acceleration_nrmse_mean, status);
end
end


function printPairedImprovements(summary)
%PRINTPAIREDIMPROVEMENTS Compare standard FBF to no compensation.

fprintf("\nStandard-FBF reduction relative to no compensation\n");
for frequency = [10, 35]
    uncompensated = summary( ...
        summary.nominal_frequency_hz == frequency & ~summary.compensated, :);
    compensated = summary( ...
        summary.nominal_frequency_hz == frequency & summary.compensated, :);
    accelerationReduction = 100.0 * (1.0 ...
        - compensated.acceleration_nrmse_mean ...
        / uncompensated.acceleration_nrmse_mean);
    status = "";
    if ~uncompensated.capture_clean || ~compensated.capture_clean
        status = " [PROVISIONAL: capture warning]";
    end
    fprintf("  %2g Hz: acceleration NRMSE reduction %.1f%%%s\n", ...
        frequency, accelerationReduction, status);
end
end


function output = appendStruct(input, row)
%APPENDSTRUCT Append a scalar struct while supporting an empty input.

if isempty(input)
    output = row;
else
    output = input;
    output(end + 1) = row;
end
end
