clear;
close all;
clc;

% Illustrative vibration mode
fn = 10;                   % Undamped natural frequency [Hz]
zeta = 0.05;               % Damping ratio [-]

wn = 2*pi*fn;              % Undamped natural frequency [rad/s]
wd = wn*sqrt(1-zeta^2);    % Damped natural frequency [rad/s]

% ZV input-shaper parameters
t1 = 0;
t2 = pi/wd;                % Half of damped oscillation period

K = exp(-zeta*pi/sqrt(1-zeta^2));
A1 = 1/(1 + K);
A2 = K/(1 + K);

% Time vector
t = linspace(0, 5/fn, 3000);

% Unit-impulse response scaling
C = wn/sqrt(1-zeta^2);

% Response to first impulse
tau1 = t - t1;
y1 = zeros(size(t));
valid1 = tau1 >= 0;
y1(valid1) = A1*C ...
    .* exp(-zeta*wn*tau1(valid1)) ...
    .* sin(wd*tau1(valid1));

% Response to second impulse
tau2 = t - t2;
y2 = zeros(size(t));
valid2 = tau2 >= 0;
y2(valid2) = A2*C ...
    .* exp(-zeta*wn*tau2(valid2)) ...
    .* sin(wd*tau2(valid2));

% Combined response
yTotal = y1 + y2;

% Normalise for a clearer conceptual plot
scale = max(abs([y1, y2]));
y1 = y1/scale;
y2 = y2/scale;
yTotal = yTotal/scale;

figure('Units', 'centimeters', 'Position', [2 2 16 15], ...
    'Color', 'w', 'Renderer', 'painters', 'ToolBar', 'none');

tiledlayout(3, 1, ...
    'TileSpacing', 'compact', ...
    'Padding', 'loose');

% Input-shaper impulses
axImpulse = nexttile;
stem([t1, t2], [A1, A2], 'filled', 'LineWidth', 1.5);
grid on;
xlim([-0.02*t(end), t(end)]);
ylim([0, 1.2*max([A1, A2])]);
xticklabels([]);
ylabel({'Impulse weight', '[-]'});
text(t1, A1, '  A_1', 'VerticalAlignment', 'bottom');
text(t2, A2, '  A_2', 'VerticalAlignment', 'bottom');

% Individual responses
axIndividual = nexttile;
plot(t, y1, 'LineWidth', 2);
hold on;
plot(t, y2, '--', 'LineWidth', 2);
xline(t2, ':', 'LineWidth', 2);
yline(0);
grid on;
xlim([-0.02*t(end), t(end)]);
xticklabels([]);

ylabel({'Normalised response', '[-]'});
legend('Response to first impulse', ...
       'Response to second impulse', ...
       'Location', 'northeast');

% Combined response
axCombined = nexttile;
plot(t, yTotal, 'LineWidth', 2);
hold on;
xline(t2, ':', 'LineWidth', 2);
yline(0);
grid on;
xlim([-0.02*t(end), t(end)]);

xlabel('Time [s]');
ylabel({'Combined response', '[-]'});

combinedYLim = ylim;
combinedYPad = 0.08*diff(combinedYLim);
ylim(combinedYLim + combinedYPad*[-1 1]);

for ax = [axImpulse, axIndividual, axCombined]
    ax.Toolbar.Visible = 'off';
end

fontsize(gcf, 14, 'points');

% Export as a vector PDF
exportgraphics(gcf, ...
    'input-shaping-cancellation.pdf', ...
    'ContentType', 'vector');
exportgraphics(gcf, ...
    'input-shaping-cancellation.png', ...
    'Resolution', 300);
close(gcf);
