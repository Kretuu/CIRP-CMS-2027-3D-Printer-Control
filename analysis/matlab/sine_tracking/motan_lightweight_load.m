function capture = motan_lightweight_load(logPath)
%MOTAN_LIGHTWEIGHT_LOAD Read one lightweight Motan JSON/GZIP capture.
% Internal loader for the sine-tracking workflow.
%
%   capture = motan_lightweight_load("data/motan/sine10_comp_r2.json.gz")
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

baseHeader = defaultHeader("base");
toolheadHeader = defaultHeader("toolhead");
baseChunks = cell(numel(messages), 1);
toolheadChunks = cell(numel(messages), 1);
baseChunkCount = 0;
toolheadChunkCount = 0;

diagnostics = emptyDiagnostics();
configuredRateHz = NaN;
configuredBandwidthHz = NaN;
loggerProgram = "";
loggerVersion = "";

eventTime = zeros(0, 1);
eventFilename = strings(0, 1);
eventState = strings(0, 1);
eventEnabled = NaN(0, 1);
eventMode = strings(0, 1);
eventHybridX = NaN(0, 8);
eventHybridY = NaN(0, 8);
eventHybridPythonErrors = NaN(0, 1);
currentFilename = "";
currentState = "";
currentEnabled = NaN;
currentMode = "";
currentHybridX = NaN(1, 8);
currentHybridY = NaN(1, 8);
currentHybridPythonErrors = NaN;

for messageIndex = 1:numel(messages)
    rawMessage = messages{messageIndex};
    if isempty(rawMessage)
        continue;
    end

    isExperimentData = contains( ...
        rawMessage, '"q":"trinkey_accel:experiment"');
    isExperimentHeader = contains( ...
        rawMessage, '"id":"trinkey_accel:experiment"');
    isInformation = contains(rawMessage, '"id":"info"');
    isStatus = contains(rawMessage, '"id":"status"') ...
        || contains(rawMessage, '"q":"status"');
    if ~(isExperimentData || isExperimentHeader || isInformation || isStatus)
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
            if isfield(result.headers, "base")
                baseHeader = string(result.headers.base(:)).';
            end
            if isfield(result.headers, "toolhead")
                toolheadHeader = string(result.headers.toolhead(:)).';
            end
        end
        continue;
    end

    if isExperimentData && isfield(message, "params")
        parameters = message.params;
        if isfield(parameters, "base") && ~isempty(parameters.base)
            baseChunkCount = baseChunkCount + 1;
            baseChunks{baseChunkCount} = double(parameters.base);
        end
        if isfield(parameters, "toolhead") && ~isempty(parameters.toolhead)
            toolheadChunkCount = toolheadChunkCount + 1;
            toolheadChunks{toolheadChunkCount} = double(parameters.toolhead);
        end
        diagnostics = updateDiagnostics(diagnostics, parameters);
        continue;
    end

    if isInformation && isfield(message, "result") ...
            && isfield(message.result, "state")
        if isfield(message.result, "client_info")
            client = message.result.client_info;
            loggerProgram = readString(client, "program", loggerProgram);
            loggerVersion = readString(client, "version", loggerVersion);
        end
        continue;
    end

    [status, statusEventTime] = readStatusMessage(message);
    if isempty(fieldnames(status))
        continue;
    end
    if isfield(status, "configfile") && isfield(status.configfile, "settings")
        settings = status.configfile.settings;
        if isfield(settings, "trinkey_accel")
            trinkey = settings.trinkey_accel;
            configuredRateHz = readScalar(trinkey, "rate", configuredRateHz);
            configuredBandwidthHz = readScalar( ...
                trinkey, "bandwidth", configuredBandwidthHz);
        end
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
        currentEnabled = readScalar(filtered, "enabled", currentEnabled);
        currentMode = readString(filtered, "mode", currentMode);
        currentHybridX = readHybridAxisStatus( ...
            filtered, "hybrid_x", currentHybridX);
        currentHybridY = readHybridAxisStatus( ...
            filtered, "hybrid_y", currentHybridY);
        currentHybridPythonErrors = readScalar( ...
            filtered, "hybrid_observation_errors", ...
            currentHybridPythonErrors);
        changed = true;
    end
    if changed
        eventTime(end + 1, 1) = statusEventTime; %#ok<AGROW>
        eventFilename(end + 1, 1) = currentFilename; %#ok<AGROW>
        eventState(end + 1, 1) = currentState; %#ok<AGROW>
        eventEnabled(end + 1, 1) = currentEnabled; %#ok<AGROW>
        eventMode(end + 1, 1) = currentMode; %#ok<AGROW>
        eventHybridX(end + 1, :) = currentHybridX; %#ok<AGROW>
        eventHybridY(end + 1, :) = currentHybridY; %#ok<AGROW>
        eventHybridPythonErrors(end + 1, 1) = ...
            currentHybridPythonErrors; %#ok<AGROW>
    end
end

base = concatenateChunks(baseChunks, baseChunkCount, baseHeader, "base");
toolhead = concatenateChunks( ...
    toolheadChunks, toolheadChunkCount, toolheadHeader, "toolhead");

capture = struct();
capture.path = logPath;
capture.base = base;
capture.toolhead = toolhead;
capture.events = table(eventTime, eventFilename, eventState, eventEnabled, ...
    eventMode, eventHybridX, eventHybridY, eventHybridPythonErrors, ...
    VariableNames=["event_time", "filename", "state", ...
    "filtered_bspline_enabled", "filtered_bspline_mode", ...
    "hybrid_x_status", "hybrid_y_status", ...
    "hybrid_python_observation_errors"]);
capture.hybrid_status_columns = [ ...
    "training_samples", "active", "hybrid_solves", ...
    "prediction_gap_samples", "maximum_prediction_gap_samples", ...
    "measurement_errors", "solve_fallbacks", "weight_norm"];
capture.diagnostics = diagnostics;
capture.configured_rate_hz = configuredRateHz;
capture.configured_bandwidth_hz = configuredBandwidthHz;
capture.logger_program = loggerProgram;
capture.logger_version = loggerVersion;

clear cleanup;
end


function header = defaultHeader(sensor)
%DEFAULTHEADER Return the current combined-experiment row definition.

common = ["time", "device_time_us", "sample_sequence", ...
    "x_raw", "y_raw", "z_raw", ...
    "x_acceleration", "y_acceleration", "z_acceleration", "flags"];
if sensor == "base"
    header = [common, "desired_y_position", "desired_y_acceleration", ...
        "motor_y_position", "motor_y_velocity", "observed_y_position", ...
        "observer_y_acceleration", "observer_valid", "reference_valid"];
else
    header = [common, "desired_x_position", "desired_x_acceleration", ...
        "motor_x_position", "motor_x_velocity", "observed_x_position", ...
        "observer_x_acceleration", "observer_valid", "reference_valid"];
end
end


function output = concatenateChunks(chunks, chunkCount, header, sensor)
%CONCATENATECHUNKS Join sample matrices and attach their logged headers.

if chunkCount == 0
    error("Capture contains no %s accelerometer samples.", sensor);
end
rows = vertcat(chunks{1:chunkCount});
if size(rows, 2) ~= numel(header)
    error("%s rows have %d columns but the header has %d.", ...
        sensor, size(rows, 2), numel(header));
end
variableNames = matlab.lang.makeValidName(cellstr(header));
output = array2table(rows, "VariableNames", variableNames);

% Preserve the field names expected by the acceleration-only sine analysis.
% This keeps previous scripts and captures usable while the newer names make
% the distinction between desired, motor, and observed motion explicit.
if sensor == "toolhead" && ismember( ...
        "desired_x_acceleration", string(output.Properties.VariableNames))
    output.command_x_acceleration = output.desired_x_acceleration;
elseif sensor == "base" && ismember( ...
        "desired_y_acceleration", string(output.Properties.VariableNames))
    output.command_y_acceleration = output.desired_y_acceleration;
end
end


function diagnostics = emptyDiagnostics()
%EMPTYDIAGNOSTICS Construct diagnostics even for a truncated capture.

diagnostics = struct( ...
    "firmware", struct(), ...
    "clock", struct(), ...
    "host_queue_drops", NaN, ...
    "frame_errors", NaN, ...
    "packet_sequence_errors", NaN, ...
    "sync_timeouts", NaN, ...
    "read_errors", NaN, ...
    "observer_resets", NaN, ...
    "motion_lookup_errors", NaN);
end


function diagnostics = updateDiagnostics(diagnostics, parameters)
%UPDATEDIAGNOSTICS Retain the newest cumulative stream diagnostics.

fields = ["firmware", "clock", "host_queue_drops", "frame_errors", ...
    "packet_sequence_errors", "sync_timeouts", "read_errors", ...
    "observer_resets", "motion_lookup_errors"];
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


function values = readHybridAxisStatus(filtered, field, fallback)
%READHYBRIDAXISSTATUS Flatten one nested filtered-B-spline status object.

values = fallback;
name = char(field);
if ~isfield(filtered, name) || isempty(filtered.(name))
    return;
end
axisStatus = filtered.(name);
fields = ["training_samples", "active", "hybrid_solves", ...
    "prediction_gap_samples", "maximum_prediction_gap_samples", ...
    "measurement_errors", "solve_fallbacks", "weight_norm"];
for index = 1:numel(fields)
    values(index) = readScalar(axisStatus, fields(index), values(index));
end
end


function removeTemporaryDirectory(path)
%REMOVETEMPORARYDIRECTORY Remove the private gunzip destination.

if isfolder(path)
    rmdir(path, "s");
end
end
