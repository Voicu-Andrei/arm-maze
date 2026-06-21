#!/usr/bin/env bash
# ============================================================================
# demo.sh -- guided, paused walkthrough of the A64 maze runner for the talk.
# Run it with:  make demo     (or directly: ./demo.sh)
# On the Pi leave RUN empty.  Off-Pi:  RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu" ./demo.sh
#
# Stages map onto 3 speakers:
#   Speaker 1  -> [1] data & bits        (Chapter 4)
#   Speaker 2  -> [2] solve & call stack (Chapter 9) + [3] unsolvable
#   Speaker 3  -> [4] verify vs C        + [5] gdb on the real stack
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
    * each cell is one BYTE; walls + state are individual BITS
    * movement uses SIGNED deltas (two's complement, sign-extended)
    * the solver is a RECURSIVE depth-first search --
      and the CALL STACK you see on screen IS the path it is walking.
EOF
echo
pause

# ---------------------------------------------------------------- SPEAKER 1 --
clear
bold "[1/5]  SPEAKER 1 -- the DATA: a maze is just bytes and bits  (Chapter 4)"
rule
echo "  First, the whole maze as raw bytes -- 64 of them, one per cell:"
echo
$RUN "$BIN" bytes
pause
clear
bold "[1/5]  ... and what the bits inside one byte mean"
rule
$RUN "$BIN" bits
pause
clear
bold "[1/5]  ... and the SIGNED move deltas (two's complement + sign extension)"
rule
$RUN "$BIN" deltas
echo
echo "  ldrsb turns the byte 0xFF into -1; that is how a north step subtracts 1."
pause

# ---------------------------------------------------------------- SPEAKER 2 --
clear
bold "[2/5]  SPEAKER 2 -- the SEARCH: watch the call stack grow and shrink"
rule
echo "  HUD: 'stack depth' is the live recursion depth; 'call stack' lists the"
echo "  live solve() frames; 'runner cell' shows that cell's byte in BINARY"
echo "  (watch the seen bit flip 0->1 on entry, path bit on the way back)."
echo "  On a dead end the runner walks BACK -- that is ldp .. ret popping a frame."
echo
pause
MAZE_DELAY="${MAZE_DELAY:-55}" $RUN "$BIN"
echo
echo "  Explored, backtracked, highlighted the path in green.  Exit code: $?"
pause

clear
bold "[3/5]  SPEAKER 2 -- an UNSOLVABLE maze  (goal walled off on all sides)"
rule
echo "  Same assembly, different DATA. It searches everywhere, finds nothing,"
echo "  and reports failure through the process EXIT CODE."
echo
pause
$RUN "$BIN" 1
ec=$?
echo
printf "  Exit code (1 = no path): \033[1;91m%s\033[0m\n" "$ec"
pause

# ---------------------------------------------------------------- SPEAKER 3 --
clear
bold "[4/5]  SPEAKER 3 -- is it CORRECT?  diff the A64 against a C reference"
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
bold "[5/5]  SPEAKER 3 -- the recursion under the debugger (live)"
rule
cat <<'EOF'
  Show the REAL machine stack and tie it to the on-screen "call stack":

      make debug
      (gdb) break solve
      (gdb) run
      (gdb) bt                 # each frame = one cell on the current trail
      (gdb) info reg x19 x20   # this frame's row / col
      (gdb) continue           # step the recursion; watch bt grow / shrink

  The gdb backtrace and the HUD "call stack" are the same thing: the AAPCS64
  frames saved by  stp x29,x30  and restored by  ldp .. ret.
EOF
echo
bold "Done. Thanks!"
