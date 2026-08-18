#!/usr/bin/env bash
set -euo pipefail

klipper_root=${KLIPPER_ROOT:-/workspace/external/klipper}
output_path=${OUTPUT_PATH:-/workspace/build/klipper-c-helper/c_helper.so}
chelper_dir="${klipper_root}/klippy/chelper"
chelper_init="${chelper_dir}/__init__.py"
compiler="${CROSS_PREFIX}gcc"
readelf="${CROSS_PREFIX}readelf"
nm="${CROSS_PREFIX}nm"
strip="${CROSS_PREFIX}strip"

for required_path in \
    "${chelper_init}" "${compiler}" "${readelf}" "${nm}" "${strip}" \
    "${SYSROOT}"; do
    if [[ ! -e "${required_path}" ]]; then
        echo "Required path not found: ${required_path}" >&2
        exit 1
    fi
done

mapfile -t source_names < <(
    python3 - "${chelper_init}" <<'PY'
import ast
import pathlib
import sys

init_path = pathlib.Path(sys.argv[1])
module = ast.parse(init_path.read_text(), filename=str(init_path))
for node in module.body:
    if not isinstance(node, ast.Assign):
        continue
    if not any(isinstance(target, ast.Name) and target.id == "SOURCE_FILES"
               for target in node.targets):
        continue
    source_files = ast.literal_eval(node.value)
    if not isinstance(source_files, (list, tuple)):
        raise SystemExit("SOURCE_FILES is not a list or tuple")
    for source_file in source_files:
        if not isinstance(source_file, str):
            raise SystemExit("SOURCE_FILES contains a non-string entry")
        print(source_file)
    break
else:
    raise SystemExit("Unable to find SOURCE_FILES in chelper/__init__.py")
PY
)

if [[ ${#source_names[@]} -eq 0 ]]; then
    echo "Klipper's SOURCE_FILES list is empty" >&2
    exit 1
fi

source_paths=()
for source_name in "${source_names[@]}"; do
    source_path="${chelper_dir}/${source_name}"
    if [[ ! -f "${source_path}" ]]; then
        echo "Klipper helper source not found: ${source_path}" >&2
        exit 1
    fi
    source_paths+=("${source_path}")
done

mkdir -p "$(dirname "${output_path}")"
temporary_output=$(mktemp "${output_path}.tmp.XXXXXX")
trap 'rm -f "${temporary_output}"' EXIT

echo "Building Klipper c_helper.so for the Creality MIPS host"
echo "Compiler: ${compiler}"
echo "Klipper:  ${klipper_root}"
echo "Sources:  ${#source_paths[@]} files from chelper/SOURCE_FILES"

"${compiler}" --sysroot="${SYSROOT}" \
    -Wall -O2 -shared -fPIC \
    -mips32r2 -mabi=32 -mhard-float -mfp64 \
    -mnan=2008 -Wa,-mnan=2008 \
    -o "${temporary_output}" \
    "${source_paths[@]}"

"${strip}" --strip-unneeded "${temporary_output}"

elf_header=$("${readelf}" --file-header "${temporary_output}")
if ! grep -Eq 'Class:[[:space:]]+ELF32' <<<"${elf_header}" \
    || ! grep -Eq 'Data:[[:space:]]+.*little endian' <<<"${elf_header}" \
    || ! grep -Eq 'Machine:[[:space:]]+MIPS' <<<"${elf_header}"; then
    echo "Built helper does not have the required ELF32 little-endian MIPS ABI" >&2
    echo "${elf_header}" >&2
    exit 1
fi

elf_flags=$(grep -E 'Flags:' <<<"${elf_header}")
for required_flag in nan2008 o32 mips32r2; do
    if [[ "${elf_flags}" != *"${required_flag}"* ]]; then
        echo "Built helper is missing required ELF flag: ${required_flag}" >&2
        echo "${elf_flags}" >&2
        exit 1
    fi
done

arch_attributes=$("${readelf}" --arch-specific "${temporary_output}")
if ! grep -Fq \
    'Tag_GNU_MIPS_ABI_FP: Hard float (32-bit CPU, 64-bit FPU)' \
    <<<"${arch_attributes}"; then
    echo "Built helper does not use the required MIPS hard-float FP64 ABI" >&2
    echo "${arch_attributes}" >&2
    exit 1
fi

version_info=$("${readelf}" --version-info "${temporary_output}")
max_glibc_version=$(
    grep -Eo 'GLIBC_[0-9]+(\.[0-9]+)+' <<<"${version_info}" \
        | sed 's/^GLIBC_//' \
        | sort -Vu \
        | tail -n 1
)
if [[ -z "${max_glibc_version}" \
    || $(printf '%s\n' '2.28' "${max_glibc_version}" | sort -V | tail -n 1) \
        != '2.28' ]]; then
    echo "Built helper requires unsupported glibc ${max_glibc_version:-unknown}" >&2
    exit 1
fi

dynamic_symbols=$("${nm}" --dynamic --defined-only "${temporary_output}")
for required_symbol in \
    serialqueue_alloc \
    stepcompress_find_past_positions; do
    if ! grep -Eq "[[:space:]]${required_symbol}$" \
        <<<"${dynamic_symbols}"; then
        echo "Built helper is missing ${required_symbol}" >&2
        exit 1
    fi
done

if [[ " ${source_names[*]} " == *" kin_filtered_bspline.c "* ]]; then
    for required_symbol in \
        filtered_bspline_controller_alloc \
        filtered_bspline_add_observation \
        filtered_bspline_get_hybrid_status; do
        if ! grep -Eq "[[:space:]]${required_symbol}$" \
            <<<"${dynamic_symbols}"; then
            echo "Built helper is missing ${required_symbol}" >&2
            exit 1
        fi
    done
fi

if [[ " ${source_names[*]} " == *" state_space_observer.c "* ]] \
    && ! grep -Eq '[[:space:]]state_space_observer_alloc$' \
        <<<"${dynamic_symbols}"; then
    echo "Built helper is missing the state-space observer symbols" >&2
    exit 1
fi

mv "${temporary_output}" "${output_path}"
trap - EXIT
chmod 0755 "${output_path}"

echo
file "${output_path}"
echo "${elf_flags}"
echo "${arch_attributes}" | sed -n '1,12p'
echo "Maximum required glibc version: ${max_glibc_version}"
echo "SHA-256: $(sha256sum "${output_path}" | awk '{print $1}')"
echo "Output: ${output_path}"
