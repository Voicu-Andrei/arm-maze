# ============================================================================
# trace.gdb -- automated tour of the recursive call stack in solve().
# Native on the Pi:   make trace      (or: gdb -q -batch -x trace.gdb ./build/maze)
#
# It breaks in push_cell (called once per cell the search enters), steps a few
# levels deep, and shows the REAL machine stack: a backtrace of nested solve()
# frames, the row/col held in callee-saved registers, and the saved frame
# pointer + return address -- i.e. the AAPCS64 calling convention in action.
# ============================================================================
set pagination off
set confirm off
set environment MAZE_ANIM 0          # run quiet: no animation, clean trace output

break push_cell
run

printf "\n=============================================================\n"
printf " Watching solve() recurse.  push_cell runs once per cell the\n"
printf " search ENTERS, so each stop below is one level deeper.\n"
printf " Watch the stack pointer (sp) and frame pointer (x29) drop by\n"
printf " exactly 0x40 = 64 bytes -- one solve() stack frame -- per level.\n"
printf "=============================================================\n\n"

set $i = 1
while $i < 5
  printf "  level %d:  enter cell (%d,%d)    x29 = %#lx   sp = %#lx\n", $i, $w0, $w1, $x29, $sp
  continue
  set $i = $i + 1
end
printf "  level %d:  enter cell (%d,%d)    x29 = %#lx   sp = %#lx   <-- deepest\n\n", $i, $w0, $w1, $x29, $sp

printf "----- the REAL machine call stack now (gdb backtrace) --------\n"
printf " each <solve> frame is one recursive call = one cell on the trail:\n"
bt
printf "\n----- this frame's row/col live in callee-saved registers ----\n"
info registers x19 x20
printf "\n----- the saved frame at [x29]: caller's FP, then return addr -\n"
printf " (saved by  stp x29, x30  in the prologue; restored by  ldp .. ret)\n"
x/2gx $x29
printf "\nThis backtrace IS the on-screen \"call stack\" HUD -- same frames.\n\n"

kill
quit
