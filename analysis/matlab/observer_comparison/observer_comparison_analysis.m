function report = observer_comparison_analysis( ...
        capturePath, observerConfigPath, outputDirectory)
%OBSERVER_COMPARISON_ANALYSIS Compare old and Kalman observers on one run.
%
% The archived Luenberger position and the offline Kalman replay use the same
% final motor command and the same bias-corrected acceleration samples. This
% isolates observer design from mechanical run-to-run variation.

scriptDirectory = string(fileparts(mfilename("fullpath")));
repositoryRoot = string(fileparts(fileparts(fileparts(scriptDirectory))));
if nargin < 1 || strlength(string(capturePath)) == 0
    capturePath = fullfile(repositoryRoot, "data", "raw", ...
        "motan_fresh", "sine35_comp_test5.json.gz");
end
if nargin < 2 || strlength(string(observerConfigPath)) == 0
    observerConfigPath = fullfile( ...
        repositoryRoot, "klipper_extensions", "trinkey_accel.cfg");
end
if nargin < 3 || strlength(string(outputDirectory)) == 0
    outputDirectory = fullfile( ...
        repositoryRoot, "data", "processed", "observer_comparison");
end
capturePath = string(capturePath);
observerConfigPath = string(observerConfigPath);
outputDirectory = string(outputDirectory);
if ~isfolder(outputDirectory)
    mkdir(outputDirectory);
end

addpath(fullfile(repositoryRoot, "analysis", "matlab", "sine_tracking"));
capture = motan_lightweight_load(capturePath);
samples = sortrows(capture.toolhead, "time");
requireVariables(samples, [ ...
    "time", "sample_sequence", "desired_x_position", ...
    "desired_x_acceleration", "motor_x_position", "motor_x_velocity", ...
    "observed_x_position", "observer_x_acceleration", ...
    "observer_valid", "reference_valid"]);

kalmanObserver = readObserverConfiguration(observerConfigPath, "x");
kalmanPosition = replayObserver(samples, kalmanObserver);
[windowRows, passIndex, windowStart, windowEnd] = selectSineWindow(samples);

time = samples.time(windowRows) - samples.time(find(windowRows, 1));
desiredPosition = samples.desired_x_position(windowRows);
luenbergerPosition = samples.observed_x_position(windowRows);
kalmanPosition = kalmanPosition(windowRows);
positionCentre = mean(desiredPosition);

desiredUm = 1000.0 * (desiredPosition - positionCentre);
luenbergerUm = 1000.0 * (luenbergerPosition - positionCentre);
kalmanUm = 1000.0 * (kalmanPosition - positionCentre);

figureHandle = figure( ...
    "Name", "Luenberger and Kalman observer comparison", ...
    "Color", "w", "Units", "inches", ...
    "Position", [1.0, 1.0, 12.0, 6.75]);
axesHandle = axes(figureHandle);
hold(axesHandle, "on");
plot(axesHandle, time, desiredUm, "k--", "LineWidth", 2.0, ...
    "DisplayName", "Desired");
plot(axesHandle, time, luenbergerUm, ...
    "Color", [0.80, 0.15, 0.15], "LineWidth", 1.4, ...
    "DisplayName", "5 Hz Luenberger");
plot(axesHandle, time, kalmanUm, ...
    "Color", [0.10, 0.35, 0.85], "LineWidth", 1.8, ...
    "DisplayName", "Steady-state Kalman");
grid(axesHandle, "on");
box(axesHandle, "on");
axesHandle.Layer = "top";
axesHandle.Toolbar.Visible = "off";
xlabel(axesHandle, "Time [s]");
ylabel(axesHandle, "X position relative to centre [\mum]");
title(axesHandle, "Identical recorded inputs: nominal 35 Hz");
legendHandle = legend(axesHandle, "Location", "northoutside", ...
    "Orientation", "horizontal", "NumColumns", 3);
axesHandle.FontSize = 19;
axesHandle.LabelFontSizeMultiplier = 1.10;
axesHandle.TitleFontSizeMultiplier = 1.15;
legendHandle.FontSize = 18;
% Leave generous margins so the larger slide text is not clipped on export.
axesHandle.Position = [0.15, 0.15, 0.81, 0.67];
drawnow;
exportgraphics(figureHandle, fullfile( ...
    outputDirectory, "luenberger_kalman_position_comparison.png"), ...
    "Resolution", 220);
figureHandle.PaperUnits = "inches";
figureHandle.PaperSize = [12.0, 6.75];
figureHandle.PaperPosition = [0.0, 0.0, 12.0, 6.75];
print(figureHandle, char(fullfile(outputDirectory, ...
    "luenberger_kalman_position_comparison.pdf")), ...
    "-dpdf", "-painters");
close(figureHandle);

comparisonTable = table( ...
    time, desiredUm, luenbergerUm, kalmanUm, ...
    VariableNames=["time_s", "desired_position_um", ...
    "luenberger_position_um", "kalman_position_um"]);
writetable(comparisonTable, fullfile( ...
    outputDirectory, "luenberger_kalman_position_comparison.csv"));

fprintf("\nObserver comparison\n");
fprintf("  source: %s\n", capturePath);
fprintf("  pass: %d, print time %.6f..%.6f s\n", ...
    passIndex, windowStart, windowEnd);
fprintf("  samples: %d\n", height(comparisonTable));

report = struct();
report.capture_path = capturePath;
report.observer_config_path = observerConfigPath;
report.pass_index = passIndex;
report.window_start_print_time_s = windowStart;
report.window_end_print_time_s = windowEnd;
report.comparison = comparisonTable;
report.output_directory = outputDirectory;
end


function requireVariables(samples, required)
%REQUIREVARIABLES Reject captures that cannot support a fair replay.

missing = setdiff(required, string(samples.Properties.VariableNames));
if ~isempty(missing)
    error("Capture is missing column(s): %s", strjoin(missing, ", "));
end
end


function observer = readObserverConfiguration(path, axisName)
%READOBSERVERCONFIGURATION Load the deployed fixed matrices from Klipper cfg.

if ~isfile(path)
    error("Observer configuration does not exist: %s", path);
end
text = fileread(path);
prefix = "observer_" + axisName + "_";
stateCount = readConfigValues(text, prefix + "state_count", 1);
observer.state_count = stateCount;
observer.fo = reshape(readConfigValues( ...
    text, prefix + "fo", stateCount^2), stateCount, stateCount).';
observer.gu = readConfigValues(text, prefix + "gu", stateCount);
observer.gv = readConfigValues(text, prefix + "gv", stateCount);
observer.ga = readConfigValues(text, prefix + "ga", stateCount);
observer.ho = readConfigValues(text, prefix + "ho", stateCount).';
observer.hu = readConfigValues(text, prefix + "hu", 1);
observer.hv = readConfigValues(text, prefix + "hv", 1);
observer.ha = readConfigValues(text, prefix + "ha", 1);
observer.x0 = readConfigValues(text, prefix + "x0_per_mm", stateCount);
end


function values = readConfigValues(text, key, expectedCount)
%READCONFIGVALUES Parse one scalar or indented numeric list from the cfg.

escapedKey = regexptranslate("escape", key);
[starts, ends] = regexp(text, "(?m)^" + escapedKey + ":\s*", ...
    "start", "end");
if numel(starts) ~= 1
    error("Expected one configuration field named %s.", key);
end
remainder = extractAfter(string(text), ends);
nextField = regexp(remainder, "(?m)^[A-Za-z_][A-Za-z0-9_]*:\s*", ...
    "start", "once");
if isempty(nextField)
    block = remainder;
else
    block = extractBefore(remainder, nextField);
end
numberPattern = "[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?";
tokens = regexp(block, numberPattern, "match");
values = str2double(tokens(:));
if numel(values) ~= expectedCount || any(~isfinite(values))
    error("Configuration field %s contains %d/%d finite values.", ...
        key, numel(values), expectedCount);
end
end


function position = replayObserver(samples, observer)
%REPLAYOBSERVER Apply the current C recurrence to archived physical samples.

sampleCount = height(samples);
position = NaN(sampleCount, 1);
state = zeros(observer.state_count, 1);
initialized = false;
lastSequence = NaN;
lastTime = NaN;
for sampleIndex = 1:sampleCount
    valid = samples.observer_valid(sampleIndex) ~= 0 ...
        && samples.reference_valid(sampleIndex) ~= 0;
    sequence = samples.sample_sequence(sampleIndex);
    sampleTime = samples.time(sampleIndex);
    continuous = initialized ...
        && sequence == lastSequence + 1 ...
        && sampleTime > lastTime;
    if ~valid
        initialized = false;
        lastSequence = sequence;
        lastTime = sampleTime;
        continue;
    end

    inputPosition = samples.motor_x_position(sampleIndex);
    inputVelocity = samples.motor_x_velocity(sampleIndex);
    acceleration = samples.observer_x_acceleration(sampleIndex);
    if ~continuous
        state = observer.x0 * inputPosition;
        initialized = true;
    end

    position(sampleIndex) = observer.ho * state ...
        + observer.hu * inputPosition ...
        + observer.hv * inputVelocity ...
        + observer.ha * acceleration;
    state = observer.fo * state ...
        + observer.gu * inputPosition ...
        + observer.gv * inputVelocity ...
        + observer.ga * acceleration;
    lastSequence = sequence;
    lastTime = sampleTime;
end
end


function [windowRows, selectedPass, windowStart, windowEnd] = ...
        selectSineWindow(samples)
%SELECTSINEWINDOW Select 0.5 s from the middle of the third steady pass.

activity = abs(samples.desired_x_acceleration) > 1.0 ...
    & samples.observer_valid ~= 0 & samples.reference_valid ~= 0;
activityTimes = samples.time(activity);
starts = [1; find(diff(activityTimes) > 1.0) + 1];
ends = [starts(2:end) - 1; numel(activityTimes)];
startTimes = activityTimes(starts);
endTimes = activityTimes(ends);
durations = endTimes - startTimes;
steady = durations >= 2.0 & durations <= 4.0;
startTimes = startTimes(steady);
endTimes = endTimes(steady);
if numel(startTimes) < 6
    error("Capture contains only %d steady sine passes.", numel(startTimes));
end
startTimes = startTimes(end - 5:end);
endTimes = endTimes(end - 5:end);
selectedPass = 3;
centre = 0.5 * (startTimes(selectedPass) + endTimes(selectedPass));
windowStart = centre - 0.25;
windowEnd = centre + 0.25;
windowRows = samples.time >= windowStart & samples.time <= windowEnd ...
    & samples.observer_valid ~= 0 & samples.reference_valid ~= 0;
if nnz(windowRows) < 100
    error("Selected comparison window contains only %d valid rows.", ...
        nnz(windowRows));
end
end
