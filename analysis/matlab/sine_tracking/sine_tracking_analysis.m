function report = sine_tracking_analysis(dataDirectory, outputDirectory)
%SINE_TRACKING_ANALYSIS Compare position tracking for all three controllers.
%
% Run from the repository root:
%
%   addpath("analysis/matlab/sine_tracking");
%   report = sine_tracking_analysis();
%
% The function discovers the newest run for every combination of nominal
% 10/35 Hz and uncompensated/standard-FBF/hybrid-FBF control. If the newest
% capture does not contain all six evaluated sine passes, it records the
% rejection and falls back to the newest analyzable capture.
%
% As in the core paper, tracking error is desired TrapQ position minus the
% shared observer's estimated physical position. RMS error is reported in
% micrometres. The estimate is model assisted and is not encoder ground truth.

scriptDirectory = string(fileparts(mfilename("fullpath")));
repositoryRoot = string(fileparts(fileparts(fileparts(scriptDirectory))));
if nargin < 1 || strlength(string(dataDirectory)) == 0
    dataDirectory = fullfile( ...
        repositoryRoot, "data", "raw", "final_evaluation");
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
            analysis = sine_tracking_analyze_capture( ...
                capture, specification, configuration);
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

sine_tracking_plot_position_error(selected, summaryTable, outputDirectory);

printCaptureReview(reviewTable);
printSummary(summaryTable);
printPairedImprovements(summaryTable);

report = struct();
report.configuration = configuration;
report.capture_review = reviewTable;
report.pass_metrics = passTable;
report.summary = summaryTable;
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
configuration.maximum_sample_gap_periods = 1.6;
configuration.minimum_position_fundamental_fraction = 0.50;
end


function specifications = conditionSpecifications()
%CONDITIONSPECIFICATIONS Describe the six experimental conditions.

specifications = struct( ...
    "key", {"sine10_uncomp", "sine10_standard", "sine10_hybrid", ...
            "sine35_uncomp", "sine35_standard", "sine35_hybrid"}, ...
    "label", {"10 Hz, no compensation", "10 Hz, standard FBF", ...
              "10 Hz, hybrid FBF", "35 Hz, no compensation", ...
              "35 Hz, standard FBF", "35 Hz, hybrid FBF"}, ...
    "short_label", {"No compensation", "Standard FBF", "Hybrid FBF", ...
                    "No compensation", "Standard FBF", "Hybrid FBF"}, ...
    "nominal_frequency_hz", {10, 10, 10, 35, 35, 35}, ...
    "controller_mode", {"uncompensated", "standard", "hybrid", ...
                        "uncompensated", "standard", "hybrid"}, ...
    "pattern", {"sine10_uncomp_r*.json.gz", ...
                "sine10_standard_r*.json.gz", ...
                "sine10_hybrid_r*.json.gz", ...
                "sine35_uncomp_r*.json.gz", ...
                "sine35_standard_r*.json.gz", ...
                "sine35_hybrid_r*.json.gz"}, ...
    "gcode_filename", {"sine_10hz_uncompensated.gcode", ...
                       "sine_10hz_filtered_bspline.gcode", ...
                       "sine_10hz_hybrid.gcode", ...
                       "sine_35hz_uncompensated.gcode", ...
                       "sine_35hz_filtered_bspline.gcode", ...
                       "sine_35hz_hybrid.gcode"});
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
analysis.invalid_observers = NaN;
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
row.invalid_observers = analysis.invalid_observers;
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
            "%d sample-sequence break(s)", analysis.sequence_breaks);
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
    row.controller_mode = string(specification.controller_mode);
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
    allErrorsUm = vertcat(selected(conditionIndex).series.position_error_um);
    row.overall_position_rms_error_um = sqrt(mean(allErrorsUm.^2));
    rows = appendStruct(rows, row);
end
summary = struct2table(rows);
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
        status = " [WHOLE-CAPTURE WARNING; evaluated intervals accepted]";
    end
    fprintf(['  %-18s executed=%6.3f Hz overall position RMS=' ...
        '%8.1f um%s\n'], ...
        row.condition, row.actual_frequency_mean_hz, ...
        row.overall_position_rms_error_um, status);
end
end


function printPairedImprovements(summary)
%PRINTPAIREDIMPROVEMENTS Compare the three controller modes.

fprintf("\nPosition RMS reductions\n");
for frequency = [10, 35]
    uncompensated = summary( ...
        summary.nominal_frequency_hz == frequency ...
        & summary.controller_mode == "uncompensated", :);
    standard = summary( ...
        summary.nominal_frequency_hz == frequency ...
        & summary.controller_mode == "standard", :);
    hybrid = summary( ...
        summary.nominal_frequency_hz == frequency ...
        & summary.controller_mode == "hybrid", :);
    standardReduction = percentageReduction( ...
        uncompensated.overall_position_rms_error_um, ...
        standard.overall_position_rms_error_um);
    hybridReduction = percentageReduction( ...
        uncompensated.overall_position_rms_error_um, ...
        hybrid.overall_position_rms_error_um);
    hybridBeyondStandard = percentageReduction( ...
        standard.overall_position_rms_error_um, ...
        hybrid.overall_position_rms_error_um);
    status = "";
    if ~uncompensated.capture_clean || ~standard.capture_clean ...
            || ~hybrid.capture_clean
        status = " [WHOLE-CAPTURE WARNING; evaluated intervals accepted]";
    end
    fprintf(['  %2g Hz: standard vs none %.1f%%, hybrid vs none %.1f%%, ' ...
        'hybrid vs standard %.1f%%%s\n'], frequency, standardReduction, ...
        hybridReduction, hybridBeyondStandard, status);
end
end


function reduction = percentageReduction(reference, candidate)
%PERCENTAGEREDUCTION Return positive values when RMS becomes smaller.

reduction = 100.0 * (1.0 - candidate / reference);
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
