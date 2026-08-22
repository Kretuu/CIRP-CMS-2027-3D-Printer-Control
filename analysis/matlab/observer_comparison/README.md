# Luenberger versus Kalman observer comparison

This package creates a controlled comparison between the original 5 Hz
pole-placement Luenberger observer and the final steady-state Kalman observer.
It uses `sine35_comp_test5.json.gz`, the last archived capture whose embedded
configuration has the old Luenberger recurrence and lacks the Kalman posterior
feedthrough fields `Hu`, `Hv`, and `Ha`.

The comparison does **not** compare `test5` directly with a later print. The
old position is the result logged during `test5`; the Kalman position is
replayed offline using the same recorded:

- final X motor position;
- final X motor velocity; and
- sign- and bias-corrected toolhead X acceleration.

Consequently, differences in the figure come from the observer recurrence,
not from a different physical print or accelerometer realization.

## Run

From the repository root:

```matlab
addpath("analysis/matlab/observer_comparison");
report = observer_comparison_analysis();
```

The optional arguments are the capture, deployed observer configuration, and
output directory:

```matlab
report = observer_comparison_analysis( ...
    "data/raw/motan_fresh/sine35_comp_test5.json.gz", ...
    "klipper_extensions/trinkey_accel.cfg", ...
    "data/processed/observer_comparison");
```

The script selects a central 0.5-second interval from retained sine pass 3 and
exports:

```text
luenberger_kalman_position_comparison.png
luenberger_kalman_position_comparison.pdf
luenberger_kalman_position_comparison.csv
```

The PDF is vector output and all figure text is 14 points for slides.

## Suggested caption

> Comparison of X-position estimates produced by the original 5 Hz
> pole-placement Luenberger observer and the final steady-state Kalman
> observer. Both observers are evaluated using the same recorded final motor
> command and bias-corrected toolhead acceleration from the third steady
> 35 Hz sine pass of `sine35_comp_test5`; the Kalman result is an offline
> replay. The desired trajectory is shown as a reference and is not an
> independent position measurement.

## Interpretation

The experiment demonstrates why the observer gain design was changed. It does
not establish absolute position accuracy because neither observer is compared
with an independent displacement sensor. In dissertation wording, describe
the result as a comparison of two model-assisted estimates under identical
recorded inputs. The large red excursions demonstrate the old observer's
sensitivity to acceleration measurement content; they should not all be
labelled sensor noise because genuine unmodelled mechanical acceleration may
also contribute.
