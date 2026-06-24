#!/usr/bin/env bash
# ============================================================================
# demo.sh -- ONE combined, NAVIGABLE presentation of the A64 maze runner.
# Merges the behaviour demo AND the assembly deep dive, split across 3 speakers
# and balanced by time (the slow solve alone is ~2 min).
#
#   Navigation at every slide:
#     [Enter] / n   next slide
#     b / p         back to the previous slide
#     r             replay this slide (re-run the maze, re-show the view)
#     q             quit
#
#   Input is flushed before each prompt, so keystrokes pressed WHILE the maze is
#   solving do NOT skip ahead -- a finished maze waits for a fresh keypress.
#
#   Speaker 1  "It's bytes and bits"   ~3:00   Chapter 4
#   Speaker 2  "Watch it think"        ~3:25   the search  (includes SLOW solve)
#   Speaker 3  "Down to the metal"     ~3:30   Chapter 9 / AAPCS64
#
# Run with:  make demo      (leave RUN empty on the Pi)
# ============================================================================
set -u
CC="${CC:-gcc}"
OBJDUMP="${OBJDUMP:-objdump}"
GDB="${GDB:-gdb}"
RUN="${RUN:-}"
SOLVE_DELAY="${MAZE_DELAY:-130}"        # the SLOW maze solver for the demo
BIN="build/maze"
REF="build/maze_ref"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
dim()  { printf '\033[2m%s\033[0m\n' "$1"; }
rule() { dim "----------------------------------------------------------------"; }

# Slide header with its budgeted time.
head_() {          # $1="S1 1/3"  $2=title  $3=~time
  clear
  printf '\033[1m[%s · ~%s]  %s\033[0m\n' "$1" "$3" "$2"
  rule
}

# Big hand-off card between speakers.
card() {           # $1=number  $2=title  $3=time  $4=slides-summary
  clear
  echo
  printf '\033[1;96m  ============================================================\033[0m\n'
  printf '\033[1;96m   SPEAKER %s   --   %s\033[0m\n' "$1" "$2"
  printf '\033[1;96m  ============================================================\033[0m\n\n'
  printf '   your segment: \033[1m%s\033[0m\n\n' "$3"
  printf '%s\n' "$4"
  echo
  printf '\033[1;93m   Speaker %s -- you are up.\033[0m\n' "$1"
}

# ---------------------------------------------------------------- SLIDES -----
# Each slide is a function that only RENDERS (no waiting); the main loop handles
# navigation, so you can go back/forward/replay freely.

s_title() {
  clear
  bold "CM-203 Project 2  --  AArch64 Maze Runner"
  rule
  cat <<'EOF'
  A maze solver written in PURE A64 assembly, running native on the Pi.

  Three speakers, no slides -- this program IS the presentation:
    1. the DATA   -- a maze is just bytes, and bits inside those bytes
    2. the SEARCH -- a recursive solver whose CALL STACK is the path
    3. the METAL  -- the real machine code + the live stack frames

  Thesis to remember: the recursion you watch on screen IS the call stack.
EOF
}

c_s1() { card "1" "It's all bytes and bits  (Chapter 4)" "~3:00, 3 slides" \
"   1) the maze as 64 raw bytes
   2) the bits inside one byte (walls + state)
   3) signed move deltas: two's complement + sign extension"; }

s1_bytes() {
  head_ "S1 1/3" "A maze is just DATA -- 64 bytes" "45s"
  echo "  The whole maze lives in .data: one byte per cell, row-major."
  echo "  Address of a cell = base + row*8 + col  (that is the 'madd' instruction)."
  echo
  $RUN "$BIN" bytes
}

s1_bits() {
  head_ "S1 2/3" "Inside ONE byte: walls + state, as bits" "55s"
  echo "  Low nibble = the 4 walls (N/E/S/W); high nibble = state flags."
  echo "  Reading a wall is ldrb + and with a mask; setting 'seen' is ldrb/orr/strb."
  echo
  $RUN "$BIN" bits
}

s1_deltas() {
  head_ "S1 3/3" "Signed deltas: two's complement & sign extension" "50s"
  echo "  Moving north is row -1. As a byte that is 1111 1111 (two's complement)."
  echo "  ldrsb SIGN-EXTENDS it to 0xFFFFFFFF, so the add really subtracts 1."
  echo "  (Use ldrb instead and you would get 255 -- the wrong way.)"
  echo
  $RUN "$BIN" deltas
}

c_s2() { card "2" "Watch it think  (the search)" "~3:25, 3 slides" \
"   1) the SLOW animated solve (the centrepiece)
   2) an unsolvable maze -> exit code 1
   3) prove it is correct against a C reference"; }

s2_solve_intro() {
  head_ "S2 1/3" "The slow solve -- what to watch (read, then advance to run it)" "intro"
  cat <<'EOF'
  Talking points for while it runs (next slide plays the maze):
    * 'stack depth'  = the live recursion depth (copies of solve on the stack)
    * 'call stack'   = the live frames, start -> runner.  THIS LIST IS THE PATH.
    * 'runner cell'  = that cell's byte in BINARY -- watch the 'seen' bit flip
    * dead end -> solve returns, frame pops, runner WALKS BACK  (ldp .. ret)
    * goal -> the green path lights up from the goal back to the start

  Press Enter to start the solve.  (When it finishes it WAITS -- it will not
  skip ahead; press 'r' to replay it, or Enter to move on.)
EOF
}

s2_solve_run() {
  MAZE_DELAY="$SOLVE_DELAY" $RUN "$BIN"
  local rc=$?
  echo
  echo "  Explored, backtracked, highlighted the path in green.  Exit code: $rc"
}

s2_unsolvable() {
  head_ "S2 2/3" "An UNSOLVABLE maze -- goal walled off" "50s"
  echo "  Same assembly, different DATA. It searches everywhere, finds nothing,"
  echo "  and reports failure through the process EXIT CODE."
  echo "  (Press Enter to run; it waits when done.)"
  echo
  MAZE_DELAY="$SOLVE_DELAY" $RUN "$BIN" 1
  local ec=$?
  echo
  printf "  Exit code (1 = no path): \033[1;91m%s\033[0m\n" "$ec"
}

s2_verify() {
  head_ "S2 3/3" "Is it CORRECT? diff A64 vs a C reference" "35s"
  echo "  Both solvers share the SAME maze bytes and SAME search order."
  echo
  local a0 c0 a1 c1 ae0 ce0 ae1 ce1
  a0=$(MAZE_ANIM=0 $RUN "$BIN");     ae0=$?
  c0=$(MAZE_ANIM=0 $RUN "$REF");     ce0=$?
  a1=$(MAZE_ANIM=0 $RUN "$BIN" 1);   ae1=$?
  c1=$(MAZE_ANIM=0 $RUN "$REF" 1);   ce1=$?
  echo "  solvable:    A64 $a0  (exit $ae0)"
  echo "               C   $c0  (exit $ce0)"
  echo "  unsolvable:  A64 '$a1' (exit $ae1)   C '$c1' (exit $ce1)"
  echo
  if [ "$a0" = "$c0" ] && [ "$a1" = "$c1" ] && [ "$ae0" = 0 ] && [ "$ae1" = 1 ]; then
    printf '  \033[1;92mRESULT: PASS -- the A64 solver matches the C reference.\033[0m\n'
  else
    printf '  \033[1;91mRESULT: FAIL\033[0m\n'
  fi
}

c_s3() { card "3" "Down to the metal  (Chapter 9 / AAPCS64)" "~3:30, 4 slides" \
"   1) the calling-convention register roles
   2) a whole routine as REAL encoded instructions
   3) the prologue/epilogue that make recursion work
   4) live: the actual stack frames stacking up"; }

s3_regs() {
  head_ "S3 1/4" "AAPCS64 register roles (the contract)" "45s"
  cat <<'EOF'
  x0 - x7    arguments / return values        (caller-saved)
  x19 - x28  callee-saved  <- preserved across calls, so we keep
                               row/col/dir here across the recursion
  x29 (fp)   frame pointer   -- this call's saved frame
  x30 (lr)   link register   -- where 'ret' returns to (set by 'bl')
  sp         stack pointer   -- 16-byte aligned, grows DOWN

  Recursion works because each solve() call saves its OWN x30 and
  x19-x24 in its OWN stack frame.
EOF
}

s3_move() {
  head_ "S3 2/4" "A whole routine as real machine code: move()" "45s"
  echo "  Source comments interleaved with the encoded instructions."
  echo "  Note 'ldrsb' -- the sign-extending load from Speaker 1, for real:"
  echo
  $OBJDUMP -S --disassemble=move "$BIN" 2>/dev/null | sed -n '/<move>:/,/^$/p'
}

s3_solveasm() {
  head_ "S3 3/4" "The calling convention inside solve()" "50s"
  echo "  Just the frame + branch instructions of the recursive routine:"
  echo
  $OBJDUMP -d --disassemble=solve "$BIN" 2>/dev/null \
    | grep -E '\b(stp|ldp|bl|ret)\b' | sed 's/^/    /'
  cat <<'EOF'

    stp x29, x30, [sp, #-64]!   prologue: push frame, save FP + return addr
    bl  <solve>                 the RECURSION: it branches to its OWN address
    ldp x29, x30, [sp], #64     epilogue: restore the frame ...
    ret                         ... and jump back to the saved return address
EOF
}

s3_trace() {
  head_ "S3 4/4" "LIVE: watch the real stack frames stack up" "55s"
  echo "  Stepping into the recursion under gdb. Watch x29/sp drop by 0x40 = 64"
  echo "  bytes (one frame) per level, then a backtrace of nested solve() frames."
  echo
  $GDB -q -batch -x trace.gdb "./$BIN" 2>/dev/null
  echo
  bold "  That backtrace IS the on-screen 'call stack' -- the same frames, for real."
}

s_wrap() {
  clear
  bold "Wrap-up"
  rule
  cat <<'EOF'
  One byte per cell, bits for the walls, signed deltas with sign extension,
  and a recursive DFS where the CALL STACK is the path -- written in pure A64,
  verified against C, running native on the Pi.

  Thanks!
EOF
}

# Ordered list of slides (cards are slides too, so you can step back into them).
SLIDES=(
  s_title
  c_s1 s1_bytes s1_bits s1_deltas
  c_s2 s2_solve_intro s2_solve_run s2_unsolvable s2_verify
  c_s3 s3_regs s3_move s3_solveasm s3_trace
  s_wrap
)

# Drain any input buffered while the maze was animating, so a finished maze does
# NOT auto-skip the next prompt.  (Only meaningful on a real terminal.)
flush_input() {
  [ -t 0 ] || return 0
  local junk
  while read -r -t 0.1 -n 256 junk 2>/dev/null; do :; done
}

# ---- build everything the demo needs (a -g binary for disasm/trace) ---------
mkdir -p build
printf 'building (with debug symbols for the assembly section)...\n'
$CC -g src/maze.S -o "$BIN"            || { echo "build of maze failed"; exit 1; }
$CC -Wall -O2 src/maze_ref.c -o "$REF" || { echo "build of maze_ref failed"; exit 1; }

# ---- navigation loop --------------------------------------------------------
i=0
n=${#SLIDES[@]}
while [ "$i" -lt "$n" ]; do
  "${SLIDES[$i]}"                       # render the current slide
  flush_input                           # discard keystrokes from during the maze
  printf '\n\033[2m  slide %d/%d\033[0m   \033[1;93m[Enter] next   [b] back   [r] replay   [q] quit \033[0m> ' \
         "$((i + 1))" "$n"
  if ! IFS= read -r nav; then nav="q"; fi   # EOF (piped) -> quit
  case "$nav" in
    b|B|p|P)  [ "$i" -gt 0 ] && i=$((i - 1)) ;;   # go back
    r|R)      : ;;                                 # replay (stay on same slide)
    q|Q)      break ;;
    *)        i=$((i + 1)) ;;                       # Enter / anything else -> next
  esac
done

clear
dim "demo ended."
