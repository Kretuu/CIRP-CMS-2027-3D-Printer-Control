function capture = motan_lightweight_load(logPath)
%MOTAN_LIGHTWEIGHT_LOAD Read one lightweight Motan JSON/GZIP capture.
% Internal loader for the sine-tracking workflow.
%
%   capture = motan_lightweight_load( ...
%       "data/raw/final_evaluation/sine10_hybrid_r2.json.gz")
%
% The lightweight logger stores JSON messages separated by ASCII ETX (0x03)
% in a gzip stream.  This loader returns the genuine accelerometer rows without
% interpolating or resampling them.  New captures also contain desired motion,
% final motor commands, and the shared position-observer result at each genuine
% physical sample timestamp.

logPath = string(logPath);
if ~isscalar(logPath) || ~isfile(logPath)
    error("Motan capture does not exist: %s", logPath);
end

temporaryDirectory = string(tempname);
mkdir(temporaryDirectory);
cleanup = onCleanup(@() removeTemporaryDirectory(temporaryDirectory));
inflatedFiles = gunzip(logPath, temporaryDirectory);
if numel(inflatedFiles) ~= 1
    error("Expected one file inside %s.", logPath);
end

payload = fileread(inflatedFiles{1});
messages = regexp(payload, char(3), "split");

toolheadHeader = defaultToolheadHeader();
toolheadChunks = cell(numel(messages), 1);
toolheadChunkCount = 0;

diagnostics = emptyDiagnostics();

eventTime = zeros(0, 1);
eventFilename = strings(0, 1);
eventState = strings(0, 1);
eventMode = strings(0, 1);
eventHybridXActive = NaN(0, 1);
eventHybridXSolves = NaN(0, 1);
eventHybridXMeasurementErrors = NaN(0, 1);
eventHybridXSolveFallbacks = NaN(0, 1);
eventHybridYActive = NaN(0, 1);
eventHybridYSolves = NaN(0, 1);
eventHybridYMeasurementErrors = NaN(0, 1);
eventHybridYSolveFallbacks = NaN(0, 1);
eventHybridPythonErrors = NaN(0, 1);
eventHybridWorkerDrops = NaN(0, 1);
currentFilename = "";
currentState = "";
currentMode = "";
currentHybridXActive = NaN;
currentHybridXSolves = NaN;
currentHybridXMeasurementErrors = NaN;
currentHybridXSolveFallbacks = NaN;
currentHybridYActive = NaN;
currentHybridYSolves = NaN;
currentHybridYMeasurementErrors = NaN;
currentHybridYSolveFallbacks = NaN;
currentHybridPythonErrors = NaN;
currentHybridWorkerDrops = NaN;

for messageIndex = 1:numel(messages)
    rawMessage = messages{messageIndex};
    if isempty(rawMessage)
        continue;
    end

    isExperimentData = contains( ...
        rawMessage, '"q":"trinkey_accel:experiment"');
    isExperimentHeader = contains( ...
        rawMessage, '"id":"trinkey_accel:experiment"');
    isStatus = contains(rawMessage, '"id":"status"') ...
        || contains(rawMessage, '"q":"status"');
    if ~(isExperimentData || isExperimentHeader || isStatus)
        continue;
    end

    try
        message = jsondecode(rawMessage);
    catch exception
        error("Invalid JSON message %d in %s: %s", ...
            messageIndex, logPath, exception.message);
    end

    if isExperimentHeader && isfield(message, "result")
        result = message.result;
        if isfield(result, "headers")
            if isfield(result.headers, "toolhead")
                toolheadHeader = string(result.headers.toolhead(:)).';
            end
        end
        continue;
    end

    if isExperimentData && isfield(message, "params")
        parameters = message.params;
        if isfield(parameters, "toolhead") && ~isempty(parameters.toolhead)
            toolheadChunkCount = toolheadChunkCount + 1;
            toolheadChunks{toolheadChunkCount} = double(parameters.toolhead);
        end
        diagnostics = updateDiagnostics(diagnostics, parameters);
        continue;
    end

    [status, statusEventTime] = readStatusMessage(message);
    if isempty(fieldnames(status))
        continue;
    end
    changed = false;
    if isfield(status, "print_stats")
        printStats = status.print_stats;
        if isfield(printStats, "filename") && ~isempty(printStats.filename)
            currentFilename = string(printStats.filename);
            changed = true;
        end
        if isfield(printStats, "state") && ~isempty(printStats.state)
            currentState = string(printStats.state);
            changed = true;
        end
    end
    if isfield(status, "filtered_bspline")
        filtered = status.filtered_bspline;
        currentMode = readString(filtered, "mode", currentMode);
        currentHybridXActive = readHybridScalar( ...
            filtered, "hybrid_x", "active", currentHybridXActive);
        currentHybridXSolves = readHybridScalar( ...
            filtered, "hybrid_x", "hybrid_solves", currentHybridXSolves);
        currentHybridXMeasurementErrors = readHybridScalar( ...
            filtered, "hybrid_x", "measurement_errors", ...
            currentHybridXMeasurementErrors);
        currentHybridXSolveFallbacks = readHybridScalar( ...
            filtered, "hybrid_x", "solve_fallbacks", ...
            currentHybridXSolveFallbacks);
        currentHybridYActive = readHybridScalar( ...
            filtered, "hybrid_y", "active", currentHybridYActive);
        currentHybridYSolves = readHybridScalar( ...
            filtered, "hybrid_y", "hybrid_solves", currentHybridYSolves);
        currentHybridYMeasurementErrors = readHybridScalar( ...
            filtered, "hybrid_y", "measurement_errors", ...
            currentHybridYMeasurementErrors);
        currentHybridYSolveFallbacks = readHybridScalar( ...
            filtered, "hybrid_y", "solve_fallbacks", ...
            currentHybridYSolveFallbacks);
        currentHybridPythonErrors = readScalar( ...
            filtered, "hybrid_observation_errors", ...
            currentHybridPythonErrors);
        currentHybridWorkerDrops = readScalar( ...
            filtered, "hybrid_worker_drops", currentHybridWorkerDrops);
        changed = true;
    end
    if changed
        eventTime(end + 1, 1) = statusEventTime; %#ok<AGROW>
        eventFilename(end + 1, 1) = currentFilename; %#ok<AGROW>
        eventState(end + 1, 1) = currentState; %#ok<AGROW>
        eventMode(end + 1, 1) = currentMode; %#ok<AGROW>
        eventHybridXActive(end + 1, 1) = currentHybridXActive; %#ok<AGROW>
        eventHybridXSolves(end + 1, 1) = currentHybridXSolves; %#ok<AGROW>
        eventHybridXMeasurementErrors(end + 1, 1) = ...
            currentHybridXMeasurementErrors; %#ok<AGROW>
        eventHybridXSolveFallbacks(end + 1, 1) = ...
            currentHybridXSolveFallbacks; %#ok<AGROW>
        eventHybridYActive(end + 1, 1) = currentHybridYActive; %#ok<AGROW>
        eventHybridYSolves(end + 1, 1) = currentHybridYSolves; %#ok<AGROW>
        eventHybridYMeasurementErrors(end + 1, 1) = ...
            currentHybridYMeasurementErrors; %#ok<AGROW>
        eventHybridYSolveFallbacks(end + 1, 1) = ...
            currentHybridYSolveFallbacks; %#ok<AGROW>
        eventHybridPythonErrors(end + 1, 1) = ...
            currentHybridPythonErrors; %#ok<AGROW>
        eventHybridWorkerDrops(end + 1, 1) = currentHybridWorkerDrops; %#ok<AGROW>
    end
end

toolhead = concatenateChunks(toolheadChunks, toolheadChunkCount, toolheadHeader);

capture = struct();
capture.path = logPath;
capture.toolhead = toolhead;
capture.events = table(eventTime, eventFilename, eventState, eventMode, ...
    eventHybridXActive, eventHybridXSolves, ...
    eventHybridXMeasurementErrors, eventHybridXSolveFallbacks, ...
    eventHybridYActive, eventHybridYSolves, ...
    eventHybridYMeasurementErrors, eventHybridYSolveFallbacks, ...
    eventHybridPythonErrors, eventHybridWorkerDrops, ...
    VariableNames=["event_time", "filename", "state", ...
    "filtered_bspline_mode", ...
    "hybrid_x_active", "hybrid_x_solves", ...
    "hybrid_x_measurement_errors", "hybrid_x_solve_fallbacks", ...
    "hybrid_y_active", "hybrid_y_solves", ...
    "hybrid_y_measurement_errors", "hybrid_y_solve_fallbacks", ...
    "hybrid_python_observation_errors", "hybrid_worker_drops"]);
capture.diagnostics = diagnostics;

clear cleanup;
end


function header = defaultToolheadHeader()
%DEFAULTTOOLHEADHEADER Return the current toolhead row definition.

common = ["time", "device_time_us", "sample_sequence", ...
    "x_raw", "y_raw", "z_raw", ...
    "x_acceleration", "y_acceleration", "z_acceleration", "flags"];
header = [common, "desired_x_position", "desired_x_acceleration", ...
    "motor_x_position", "motor_x_velocity", "observed_x_position", ...
    "observer_x_acceleration", "observer_valid", "reference_valid"];
end


function output = concatenateChunks(chunks, chunkCount, header)
%CONCATENATECHUNKS Join sample matrices and attach their logged headers.

if chunkCount == 0
    error("Capture contains no toolhead accelerometer samples.");
end
rows = vertcat(chunks{1:chunkCount});
if size(rows, 2) ~= numel(header)
    error("Toolhead rows have %d columns but the header has %d.", ...
        size(rows, 2), numel(header));
end
variableNames = matlab.lang.makeValidName(cellstr(header));
output = array2table(rows, "VariableNames", variableNames);
end


function diagnostics = emptyDiagnostics()
%EMPTYDIAGNOSTICS Construct diagnostics even for a truncated capture.

diagnostics = struct( ...
    "firmware", struct(), ...
    "host_queue_drops", NaN, ...
    "frame_errors", NaN, ...
    "packet_sequence_errors", NaN, ...
    "sync_timeouts", NaN, ...
    "read_errors", NaN, ...
    "motion_lookup_errors", NaN);
end


function diagnostics = updateDiagnostics(diagnostics, parameters)
%UPDATEDIAGNOSTICS Retain the newest cumulative stream diagnostics.

fields = ["firmware", "host_queue_drops", "frame_errors", ...
    "packet_sequence_errors", "sync_timeouts", "read_errors", ...
    "motion_lookup_errors"];
for field = fields
    name = char(field);
    if isfield(parameters, name)
        diagnostics.(name) = parameters.(name);
    end
end
end


function [status, eventTime] = readStatusMessage(message)
%READSTATUSMESSAGE Normalize initial and asynchronous status messages.

status = struct();
eventTime = NaN;
if isfield(message, "id") && isequal(string(message.id), "status") ...
        && isfield(message, "result")
    result = message.result;
    if isfield(result, "status")
        status = result.status;
    end
    eventTime = readScalar(result, "eventtime", eventTime);
elseif isfield(message, "q") && isequal(string(message.q), "status") ...
        && isfield(message, "params")
    parameters = message.params;
    if isfield(parameters, "status")
        status = parameters.status;
    end
    eventTime = readScalar(parameters, "eventtime", eventTime);
end
end


function value = readScalar(container, field, fallback)
%READSCALAR Read an optional numeric scalar.

value = fallback;
name = char(field);
if isfield(container, name) && ~isempty(container.(name))
    value = double(container.(name));
end
end


function value = readString(container, field, fallback)
%READSTRING Read an optional string value.

value = fallback;
name = char(field);
if isfield(container, name) && ~isempty(container.(name))
    value = string(container.(name));
end
end


function value = readHybridScalar(filtered, axisName, field, fallback)
%READHYBRIDSCALAR Read one required scalar from a hybrid-axis status object.

value = fallback;
axisField = char(axisName);
if ~isfield(filtered, axisField) || isempty(filtered.(axisField))
    return;
end
value = readScalar(filtered.(axisField), field, fallback);
end


function removeTemporaryDirectory(path)
%REMOVETEMPORARYDIRECTORY Remove the private gunzip destination.

if isfolder(path)
    rmdir(path, "s");
end
end
