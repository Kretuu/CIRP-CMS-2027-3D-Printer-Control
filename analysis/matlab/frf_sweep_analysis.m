function [results, models] = frf_sweep_analysis(runDirs)
%FRF_SWEEP_ANALYSIS Plot measured FRFs and identify the 3 m/s^2 models.
%
% Run from the repository root:
%
%   addpath("analysis/matlab");
%   runDirs = [
%       "data/raw/2026-07-20_1_5ms"
%       "data/raw/2026-07-20_2ms"
%       "data/raw/2026-07-20_2_5ms"
%       "data/raw/2026-07-20_3ms"
%   ];
%   [results, models] = frf_sweep_analysis(runDirs);
%
% Each curve stops where its commanded peak-to-peak displacement falls below
% one configured microstep on the corresponding printer axis.

MODEL_ACCELERATION_M_S2 = 3.0;

if nargin ~= 1
    error("Usage: results = frf_sweep_analysis(runDirs)");
end

runDirs = string(runDirs(:));
if isempty(runDirs)
    error("Provide at least one sweep directory.");
end

results = frf_sweep_extract(runDirs(1), false);
for resultIndex = 2:numel(runDirs)
    results(resultIndex, 1) = frf_sweep_extract(runDirs(resultIndex), false);
end

[~, order] = sort([results.commanded_accel_amplitude_m_s2]);
results = results(order);
results = results(:);

for resultIndex = 1:numel(results)
    results(resultIndex).x.used_for_frf = usableRows(results(resultIndex).x);
    results(resultIndex).y.used_for_frf = usableRows(results(resultIndex).y);
end

modelIndex = find(abs([results.commanded_accel_amplitude_m_s2] ...
    - MODEL_ACCELERATION_M_S2) < 1e-9, 1);
if isempty(modelIndex)
    error("The 3 m/s^2 sweep required for model identification is missing.");
end
models.x = frf_identify_model(results(modelIndex).x);
models.y = frf_identify_model(results(modelIndex).y);

printSummary(results, models);
plotFrfs(results, models);
end


function rows = usableRows(axisResult)
%USABLEROWS Select finite FRFs above the theoretical step-resolution limit.

rows = axisResult.within_step_resolution & isfinite(axisResult.frf);
end


function printSummary(results, models)
%PRINTSUMMARY Report the theory-derived frequency range for every sweep.

fprintf("\nFRF ranges from configured step resolution\n");
for resultIndex = 1:numel(results)
    fprintf("\n%.1f m/s^2\n", ...
        results(resultIndex).commanded_accel_amplitude_m_s2);
    printAxisSummary(results(resultIndex).x);
    printAxisSummary(results(resultIndex).y);
end

fprintf("\nIdentified 3 m/s^2 models\n");
printModelSummary(models.x);
printModelSummary(models.y);
end


function printAxisSummary(axisResult)
%PRINTAXISSUMMARY Print retained count and maximum frequency for one axis.

usedRows = axisResult.used_for_frf;
fprintf("  %s: %d/%d points, %g--%g Hz\n", axisResult.axis, ...
    nnz(usedRows), numel(usedRows), min(axisResult.frequency_hz(usedRows)), ...
    max(axisResult.frequency_hz(usedRows)));
end


function printModelSummary(model)
%PRINTMODELSUMMARY Print the selected order and complex fitting error.

fprintf("  %s: order %d/%d, relative RMS error %.3f\n", model.axis, ...
    model.numerator_order, model.denominator_order, model.relative_rms_error);
end


function plotFrfs(results, models)
%PLOTFRFS Plot every retained acceleration sweep in a four-panel layout.

figureHandle = figure("Name", "Measured and identified FRFs");
layout = tiledlayout(2, 2, "TileSpacing", "compact", "Padding", "compact");
colours = lines(numel(results));

xMagnitudeAxes = nexttile(layout, 1);
plotMagnitude(xMagnitudeAxes, results, "x", colours, models.x);
title(xMagnitudeAxes, "X-axis");
ylabel(xMagnitudeAxes, "Magnitude [dB]");
legendHandle = legend(xMagnitudeAxes, "Orientation", "horizontal");
legendHandle.Layout.Tile = "south";

yMagnitudeAxes = nexttile(layout, 2);
plotMagnitude(yMagnitudeAxes, results, "y", colours, models.y);
title(yMagnitudeAxes, "Y-axis");
ylabel(yMagnitudeAxes, "Magnitude [dB]");

xPhaseAxes = nexttile(layout, 3);
plotPhase(xPhaseAxes, results, "x", colours, models.x);
xlabel(xPhaseAxes, "Frequency [Hz]");
ylabel(xPhaseAxes, "Phase [deg]");

yPhaseAxes = nexttile(layout, 4);
plotPhase(yPhaseAxes, results, "y", colours, models.y);
xlabel(yPhaseAxes, "Frequency [Hz]");
ylabel(yPhaseAxes, "Phase [deg]");

minimumFrequencies = arrayfun(@(result) min(result.x.frequency_hz), results);
maximumFrequencies = arrayfun(@(result) max(result.x.frequency_hz), results);
frequencyLimits = [min(minimumFrequencies), max(maximumFrequencies)];
set([xMagnitudeAxes, yMagnitudeAxes, xPhaseAxes, yPhaseAxes], ...
    "XLim", frequencyLimits);
title(layout, "Measured and identified frequency-response functions");
fontsize(figureHandle, 14, "points");
end


function plotMagnitude(axisHandle, results, axisKey, colours, model)
%PLOTMAGNITUDE Plot retained magnitude curves without point markers.

hold(axisHandle, "on");
configureAxes(axisHandle);

for resultIndex = 1:numel(results)
    axisResult = results(resultIndex).(axisKey);
    rows = axisResult.used_for_frf;
    magnitudeDb = 20.0 * log10(abs(axisResult.frf(rows)));
    semilogx(axisHandle, axisResult.frequency_hz(rows), magnitudeDb, "-", ...
        "Color", colours(resultIndex, :), "LineWidth", 2.0, ...
        "DisplayName", sprintf("%.1f m/s^2", ...
        results(resultIndex).commanded_accel_amplitude_m_s2));
end

[modelFrequencyHz, modelFrf] = evaluateModel(model);
semilogx(axisHandle, modelFrequencyHz, 20.0 * log10(abs(modelFrf)), "k--", ...
    "LineWidth", 2.0, "DisplayName", "Identified model (3.0 m/s^2)");
end


function plotPhase(axisHandle, results, axisKey, colours, model)
%PLOTPHASE Plot retained unwrapped phase curves without point markers.

hold(axisHandle, "on");
configureAxes(axisHandle);
referencePhaseDeg = NaN;

for resultIndex = 1:numel(results)
    axisResult = results(resultIndex).(axisKey);
    rows = axisResult.used_for_frf;
    phaseDeg = unwrap(angle(axisResult.frf(rows))) * 180.0 / pi;

    if isnan(referencePhaseDeg)
        referencePhaseDeg = phaseDeg(1);
    else
        phaseDeg = phaseDeg + 360.0 ...
            * round((referencePhaseDeg - phaseDeg(1)) / 360.0);
    end

    semilogx(axisHandle, axisResult.frequency_hz(rows), phaseDeg, "-", ...
        "Color", colours(resultIndex, :), "LineWidth", 2.0, ...
        "HandleVisibility", "off");
end

[modelFrequencyHz, modelFrf] = evaluateModel(model);
modelPhaseDeg = unwrap(angle(modelFrf)) * 180.0 / pi;
modelPhaseDeg = modelPhaseDeg + 360.0 ...
    * round((referencePhaseDeg - modelPhaseDeg(1)) / 360.0);
semilogx(axisHandle, modelFrequencyHz, modelPhaseDeg, "k--", ...
    "LineWidth", 2.0, "HandleVisibility", "off");
end


function [frequencyHz, response] = evaluateModel(model)
%EVALUATEMODEL Evaluate one fitted model over its identification range.

omega = logspace(log10(model.minimum_omega_rad_s), ...
    log10(model.maximum_omega_rad_s), 500).';
frequencyHz = omega / (2.0 * pi);
response = freqs(model.numerator, model.denominator, omega);
end


function configureAxes(axisHandle)
%CONFIGUREAXES Apply common formatting to one FRF panel.

grid(axisHandle, "on");
box(axisHandle, "on");
set(axisHandle, "XScale", "log");
end
