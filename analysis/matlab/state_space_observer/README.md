# State-space acceleration observer package

This directory designs the plant-based Luenberger observers used to estimate
completed X/Y position from commanded motion and measured acceleration. It
uses the same continuous models as the standard filtered B-spline controller;
it does not fit a separate second-order model.

The implementation deliberately follows the sequence used in the ELE460
observer-design laboratory:

1. convert the known plant to state-space form;
2. form the measured-output equation;
3. check observability;
4. choose the observer poles;
5. calculate `L = place(A', Ca', poles)'`;
6. verify `eig(A - L*Ca)`; and
7. discretise the observer for runtime use.

`state_space_observer_design.m` is the public entry point.
`state_space_observer_axis.m` contains the same calculation for one axis so
the mathematical steps remain easy to read.

## Run it

First identify the existing FBF models using the FRF package:

```matlab
addpath("analysis/matlab/frf");
addpath("analysis/matlab/state_space_observer");

runDirs = [
    "data/raw/2026-08-11_1_5ms"
    "data/raw/2026-08-11_2ms"
    "data/raw/2026-08-11_2_5ms"
    "data/raw/2026-08-11_3ms"
];

[~, models] = frf_sweep_analysis(runDirs);
observers = state_space_observer_design(models, 250);
state_space_observer_print_config(observers);
```

The observer bandwidth is the 5 Hz value reported by the core paper. The
sample rate is passed explicitly because it must match the actual Trinkey
stream. With the current two-sensor `rate: 250` configuration, use 250 Hz even
though the FBF trajectory grid itself runs at 1 kHz. The BNO055's 125 Hz
bandwidth setting updates its filtered acceleration registers at 250 Hz, so
this avoids polling duplicate measurements and stays within the reliable
throughput of the shared I2C bus.

`state_space_observer_print_config` prints only the matrices needed at runtime
in the row-major order expected by the C helper. Copy that output into the
`[trinkey_accel]` configuration.

At runtime, `trinkey_accel.py` reconstructs the final motor command from
Klipper's generated step history, applies the configured acceleration sign and
stationary bias, and calls the small C matrix update. The published stream keeps
three signals separate:

```text
desired_position   nominal G-code/TrapQ reference
motor_position     final generated motor command
observed_position  model-assisted physical position estimate
```

The motor value therefore includes FBF compensation, kinematic conversion, and
step quantisation. Motan and a future hybrid controller can consume the same
observer batches; the observer is not calculated separately for each client.
An internal Klipper consumer starts with `start_observer_client()` and drains
new batches with the returned client's `pop_messages()` method.

## Where `C` comes from

For each axis, MATLAB performs:

```matlab
plant = ss(tf(unityDcNumerator, denominator));
[A, B, C, D] = ssdata(plant);
```

Thus, `C` is supplied by the state-space realisation of the already identified
transfer function. It is not guessed and it is not identified separately.
`balreal` then changes all state coordinates consistently to improve numerical
scaling without changing the plant's input-output transfer function.

Because the fitted plant is strictly proper, `D = 0`. Differentiating its
position output twice gives the acceleration measurement equation:

```text
Ca = C*A^2
Du = C*A*B
Dv = C*B

a_hat = Ca*x_hat + Du*u + Dv*u_dot
```

The continuous observer is therefore:

```text
x_hat_dot = A*x_hat + B*u
          + L*(a_measured - Ca*x_hat - Du*u - Dv*u_dot)

y_hat = C*x_hat
```

## Returned matrices

`observers.x` and `observers.y` contain the same plainly named fields. The
main runtime equation is:

```text
x_hat[k+1] = Fo*x_hat[k]
           + Gu*u[k]
           + Gv*u_dot[k]
           + Ga*a_measured[k]

y_hat[k] = Ho*x_hat[k]
```

When sample `k` arrives, the implementation returns the estimate at that sample
time, then stores its inputs for the transition to sample `k+1`. This ordering
is the causal interpretation of the zero-order-hold discrete model.

The matrices required later by Klipper are therefore `Fo`, `Gu`, `Gv`, `Ga`,
and `Ho`. The structure also retains `A`, `B`, `C`, `Ca`, `Du`, `Dv`, `L`, and
the pole/observability checks so that the implementation can be compared
directly with the dissertation equations.

`x0_per_mm` gives the equilibrium observer state for one millimetre of
stationary commanded position. At a stationary starting position `u0`, use:

```matlab
x_hat_0 = observer.x0_per_mm * u0;
```

## Numerical scaling

The ordinary `rank(obsv(A, Ca))` result is retained as
`observability_rank`, but it can underestimate rank for these high-order
models because the observability matrix contains powers of `A`. The design
therefore also checks whether `minreal` can remove any unobservable state and
verifies the poles actually achieved by `place`. The public summary reports
this minimal observable order and the achieved pole-placement error.

The balancing step is the only numerical conditioning measure added beyond
the ELE460 lab calculation. It does not reduce the model order or change the
transfer function.

## Runtime validity rules

The observer is invalid during the first 100 stationary samples (0.4 s at
250 Hz) while sensor bias is measured. It is also invalid for the first sample
after a missing, duplicated, or badly spaced timestamp. Dynamic state is reset
after such a gap, but the bias is retained. The config requires
`observer_sample_rate` to equal the physical Trinkey `rate`; changing either
rate requires regenerating the discrete matrices.

The estimate is model-assisted. It is useful for residual construction and
tracking comparisons, but it is not independent ground-truth displacement.
Missed motor steps and errors outside the identified model cannot be observed
perfectly from this data path.
