# Fixed-Acceleration FRF Sweep Tutorial

This tutorial describes how to collect X/Y frequency response data with
`run_vibration_sweep.py` and prepare it for model identification in MATLAB.

The experiment is designed for the Ender 3 V3 bed-slinger layout:

- X motion is measured with the toolhead accelerometer, column `ax_raw`.
- Y motion is measured with the bed/base accelerometer, column `ay_raw`.
- Z is not swept.

## 1. Run A Dry Plan

From the repository root:

```sh
python orchestrator/run_vibration_sweep.py --dry-run --freq-start 1 --freq-end 5
```

The dry run creates a `metadata.json` plan under:

```text
data/raw/<timestamp>_xy_frf_sweep/
```

Check that the displacement amplitudes are reasonable. The sweep holds
commanded acceleration amplitude constant, so low frequencies need larger
displacement:

```text
A = commanded_accel_amplitude / (2*pi*f)^2
```

If the script rejects the plan, lower `--accel-amplitude` or raise
`--freq-start`.

## 2. Run The Sweep

Default run:

```sh
python orchestrator/run_vibration_sweep.py
```

Useful options:

```sh
python orchestrator/run_vibration_sweep.py --axis X
python orchestrator/run_vibration_sweep.py --axis Y
python orchestrator/run_vibration_sweep.py --freq-start 5 --freq-end 80 --freq-step 1
python orchestrator/run_vibration_sweep.py --accel-amplitude 100
python orchestrator/run_vibration_sweep.py --serial-port /dev/tty.usbmodemXXXXX
python orchestrator/run_vibration_sweep.py --moonraker-url http://192.168.0.100:7125
```

The runner moves the printer to the configured center position unless
`--skip-setup` is passed. Home the printer before running the sweep.

## 3. Output Structure

Each run creates:

```text
data/raw/<timestamp>_xy_frf_sweep/
  metadata.json
  x_001Hz.csv
  x_002Hz.csv
  ...
  y_001Hz.csv
  y_002Hz.csv
  ...
```

`metadata.json` stores the sweep settings and one entry per frequency:

- `frequency_hz`
- `displacement_amplitude_mm`
- `velocity_amplitude_mm_s`
- `duration_s`
- `ramp_time_s`
- `sensor_chip`
- `sensor_column`
- `csv_file`

Each CSV contains three row types:

- `event`: experiment events such as `pre_roll_start`, `moonraker_send`,
  `moonraker_return`, `post_roll_start`, and `file_complete`.
- `sample`: parsed Trinkey accelerometer samples.
- `raw`: non-sample serial lines preserved for debugging.

Use only `sample` rows for FRF estimation.

## 4. Commanded Input

For each sweep point, Klipper receives a displacement sine command:

```text
x_cmd(t) = A * sin(2*pi*f*t)
```

The commanded acceleration input is:

```text
a_cmd(t) = -(2*pi*f)^2 * A * sin(2*pi*f*t)
```

Because `A` is computed from the requested fixed acceleration amplitude:

```text
A = commanded_accel_amplitude / (2*pi*f)^2
```

the acceleration amplitude is constant across frequency, while displacement
amplitude decreases as frequency increases.

## 5. Timing Limitation

The CSV event rows are useful for trimming, but they are not exact physical
motion-start markers. They are recorded on the PC using `time.monotonic()`,
while the accelerometer samples use Trinkey `t_us`.

Without a hardware sync signal wired from the printer MCU to the Trinkey, do
not treat `moonraker_send` as exact motion start. A timing error of `dt`
causes phase error:

```text
phase_error_degrees = 360 * frequency_hz * dt
```

At 100 Hz, 1 ms is 36 degrees.

The recommended workflow is therefore to estimate the complex response from
the steady-state sine wave in MATLAB, then correct any remaining constant
delay as a linear phase term across frequency.

## 6. MATLAB FRF Extraction

For each frequency:

1. Read `metadata.json`.
2. Load the corresponding CSV.
3. Keep `row_type == "sample"`.
4. Keep the expected sensor chip and axis column:
   - X: `trinkey_chip == "toolhead"`, use `ax_raw`.
   - Y: `trinkey_chip == "base"`, use `ay_raw`.
5. Convert `t_us` to seconds.
6. Remove duplicate or missing timestamps if needed.
7. Estimate the motion onset from the measured signal.
8. Discard ramp-up and ramp-down. Use the steady middle of the record.
9. Fit the measured output to sine and cosine at the commanded frequency.

Example MATLAB sketch:

```matlab
meta = jsondecode(fileread("data/raw/RUN_ID/metadata.json"));

points = meta.points;
H = zeros(numel(points), 1);
w = zeros(numel(points), 1);

for k = 1:numel(points)
    p = points(k);
    csvPath = fullfile(meta.run_dir, p.csv_file);
    T = readtable(csvPath, "TextType", "string");

    samples = T.row_type == "sample" & T.trinkey_chip == p.sensor_chip;
    t = double(T.t_us(samples)) * 1e-6;
    y = double(T.(p.sensor_column)(samples));

    t = t - t(1);

    f = p.frequency_hz;
    omega = 2*pi*f;

    % Estimate motion onset from the measured channel. This is better than
    % using the PC event rows as exact timing markers.
    dt = median(diff(t));
    win = max(5, round(0.10 / dt));
    y0 = y - median(y(1:min(numel(y), win)));
    env = sqrt(movmean(y0.^2, win));
    baseline = median(env(1:min(numel(env), win)));
    threshold = baseline + 0.20 * (max(env) - baseline);
    onsetIdx = find(env > threshold, 1, "first");
    if isempty(onsetIdx)
        onsetIdx = 1;
    end
    motionStart = t(onsetIdx);

    % Use the steady-state section only. Add a small extra margin so the
    % fitted data is away from the ramp-up and ramp-down regions.
    margin = 0.25 / f;
    steadyStart = motionStart + p.ramp_time_s + margin;
    steadyEnd = motionStart + p.duration_s - p.ramp_time_s - margin;
    keep = t > steadyStart & t < steadyEnd;

    % Fallback if onset detection is poor for a noisy low-amplitude point.
    if nnz(keep) < 20
        lo = prctile(t, 35);
        hi = prctile(t, 65);
        keep = t > lo & t < hi;
    end

    tk = t(keep);
    yk = y(keep);
    yk = yk - mean(yk);

    Phi = [sin(omega*tk), cos(omega*tk), ones(size(tk))];
    theta = Phi \ yk;

    B = theta(1);
    C = theta(2);

    % For y = B*sin(wt) + C*cos(wt), complex amplitude under the
    % real{Y*exp(jwt)} convention is C - j*B. Keep one convention
    % consistently across all frequencies.
    Y = C - 1i*B;

    % Commanded acceleration is -accel_amp*sin(wt), so its complex
    % amplitude in the same convention is j*accel_amp.
    U = 1i * meta.commanded_accel_amplitude_mm_s2;

    H(k) = Y / U;
    w(k) = omega;
end
```

The exact complex-sign convention is less important than consistency. Verify
it with a known sine signal before fitting models.

## 7. Delay Correction

Any remaining constant timing delay appears as a linear phase term:

```text
H_measured(jw) = H_true(jw) * exp(-j*w*tau)
```

In MATLAB:

```matlab
phase = unwrap(angle(H));

% Choose a frequency band where the phase trend is dominated by delay,
% not resonance behavior.
idx = w > 2*pi*5 & w < 2*pi*20;
coeff = polyfit(w(idx), phase(idx), 1);
tau = -coeff(1);

H_corrected = H .* exp(1i*w*tau);
```

Inspect the result before using it. If the correction distorts resonance
regions, choose a different fitting band or leave the delay term in the model
interpretation.

## 8. Using `invfreqs`

After extracting complex FRF values:

```matlab
nb = 5;  % numerator order, choose based on model complexity
na = 6;  % denominator order

[b, a] = invfreqs(H_corrected, w, nb, na);
G = tf(b, a);
```

Plot the measured and fitted FRFs:

```matlab
Hfit = freqs(b, a, w);

figure;
subplot(2,1,1);
semilogx(w/(2*pi), 20*log10(abs(H_corrected)), "o");
hold on;
semilogx(w/(2*pi), 20*log10(abs(Hfit)), "-");
grid on;
ylabel("Magnitude (dB)");

subplot(2,1,2);
semilogx(w/(2*pi), unwrap(angle(H_corrected))*180/pi, "o");
hold on;
semilogx(w/(2*pi), unwrap(angle(Hfit))*180/pi, "-");
grid on;
xlabel("Frequency (Hz)");
ylabel("Phase (deg)");
```

Fit X and Y separately because they use different accelerometers and printer
mechanics.

## 9. Practical Notes

- Start with a low acceleration amplitude, such as `70 mm/s^2`, to avoid
  rejected low-frequency points and excessive motion.
- If low-frequency points are too large, raise `--freq-start`.
- Prefer several steady cycles over very short tests. The script uses 8 test
  cycles clamped between 2 and 8 seconds.
- For each frequency, discard transient regions and use only steady-state data.
- Keep raw CSVs unchanged; do all trimming and delay correction in MATLAB.
