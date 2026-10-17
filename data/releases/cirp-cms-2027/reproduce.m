% Reproduce the explicitly selected CIRP CMS 2027 dataset.
releaseDir = string(fileparts(mfilename("fullpath")));
repoRoot = string(fileparts(fileparts(fileparts(releaseDir))));
selection = jsondecode(fileread(fullfile(releaseDir, "selection.json")));
addpath(fullfile(repoRoot, "analysis", "matlab", "frf"));
addpath(fullfile(repoRoot, "analysis", "matlab", "sine_tracking"));
outputDir = fullfile(repoRoot, "build", "cirp-cms-2027-reproduction");
if ~isfolder(outputDir), mkdir(outputDir); end
[frfResults, models] = frf_sweep_analysis( ...
    fullfile(repoRoot, string(selection.frf_sweep_directories)));
assert(round(models.x.relative_rms_error, 3) == 0.160);
assert(round(models.y.relative_rms_error, 3) == 0.158);
assert(round(models.x.maximum_omega_rad_s/(2*pi)) == 100);
assert(round(models.y.maximum_omega_rad_s/(2*pi)) == 89);
save(fullfile(outputDir, "frf-results.mat"), "frfResults", "models");
exportgraphics(gcf, fullfile(outputDir, "frequency-responses.pdf"), ...
    "ContentType", "vector");
selectedDir = string(tempname);
mkdir(selectedDir);
cleanupSelected = onCleanup(@() rmdir(selectedDir, "s"));
for name = string(selection.evaluation_capture_basenames).'
    for extension = [".json.gz", ".index.gz"]
        copyfile(fullfile(repoRoot, string(selection.evaluation_directory), ...
            name + extension), selectedDir);
    end
end
report = sine_tracking_analysis(selectedDir, outputDir);
expected = readtable(fullfile(releaseDir, "reference_results", ...
    "sine_tracking_summary.csv"), "TextType", "string");
assert(isequal(string(report.summary.selected_capture), expected.selected_capture));
assert(all(abs(report.summary.overall_position_rms_error_um - ...
    expected.overall_position_rms_error_um) < 1e-6));
assert(all(report.summary.pass_count == 6));
clear cleanupSelected;
fprintf("Frozen paper selection and numerical checks passed.\n");
