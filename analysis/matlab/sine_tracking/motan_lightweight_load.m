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
currentFilename = "";
currentState = "";
currentEnabled = NaN;

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
    if isfield(status, "filtered_bspline") ...
            && isfield(status.filtered_bspline, "enabled") ...
            && ~isempty(status.filtered_bspline.enabled)
        currentEnabled = double(status.filtered_bspline.enabled);
        changed = true;
    end
    if changed
        eventTime(end + 1, 1) = statusEventTime; %#ok<AGROW>
        eventFilename(end + 1, 1) = currentFilename; %#ok<AGROW>
        eventState(end + 1, 1) = currentState; %#ok<AGROW>
        eventEnabled(end + 1, 1) = currentEnabled; %#ok<AGROW>
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
    VariableNames=["event_time", "filename", "state", ...
    "filtered_bspline_enabled"]);
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


function removeTemporaryDirectory(path)
%REMOVETEMPORARYDIRECTORY Remove the private gunzip destination.

if isfolder(path)
    rmdir(path, "s");
end
end
