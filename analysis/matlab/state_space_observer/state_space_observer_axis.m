function observer = state_space_observer_axis( ...
    model, processMeasurementRatio, sampleTimeS)
%STATE_SPACE_OBSERVER_AXIS Design one steady-state discrete Kalman filter.

% Use the identified position model with unity steady-state gain.
dcGain = model.numerator(end) / model.denominator(end);
plant = balreal(minreal(ss(tf(model.numerator / dcGain, ...
    model.denominator))));
[A, B, C, D] = ssdata(plant);
if abs(D) > 1e-10
    error("The observer model must be strictly proper.");
end

% From y = C*x and x_dot = A*x + B*u:
%   y_ddot = Ca*x + Du*u + Dv*u_dot.
Ca = C * A^2;
Du = C * A * B;
Dv = C * B;

discretePlant = c2d(plant, sampleTimeS, "zoh");
[Ad, Bd] = ssdata(discretePlant);
stateCount = size(A, 1);

% This is the full-state process-noise model from ELE460 lab Session 5.
% Only Q/R affects the steady-state gain, so R is normalised to one.
Q = processMeasurementRatio * eye(stateCount);
R = 1.0;
[M, P, Z, poles] = dlqe(Ad, eye(stateCount), Ca, Q, R);

% Keep the prior estimate x[k|k-1] as the runtime state. Combining the
% measurement and time updates gives one fixed matrix recurrence.
I = eye(stateCount);
observer.Fo = Ad * (I - M * Ca);
observer.Gu = Bd - Ad * M * Du;
observer.Gv = -Ad * M * Dv;
observer.Ga = Ad * M;

% The current position estimate is the posterior x[k|k].
observer.Ho = C * (I - M * Ca);
observer.Hu = -C * M * Du;
observer.Hv = -C * M * Dv;
observer.Ha = C * M;

if any(abs(poles) >= 1.0)
    error("The discrete Kalman filter is unstable.");
end

observer.axis = upper(string(model.axis));
observer.state_count = stateCount;
observer.sample_time_s = sampleTimeS;
observer.process_measurement_ratio = processMeasurementRatio;
observer.M = M;
observer.P = P;
observer.Z = Z;
observer.poles = poles;
observer.x0_per_mm = -(A \ B);
end
