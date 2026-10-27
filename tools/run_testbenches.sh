#!/bin/bash
# Run every self-checking VHDL testbench of the repository in xsim (Vivado 2022.2) and print
# its one-line summary ("<tb>: PASS (...)" or "<tb>: FAIL (...)"). Exit code 1 if any fails.
#
#   tools/run_testbenches.sh            all testbenches
#   tools/run_testbenches.sh sobel      only those whose name contains "sobel"
#
# Each testbench runs full 640x480 frames with random input gaps, output backpressure and a long
# stall, and checks data, tlast, the AXI-Stream rules and full rate (see the header of each tb).

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILTER=${1:-}
WORK=$(mktemp -d /tmp/run_testbenches.XXXXXX)
source /tools/Xilinx/Vivado/2022.2/settings64.sh >/dev/null 2>&1 || { echo "Vivado 2022.2 not found"; exit 2; }

# name | testbench entity | sources (relative to the repo) | xelab generics
TESTS=(
  "tb_yuyv2gray|tb_yuyv2gray|kria_dma_bist_mod/fw/hdl/yuyv2gray.vhd kria_dma_bist_mod/fw/hdl/tb/tb_yuyv2gray.vhd|"
  "tb_axis_unpack32to8|tb_axis_unpack32to8|kria_edge_detect/fw/hdl/axis_unpack32to8.vhd kria_edge_detect/fw/hdl/tb/tb_axis_unpack32to8.vhd|"
  "tb_axis_pack8to32|tb_axis_pack8to32|kria_edge_detect/fw/hdl/axis_pack8to32.vhd kria_edge_detect/fw/hdl/tb/tb_axis_pack8to32.vhd|"
  "tb_sobel3x3|tb_sobel3x3|kria_edge_detect/fw/hdl/sobel3x3.vhd kria_edge_detect/fw/hdl/tb/tb_sobel3x3.vhd|-generic_top G_WIDTH=640 -generic_top G_HEIGHT=480 -generic_top G_MODE=1 -generic_top G_FRAMES=4"
  "tb_downscale4x|tb_downscale4x|kria_face_detect/fw/hdl/downscale4x.vhd kria_face_detect/fw/hdl/tb/tb_downscale4x.vhd|"
)

fails=0
for t in "${TESTS[@]}"; do
  IFS='|' read -r name top srcs generics <<< "$t"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  dir="$WORK/$name"; mkdir -p "$dir"; cd "$dir"
  files=(); for s in $srcs; do files+=("$REPO/$s"); done
  if ! xvhdl -nolog -2008 "${files[@]}" > compile.log 2>&1; then
    echo "$name: FAIL (compile error, see $dir/compile.log)"; fails=$((fails + 1)); continue
  fi
  # shellcheck disable=SC2086
  if ! xelab -nolog $generics "$top" -s sim > elab.log 2>&1; then
    echo "$name: FAIL (elaboration error, see $dir/elab.log)"; fails=$((fails + 1)); continue
  fi
  line=$(xsim sim -nolog -runall 2>&1 | tee sim.log | grep -oE "$top: (PASS|FAIL).*" | head -1)
  if [[ "$line" == *": PASS"* ]]; then
    echo "$line"
  else
    echo "${line:-$name: FAIL (no summary line, see $dir/sim.log)}"; fails=$((fails + 1))
  fi
done

echo "run_testbenches: $fails failed (logs in $WORK)"
[[ $fails -eq 0 ]]
