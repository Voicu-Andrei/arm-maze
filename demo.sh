#!/usr/bin/env bash
# ============================================================================
# demo.sh -- guided, paused walkthrough of the A64 maze runner for the talk.
# Run it with:  make demo     (or directly: ./demo.sh)
# On the Pi leave RUN empty.  Off-Pi:  RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu" ./demo.sh
# ============================================================================
set -u
RUN="${RUN:-}"
BIN="./build/maze"
REF="./build/maze_ref"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
rule() { printf '\033[2m%s\033[0m\n' "------------------------------------------------------------"; }
pause() { printf '\033[1;93m%s\033[0m' "  >> press Enter to continue..."; read -r _; }

clear
bold "CM-203 Project 2 -- AArch64 Maze Runner"
rule
cat <<'EOF'
  A maze solver written in PURE A64 assembly.
    * each cell is one byte; walls + state are individual BITS
    * movement uses SIGNED deltas (two's complement, sign-extended)
    * the solver is a RECURSIVE depth-first search --
      and the CALL STACK you see on screen IS the path it is walking.
EOF
echo
pause

clear
bold "[1/4]  Solve the maze  (watch the call stack grow and shrink)"
rule
echo "  Watch the HUD: 'stack depth' is the live recursion depth, and"
echo "  'call stack' lists the frames -- on a dead end the runner walks BACK."
echo
pause
MAZE_DELAY="${MAZE_DELAY:-55}" $RUN "$BIN"
echo
echo "  ^ It explored, backtracked at dead ends, and highlighted the path in green."
echo "  Exit code (0 = solved): $?"
pause

clear
bold "[2/4]  An UNSOLVABLE maze  (the goal is walled off on all sides)"
rule
echo "  Same code, different data. It searches everywhere, finds nothing,"
echo "  and reports failure through the process EXIT CODE."
echo
pause
$RUN "$BIN" 1
ec=$?
echo
printf "  Exit code (1 = no path): \033[1;91m%s\033[0m\n" "$ec"
pause

clear
bold "[3/4]  Is the assembly CORRECT?  Check it against a C reference"
rule
echo "  Both solvers share the SAME maze bytes and SAME search order, then"
echo "  print the same canonical line. We diff them for every maze."
echo
a0=$(MAZE_ANIM=0 $RUN "$BIN");     ae0=$?
c0=$(MAZE_ANIM=0 $RUN "$REF");     ce0=$?
a1=$(MAZE_ANIM=0 $RUN "$BIN" 1);   ae1=$?
c1=$(MAZE_ANIM=0 $RUN "$REF" 1);   ce1=$?
echo "  solvable maze:"
echo "    A64: $a0   (exit $ae0)"
echo "    C  : $c0   (exit $ce0)"
echo "  unsolvable maze:"
echo "    A64: '$a1'   (exit $ae1)"
echo "    C  : '$c1'   (exit $ce1)"
echo
if [ "$a0" = "$c0" ] && [ "$a1" = "$c1" ] && [ "$ae0" = 0 ] && [ "$ae1" = 1 ]; then
  printf '  \033[1;92mRESULT: PASS -- the A64 solver matches the C reference.\033[0m\n'
else
  printf '  \033[1;91mRESULT: FAIL\033[0m\n'
fi
pause

clear
bold "[4/4]  The recursion, under the debugger (optional, live)"
rule
cat <<'EOF'
  In another step you can show the real machine stack:

      make debug
      (gdb) break solve
      (gdb) run
      (gdb) bt                 # each frame = one cell on the current trail
      (gdb) info reg x19 x20   # this frame's row / col
      (gdb) continue

  The gdb backtrace and the on-screen "call stack" are the same thing:
  the AAPCS64 stack frames saved by stp x29,x30 / restored by ldp ... ret.
EOF
echo
bold "Done. Thanks!"
