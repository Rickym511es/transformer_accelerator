#======================================================
#  Full synth flow for top (tsmc13).  Source this from
#  design_vision/dc_shell with cwd = SYN/SYN_TOP:
#     dv> source run.tcl
#======================================================

set DESIGN top

#------------------------------------------------------
# 0. Sanity-check the library FIRST.  If target_library
#    is empty, nothing below can map and area stays 0.
#------------------------------------------------------
echo "=== target_library ==="
printvar target_library
echo "=== link_library ==="
printvar link_library
echo "=== loaded libs ==="
list_libs
# If target_library is empty / tsmc13 not listed, STOP and
# set it before continuing, e.g. (names per your kit):
#   set search_path  ". <path-to-decrypted-tsmc13-db-dir> $search_path"
#   set target_library "slow.db"
#   set link_library   "* slow.db fast.db dw_foundation.sldb"

#------------------------------------------------------
# 1. read + elaborate + link
#------------------------------------------------------
analyze -format verilog [list MAC.v tile.v softmax_modules.v PPU.v top.v]
elaborate $DESIGN
current_design $DESIGN
link

#------------------------------------------------------
# 2. constraints (your existing file)
#------------------------------------------------------
source synthesis.tcl

#------------------------------------------------------
# 3. THE step that was missing: technology mapping
#------------------------------------------------------
compile_ultra

#------------------------------------------------------
# 4. now reports have real numbers
#------------------------------------------------------
report_area -hierarchy
report_timing -max_paths 20
