clear;
close all;
clc;

t = linspace(0, 1, 500);
nBasis = 7;

%% Show how B-splines change with degree

figure;
layout = tiledlayout(2, 2, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

for degree = 0:3
    Phi = bsplineBasisMatrix(t, degree, nBasis);

    nexttile;
    plot(t, Phi, 'LineWidth', 1.2);
    grid on;
    xlim([0, 1]);
    ylim([0, 1.05]);

    xlabel('Normalised time');
    ylabel('Basis value');
    title(sprintf('Degree %d', degree));
end

title(layout, 'B-spline basis functions');

fontsize(gcf, 14, 'points');


%% Construct a command from cubic B-splines

degree = 3;
Phi = bsplineBasisMatrix(t, degree, nBasis);

gamma = [0.0; 0.5; -0.2; 0.9; 0.4; -0.1; 0.3];

u = Phi * gamma;

% Change one coefficient to demonstrate local support
gammaChanged = gamma;
gammaChanged(4) = gammaChanged(4) + 0.6;

uChanged = Phi * gammaChanged;

figure;
layout = tiledlayout(2, 1, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

nexttile;
plot(t, Phi, 'LineWidth', 1.2);
grid on;
xlim([0, 1]);
ylim([0, 1.05]);

xlabel('Normalised time');
ylabel('Basis value');
title('Cubic B-spline basis functions');

nexttile;
plot(t, u, 'LineWidth', 1.5);
hold on;
plot(t, uChanged, '--', 'LineWidth', 1.5);
grid on;
xlim([0, 1]);

xlabel('Normalised time');
ylabel('Command value');
title('Weighted sum of B-splines');

legend( ...
    'Original coefficients', ...
    'After changing \gamma_4', ...
    'Location', 'best');

title(layout, 'B-spline command construction');

fontsize(gcf, 14, 'points');


%% Local functions

function Phi = bsplineBasisMatrix(t, degree, nBasis)
% Return a matrix whose columns are B-spline basis functions.

    knots = openUniformKnots(degree, nBasis);
    Phi = zeros(numel(t), nBasis);

    for i = 1:nBasis
        Phi(:, i) = coxDeBoor(i, degree, t, knots).';
    end

    % The degree-zero definition uses t < final knot, so handle t = 1.
    finalPoint = (t == knots(end));
    Phi(finalPoint, :) = 0;
    Phi(finalPoint, end) = 1;
end


function knots = openUniformKnots(degree, nBasis)
% Create a clamped, uniformly spaced knot vector.

    nInterior = nBasis - degree - 1;

    if nInterior > 0
        interior = (1:nInterior) / (nInterior + 1);
    else
        interior = [];
    end

    knots = [
        zeros(1, degree + 1), ...
        interior, ...
        ones(1, degree + 1)
    ];
end


function N = coxDeBoor(i, degree, t, knots)
% Evaluate one B-spline basis function using Cox-de Boor recursion.

    if degree == 0
        N = double(t >= knots(i) & t < knots(i + 1));
        return;
    end

    N = zeros(size(t));

    leftDenominator = knots(i + degree) - knots(i);

    if leftDenominator ~= 0
        leftWeight = (t - knots(i)) / leftDenominator;

        N = N + leftWeight .* ...
            coxDeBoor(i, degree - 1, t, knots);
    end

    rightDenominator = ...
        knots(i + degree + 1) - knots(i + 1);

    if rightDenominator ~= 0
        rightWeight = ...
            (knots(i + degree + 1) - t) / rightDenominator;

        N = N + rightWeight .* ...
            coxDeBoor(i + 1, degree - 1, t, knots);
    end
end