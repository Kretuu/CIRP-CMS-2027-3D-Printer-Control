function results = frf_sweep_extract(runDir, includeTimeSeries)
%FRF_SWEEP_EXTRACT Estimate X/Y FRF samples from one vibration sweep.

if nargin < 2
    includeTimeSeries = false;
end

runDir = string(runDir);
metadataPath = fullfile(runDir, "metadata.json");
if ~isfile(metadataPath)
    error("Missing sweep metadata: %s", metadataPath);
end
metadata = jsondecode(fileread(metadataPath));
analysisMetadata = readAnalysisMetadata(runDir);

pointDirs = fullfile(runDir, string({metadata.points.remote_run_id})).';
if any(~isfolder(pointDirs))
    error("The sweep contains a missing frequency-point directory.");
end

pointCells = cell(numel(pointDirs), 1);
for pointIndex = 1:numel(pointDirs)
    pointCells{pointIndex} = frf_extract_point( ...
        pointDirs(pointIndex), includeTimeSeries);
end
points = vertcat(pointCells{:});

expectedFrequencies = (double(metadata.frequency_start_hz): ...
    double(metadata.frequency_step_hz):double(metadata.frequency_end_hz)).';
validateAxis(points, "X", expectedFrequencies);
validateAxis(points, "Y", expectedFrequencies);

results = struct();
results.run_id = string(metadata.run_id);
results.commanded_accel_amplitude_m_s2 = ...
    double(metadata.commanded_accel_amplitude_mm_s2) / 1000.0;
results.x = buildAxisResult("X", points, analysisMetadata);
results.y = buildAxisResult("Y", points, analysisMetadata);
end


function metadata = readAnalysisMetadata(runDir)
%READANALYSISMETADATA Load optional, experiment-specific selection limits.

metadataPath = fullfile(runDir, "analysis_metadata.json");
if isfile(metadataPath)
    metadata = jsondecode(fileread(metadataPath));
else
    metadata = struct();
end
end


function validateAxis(points, axisName, expectedFrequencies)
%VALIDATEAXIS Require one point at every requested frequency.

axes = string({points.axis});
actualFrequencies = sort([points(axes == axisName).frequency_hz]).';
if ~isequal(actualFrequencies, expectedFrequencies)
    error("%s-axis frequencies do not match the sweep metadata.", axisName);
end
end


function axisResult = buildAxisResult(axisName, points, analysisMetadata)
%BUILDAXISRESULT Select and sort all points for one printer axis.

axes = string({points.axis});
axisPoints = points(axes == axisName);
[~, order] = sort([axisPoints.frequency_hz]);
axisPoints = axisPoints(order);

axisResult = struct();
axisResult.axis = axisName;
axisResult.frequency_hz = [axisPoints.frequency_hz].';
axisResult.frf = [axisPoints.frf].';
axisResult.within_step_resolution = ...
    [axisPoints.within_step_resolution].';
axisResult.first_nonreacting_frequency_hz = ...
    firstNonreactingFrequency(analysisMetadata, axisName);
axisResult.point = axisPoints;
end


function frequencyHz = firstNonreactingFrequency(metadata, axisName)
%FIRSTNONREACTINGFREQUENCY Return the observed exclusive frequency limit.

frequencyHz = Inf;
fieldName = "first_nonreacting_frequency_hz";
if ~isfield(metadata, fieldName)
    return;
end

limits = metadata.(fieldName);
axisField = char(lower(axisName));
if ~isfield(limits, axisField)
    return;
end

frequencyHz = double(limits.(axisField));
if ~isscalar(frequencyHz) || ~isfinite(frequencyHz) || frequencyHz <= 0.0
    error("Invalid first non-reacting frequency for the %s axis.", axisName);
end
end
