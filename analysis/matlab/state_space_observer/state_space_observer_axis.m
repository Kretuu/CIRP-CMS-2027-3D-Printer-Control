function observer = state_space_observer_axis( ...
    model, observerBandwidthHz, sampleTimeS)
%STATE_SPACE_OBSERVER_AXIS Design one plant-based Luenberger observer.
%
% The observer uses commanded position u, commanded velocity u_dot, and
% measured acceleration a_m:
%
%   xhat_dot = A*xhat + B*u ...
%       + L*(a_m - Ca*xhat - Du*u - Dv*u_dot)
%   yhat = C*xhat
%
% MATLAB performs the numerically sensitive work here. Klipper only needs
% the discrete Fo, Gu, Gv, Ga, and Ho matrices returned in observer.

axisName = upper(string(model.axis));

% The measured acceleration FRF also represents position-to-position
% dynamics away from DC. Match the FBF model by enforcing unity DC gain.
dcGain = model.numerator(end) / model.denominator(end);
if ~isfinite(dcGain) || abs(dcGain) < 1e-12
    error("The %s-axis model has no usable DC gain.", axisName);
end

numerator = model.numerator / dcGain;
plant = minreal(ss(tf(numerator, model.denominator)));

% BALREAL changes only the internal state coordinates. It keeps the same
% transfer function while making high-order pole placement more reliable.
plant = balreal(plant);
[A, B, C, D] = ssdata(plant);

if abs(D) > 1e-10
    error("The %s-axis observer requires a strictly proper model.", axisName);
end

% Differentiate y = C*x twice, using x_dot = A*x + B*u:
%   y_ddot = Ca*x + Du*u + Dv*u_dot.
Ca = C * A^2;
Du = C * A * B;
Dv = C * B;

stateCount = size(A, 1);
observabilityMatrix = obsv(A, Ca);

% OBSV can be badly conditioned for a sixth- or seventh-order model because
% it contains powers of A. MINREAL provides a numerically safer check that
% the acceleration output has not made any state unobservable.
observabilitySystem = ss( ...
    A, eye(stateCount), Ca, zeros(1, stateCount));
minimalObservabilitySystem = minreal(observabilitySystem);
[minimalA, ~, ~, ~] = ssdata(minimalObservabilitySystem);
observableOrder = size(minimalA, 1);
if observableOrder ~= stateCount
    error("The %s-axis acceleration model is not observable.", axisName);
end

% A Butterworth pattern gives a distinct, stable 5 Hz pole set. The gain is
% calculated exactly as in the ELE460 lab: L = place(A', Ca', poles)'.
[~, normalisedPoles, ~] = buttap(stateCount);
desiredPoles = 2.0 * pi * observerBandwidthHz * normalisedPoles;
L = place(A', Ca', desiredPoles)';
achievedPoles = eig(A - L * Ca);

poleRelativeError = norm(poly(achievedPoles) - poly(desiredPoles)) ...
    / norm(poly(desiredPoles));
if any(real(achievedPoles) >= 0.0) || poleRelativeError > 1e-4
    error("Observer pole placement failed for the %s axis.", axisName);
end

% Collect the continuous observer using inputs [u; u_dot; a_m], then
% discretise the complete equation. This preserves all three input effects.
observerA = A - L * Ca;
observerB = [B - L * Du, -L * Dv, L];
continuousObserver = ss( ...
    observerA, observerB, C, zeros(1, 3));
discreteObserver = c2d(continuousObserver, sampleTimeS, "zoh");
[Fo, discreteInputs, Ho, ~] = ssdata(discreteObserver);

if any(abs(eig(Fo)) >= 1.0)
    error("The discrete %s-axis observer is unstable.", axisName);
end

% Keep the result flat and explicit so each field maps directly to one
% equation or one matrix required by the future Klipper implementation.
observer.axis = axisName;
observer.state_count = stateCount;
observer.bandwidth_hz = observerBandwidthHz;
observer.sample_time_s = sampleTimeS;
observer.A = A;
observer.B = B;
observer.C = C;
observer.D = D;
observer.Ca = Ca;
observer.Du = Du;
observer.Dv = Dv;
observer.L = L;
observer.desired_poles = desiredPoles;
observer.achieved_poles = achievedPoles;
observer.observability_rank = rank(observabilityMatrix);
observer.observable_order = observableOrder;
observer.pole_relative_error = poleRelativeError;
observer.Fo = Fo;
observer.Gu = discreteInputs(:, 1);
observer.Gv = discreteInputs(:, 2);
observer.Ga = discreteInputs(:, 3);
observer.Ho = Ho;
observer.x0_per_mm = -(A \ B);
end
