"""Check selected widths against the original sheet and reproduce summary statistics."""
from pathlib import Path
import csv, re, statistics
root = Path(__file__).resolve().parent / "measurements"
text = (root / "Fresh runs (mm).md").read_text()
groups = {title: [float(v) for v in re.findall(r"^-\s*([\d.]+)", body, re.M)]
          for title, body in re.findall(r"(\d+Hz [^:\n]+):\s*\n(.*?)(?=\n\s*\d+Hz|\Z)", text, re.S)}
selected = list(csv.DictReader((root / "selected_specimen_readings.csv").open()))
excluded = list(csv.DictReader((root / "excluded_specimen_readings.csv").open()))
summary = list(csv.DictReader((root / "width_summary.csv").open()))
assert len(selected) == 60 and len(excluded) == 2 and len(summary) == 6
for row in summary:
    capture = row["capture"]
    frequency, mode, run = capture.removeprefix("sine").split("_")
    title = f"{frequency}Hz { {'uncomp': 'uncompensated'}.get(mode, mode)} {run}"
    readings = [r for r in selected if r["capture"] == capture]
    values = [float(r["width_mm"]) for r in readings]
    assert [int(r["source_reading_number"]) for r in readings] == list(range(1, 11))
    assert values == groups[title][:10]
    omitted = [r for r in excluded if r["capture"] == capture]
    assert [float(r["width_mm"]) for r in omitted] == groups[title][10:]
    assert all(int(r["source_reading_number"]) == 11 for r in omitted)
    mean, sd = statistics.mean(values), statistics.stdev(values)
    assert abs(mean - float(row["mean_mm"])) < 1e-9
    assert abs(sd - float(row["sample_sd_mm"])) < 1e-9
    assert f"{mean:.3f}" == row["reported_mean_mm"]
    assert f"{sd:.3f}" == row["reported_sample_sd_mm"]
    print(f"{capture}: {mean:.3f} +/- {sd:.3f} mm (n=10)")
print("All six width summaries and the documented source selection verified.")
