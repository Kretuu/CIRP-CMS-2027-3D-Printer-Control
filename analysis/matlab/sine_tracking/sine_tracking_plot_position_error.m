function sine_tracking_plot_position_error( ...
        selected, summaryTable, outputDirectory)
%SINE_TRACKING_PLOT_POSITION_ERROR Plot all controllers at each frequency.
%
% This follows the presentation of the core paper's Figure 7. RMS is the only
% headline scalar metric and is placed directly in the legend.

frequencies = [10, 35];
colors = [0.80, 0.15, 0.15; 0.10, 0.35, 0.85; 0.10, 0.60, 0.25];
lineWidths = [0.55, 0.8, 1.0];
modes = ["uncompensated", "standard", "hybrid"];
for frequencyIndex = 1:numel(frequencies)
    frequency = frequencies(frequencyIndex);
    conditions = selectFrequencyConditions(selected, frequency);
    figureHandle = figure( ...
        "Name", sprintf("%g Hz position tracking error", frequency), ...
        "Color", "w");
    axesHandle = axes(figureHandle); %#ok<LAXES>
    hold(axesHandle, "on");
    yline(axesHandle, 0.0, "k-", "LineWidth", 0.8, ...
        "HandleVisibility", "off");

    for conditionIndex = 1:numel(conditions)
        current = conditions(conditionIndex);
        modeIndex = find(modes == current.condition.controller_mode, 1);
        summaryRow = summaryTable( ...
            summaryTable.condition == current.condition.key, :);
        [conditionTime, conditionError] = concatenateSeries( ...
            current.series, "position_error_um");
        legendLabel = sprintf("%s (RMS %.1f \\mum)", ...
            current.condition.short_label, ...
            summaryRow.overall_position_rms_error_um);
        plot(axesHandle, conditionTime, conditionError, ...
            "Color", colors(modeIndex, :), ...
            "LineWidth", lineWidths(modeIndex), ...
            "DisplayName", legendLabel);
    end

    configurePlotAxes(axesHandle);
    title(axesHandle, [sprintf( ...
        "Observer-derived X tracking error: nominal %g Hz", frequency); ...
        "Six central sine-pass intervals"]);
    xlabel(axesHandle, "Concatenated sine-motion time [s]");
    ylabel(axesHandle, "X tracking error [\mum]");
    legend(axesHandle, "Location", "northoutside", ...
        "Orientation", "horizontal", "NumColumns", 3);
    fontsize(figureHandle, 14, "points");
    exportFigure(figureHandle, outputDirectory, sprintf( ...
        "sine_tracking_position_error_%ghz", frequency));
end
end


function conditions = selectFrequencyConditions(selected, frequency)
%SELECTFREQUENCYCONDITIONS Return the three modes in plotting order.

conditionFrequency = arrayfun( ...
    @(entry) entry.condition.nominal_frequency_hz, selected);
conditionMode = string(arrayfun( ...
    @(entry) entry.condition.controller_mode, selected, ...
    "UniformOutput", false));
modes = ["uncompensated", "standard", "hybrid"];
conditions = selected([]);
for mode = modes
    match = selected(conditionFrequency == frequency & conditionMode == mode);
    if numel(match) ~= 1
        error("Expected one %g Hz %s condition.", frequency, mode);
    end
    conditions(end + 1) = match; %#ok<AGROW>
end
end


function [time, signal] = concatenateSeries(series, field)
%CONCATENATESERIES Join the six pass histories with visible gaps.

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

figureHandle.Position(3:4) = [1200, 675];
exportgraphics(figureHandle, fullfile(outputDirectory, stem + ".png"), ...
    "Resolution", 220);
exportgraphics(figureHandle, fullfile(outputDirectory, stem + ".pdf"), ...
    "ContentType", "vector");
close(figureHandle);
end
