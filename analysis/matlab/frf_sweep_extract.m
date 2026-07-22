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
results.x = buildAxisResult("X", points);
results.y = buildAxisResult("Y", points);
end


function validateAxis(points, axisName, expectedFrequencies)
%VALIDATEAXIS Require one point at every requested frequency.

axes = string({points.axis});
actualFrequencies = sort([points(axes == axisName).frequency_hz]).';
if ~isequal(actualFrequencies, expectedFrequencies)
    error("%s-axis frequencies do not match the sweep metadata.", axisName);
end
end


function axisResult = buildAxisResult(axisName, points)
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
axisResult.point = axisPoints;
end
