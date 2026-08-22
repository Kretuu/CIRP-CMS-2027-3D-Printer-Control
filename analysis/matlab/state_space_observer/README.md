# State-space acceleration observer

This package designs the fixed steady-state Kalman observers used to estimate
X/Y position from the final motor command and the two Trinkey accelerometers.
It uses the same identified transfer functions as filtered B-spline feedback.

The design deliberately follows the steady-state Kalman-filter pattern from
ELE460 laboratory Session 5 (and Lecture 15):

```matlab
Q = qOverR * eye(stateCount);
R = 1;
[M, P, Z, poles] = dlqe(Ad, eye(stateCount), Ca, Q, R);
```

There is no online covariance update and no extra Butterworth filter. MATLAB
calculates the steady-state gain once; Klipper only evaluates fixed matrices.

## Generate the configuration

Run from the repository root:

```matlab
addpath("analysis/matlab/frf");
addpath("analysis/matlab/state_space_observer");

runDirs = [
    "data/raw/frf_sweeps/2026-08-11_1_5ms"
    "data/raw/frf_sweeps/2026-08-11_2ms"
    "data/raw/frf_sweeps/2026-08-11_2_5ms"
    "data/raw/frf_sweeps/2026-08-11_3ms"
];

[~, models] = frf_sweep_analysis(runDirs);
observers = state_space_observer_design(models, 250);
state_space_observer_print_config(observers);
```

The X and Y `Q/R` ratios in `state_space_observer_design.m` were selected by
replaying the 35 Hz capture. They give the acceleration measurement as much
authority as practical without amplifying acceleration-to-position correction
above unity. The X estimate remains more model-dependent because the fitted X
plant is non-minimum-phase.

## Measurement equation

For the identified position model

```text
x_dot = A*x + B*u
y     = C*x
```

differentiating position twice gives

```text
a = Ca*x + Du*u + Dv*u_dot
Ca = C*A^2,  Du = C*A*B,  Dv = C*B.
```

`dlqe` supplies the steady-state measurement-update gain `M`:

```text
x[k|k]   = x[k|k-1] + M*(a[k] - Ca*x[k|k-1] - Du*u[k] - Dv*u_dot[k])
x[k+1|k] = Ad*x[k|k] + Bd*u[k]
```

The exported matrices combine those two equations. Runtime stores the prior
state `x[k|k-1]`, publishes the current posterior position, and retains the next
prior state. `Hu`, `Hv`, and `Ha` are the three scalar feedthrough terms needed
to publish that current posterior rather than a one-sample-old prediction.

## Runtime signals

The shared Trinkey stream keeps these meanings separate:

```text
desired_position   nominal G-code/TrapQ reference
motor_position     final generated motor command
observed_position  model-assisted physical position estimate
```

The motor position includes the active compensation, kinematic conversion,
and step quantisation. Motan and hybrid FBF consume the same observer batches;
the observer is not recalculated for each client. Hybrid RLS runs in its
bounded worker, while motion preparation and step generation remain on the
Klipper reactor thread.

The observer is invalid during the first 100 stationary samples while the
BNO055 bias is measured. A missing sequence, non-monotonic mapped timestamp,
implausible command-coordinate jump, or unavailable motor-command history
resets the dynamic state but retains the bias. `observer_sample_rate` must
equal the physical Trinkey sample rate, so changing either rate requires
regenerating the matrices.

This is a model-assisted estimate, not independent encoder ground truth.
Errors outside the identified model and missed steps cannot be reconstructed
perfectly from acceleration alone.
