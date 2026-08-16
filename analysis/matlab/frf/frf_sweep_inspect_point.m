function inspect = frf_sweep_inspect_point(runDir, axisName, frequencyHz)
%FRF_SWEEP_INSPECT_POINT Plot one frequency point using the shared extractor.
%
% Example:
%
%   addpath("analysis/matlab/frf");
%   inspect = frf_sweep_inspect_point("data/raw/2026-07-16_2ms", "X", 30);

if nargin ~= 3
    error("Usage: inspect = frf_sweep_inspect_point(runDir, axisName, frequencyHz)");
end

results = frf_sweep_extract(runDir, true);
axisResult = selectAxis(results, axisName);
point = selectPoint(axisResult, frequencyHz);

figureHandle = figure("Name", sprintf("%s %.3g Hz sweep point", ...
    upper(char(point.axis)), point.frequency_hz));

hold on;
grid on;
box on;
measuredPlot = plot(point.time_s, point.accel_mm_s2, ".", "MarkerSize", 10, ...
    "DisplayName", "measured output samples");
inputPlot = plot(point.input_segment_time_s, point.input_segment_accel_mm_s2, ".", ...
    "MarkerSize", 10, "DisplayName", "logged input segments");
fontsize(figureHandle, 14, "points");
drawTimingRegions(point);
drawTimingLines(point);
xlabel("Time from Klipper motion start [s]");
ylabel("Acceleration [mm/s^2]");
title(sprintf("%s, %.1f m/s^2 - %s %.3g Hz", results.run_id, ...
    results.commanded_accel_amplitude_m_s2, upper(char(point.axis)), ...
    point.frequency_hz), "Interpreter", "none");
legend([measuredPlot, inputPlot], "Location", "best");

inspect = struct();
inspect.run_dir = string(runDir);
inspect.run_id = results.run_id;
inspect.axis = point.axis;
inspect.frequency_hz = point.frequency_hz;
inspect.point = point;
inspect.figure = figureHandle;
end


function axisResult = selectAxis(results, axisName)
%SELECTAXIS Pick the X or Y result block from frf_sweep_extract output.

axisKey = lower(string(axisName));
if axisKey ~= "x" && axisKey ~= "y"
    error("axisName must be ""X"" or ""Y"".");
end
axisResult = results.(axisKey);
end


function point = selectPoint(axisResult, frequencyHz)
%SELECTPOINT Return the frequency point matching the requested axis frequency.

frequencyHz = double(frequencyHz);
index = find(axisResult.frequency_hz == frequencyHz, 1);
if isempty(index)
    error("No %.6g Hz point found for axis %s.", frequencyHz, axisResult.axis);
end

point = axisResult.point(index);
end


function drawTimingRegions(point)
%DRAWTIMINGREGIONS Shade the ramps, guard intervals, and fitted interval.

rampDownStart = point.duration_s - point.ramp_time_s;
boundaries = [point.motion_start_s, point.ramp_time_s, ...
    point.steady_start_s, point.steady_end_s, rampDownStart, ...
    point.duration_s];

if any(diff(boundaries) <= 0)
    error("Timing regions are not strictly ordered for the selected point.");
end

% Match colours by region type while maximising contrast between adjacent
% regions when the figure is reduced for the dissertation.
rampColour = [0.00, 0.45, 0.70];  % blue
guardColour = [1.00, 0.65, 0.00]; % gold
fitColour = [0.55, 0.15, 0.65];   % purple
colours = [rampColour; guardColour; fitColour; guardColour; rampColour];
labels = ["ramp-up", "settling guard", "fitted response", ...
    "end guard", "ramp-down"];

yLimits = ylim;
yRange = diff(yLimits);
labelOffsets = [0.025, 0.085, 0.025, 0.085, 0.025] * yRange;
minimumLabelWidth = 0.075 * point.duration_s;
regionHandles = gobjects(5, 1);

for regionIndex = 1:5
    regionStart = boundaries(regionIndex);
    regionEnd = boundaries(regionIndex + 1);
    regionHandles(regionIndex) = patch( ...
        [regionStart, regionEnd, regionEnd, regionStart], ...
        [yLimits(1), yLimits(1), yLimits(2), yLimits(2)], ...
        colours(regionIndex, :), ...
        "FaceAlpha", 0.17, "EdgeColor", [0.35, 0.35, 0.35], ...
        "EdgeAlpha", 0.55, "LineWidth", 0.6, ...
        "HandleVisibility", "off");

    if regionEnd - regionStart >= minimumLabelWidth
        labelY = yLimits(2) - labelOffsets(regionIndex);
        text((regionStart + regionEnd) / 2.0, labelY, labels(regionIndex), ...
            "HorizontalAlignment", "center", ...
            "VerticalAlignment", "top", ...
            "FontSize", 14, "FontWeight", "bold", ...
            "Color", [0.25, 0.25, 0.25], ...
            "Clipping", "on", "HandleVisibility", "off");
    end
end

uistack(regionHandles, "bottom");
ylim(yLimits);
set(gca, "Layer", "top");
end


function drawTimingLines(point)
%DRAWTIMINGLINES Mark the motion start and the samples used for fitting.

xline(point.motion_start_s, "r-", "motion start", ...
    "LabelVerticalAlignment", "bottom", "FontSize", 14, "LineWidth", 2.0);
xline(point.steady_start_s, "k--", "fit start", ...
    "LabelVerticalAlignment", "bottom", "FontSize", 14, "LineWidth", 2.0);
xline(point.steady_end_s, "k--", "fit end", ...
    "LabelVerticalAlignment", "bottom", "FontSize", 14, "LineWidth", 2.0);
end
