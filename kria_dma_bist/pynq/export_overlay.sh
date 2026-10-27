#!/usr/bin/env bash
# Extract a PYNQ overlay (.bit + .hwh with the same base name) from a Vivado XSA.
#
#   ./export_overlay.sh [xsa] [name]
#     xsa   default: ../fw/prj/fpga_top.xsa
#     name  default: dma_loop   -> writes <name>.bit and <name>.hwh next to this script
#
# The top-level .hwh is the HW_HANDOFF entry marked BD_TYPE="DEFAULT_BD" in the XSA's
# sysdef.xml; the others (e.g. design_1_smartconnect_0_1.hwh) are scoped sub-designs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
xsa="${1:-$here/../fw/prj/fpga_top.xsa}"
name="${2:-dma_loop}"

[[ -f "$xsa" ]] || { echo "XSA not found: $xsa" >&2; exit 1; }

sysdef="$(unzip -p "$xsa" sysdef.xml)"
bit="$(grep -o 'Type="BIT" Name="[^"]*"' <<<"$sysdef" | head -1 | sed 's/.*Name="\([^"]*\)"/\1/')"
hwh="$(grep -o 'Type="HW_HANDOFF" Name="[^"]*"[^>]*BD_TYPE="DEFAULT_BD"' <<<"$sysdef" | head -1 \
       | sed 's/.*Name="\([^"]*\)".*/\1/')"

[[ -n "$bit" ]] || { echo "no bitstream in $xsa (export the XSA with 'include bitstream')" >&2; exit 1; }
[[ -n "$hwh" ]] || { echo "no top-level .hwh in $xsa" >&2; exit 1; }

unzip -p "$xsa" "$bit" > "$here/$name.bit"
unzip -p "$xsa" "$hwh" > "$here/$name.hwh"

echo "xsa : $xsa ($(date -r "$xsa" '+%F %T'))"
echo "bit : $bit -> $name.bit ($(stat -c %s "$here/$name.bit") bytes)"
echo "hwh : $hwh -> $name.hwh"
grep -o 'NAME="C_SG_LENGTH_WIDTH" VALUE="[0-9]*"' "$here/$name.hwh" | head -1 \
    | sed 's/.*VALUE="\([0-9]*\)"/DMA length register: \1 bits/' || true
