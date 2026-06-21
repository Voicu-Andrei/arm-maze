#!/usr/bin/env bash
# ============================================================================
# asm-tour.sh -- a guided, paused DEEP DIVE into the assembly itself.
# Run it with:  make asm-tour    (or directly: ./asm-tour.sh)
#
# It walks through: the AAPCS64 register roles, a whole routine compiled down to
# real encoded instructions, the prologue/epilogue that make recursion work, and
# a live debugger trace of the stack frames stacking up.
#
# Honours env overrides (for off-Pi testing):
#   CC, OBJDUMP, GDB  (default: gcc, objdump, gdb)
# ============================================================================
set -u
CC="${CC:-gcc}"
OBJDUMP="${OBJDUMP:-objdump}"
GDB="${GDB:-gdb}"
BIN="build/maze"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
dim()  { printf '\033[2m%s\033[0m\n' "$1"; }
rule() { dim "------------------------------------------------------------"; }
pause(){ printf '\033[1;93m%s\033[0m' "  >> press Enter to continue..."; read -r _; }

# need a -g build for source-interleaved disassembly and tidy gdb line info
mkdir -p build
$CC -g src/maze.S -o "$BIN" || { echo "build failed"; exit 1; }

clear
bold "ASSEMBLY DEEP DIVE -- the A64, up close"
rule
cat <<'EOF'
  We will look at the actual machine code, not just the source:
    1. the AAPCS64 register roles we rely on
    2. one whole routine compiled to real instructions
    3. the prologue/epilogue that make recursion possible
    4. a live debugger trace of the stack frames stacking up
EOF
echo
pause

clear
bold "[1/4]  AAPCS64 register roles  (the calling-convention contract)"
rule
cat <<'EOF'
  x0 - x7    argument / return registers   (caller-saved)
  x8 - x18   scratch / temporaries         (caller-saved)
  x19 - x28  callee-saved   <- a function must preserve these across calls,
                                so we keep row/col/dir here across recursion
  x29 (fp)   frame pointer  -- points at this call's saved frame
  x30 (lr)   link register  -- where 'ret' jumps back to (set by 'bl')
  sp         stack pointer  -- 16-byte aligned; grows DOWN

  Recursion works because every solve() call saves its OWN x30 (return
  address) and x19-x24 (its row/col/etc) in its OWN stack frame.
EOF
echo
pause

clear
bold "[2/4]  A whole routine, compiled to real instructions:  move()"
rule
echo "  Source comments are interleaved with the encoded machine code."
echo "  Note 'ldrsb' -- it SIGN-EXTENDS the signed delta byte (the -1 path)."
echo
$OBJDUMP -S --disassemble=move "$BIN" 2>/dev/null \
  | sed -n '/<move>:/,/^$/p'
echo
pause

clear
bold "[3/4]  The calling convention inside solve()  (prologue / call / epilogue)"
rule
echo "  Just the frame + branch instructions of the recursive routine:"
echo
$OBJDUMP -d --disassemble=solve "$BIN" 2>/dev/null \
  | grep -E '\b(stp|ldp|bl|ret)\b' \
  | sed 's/^/    /'
echo
cat <<'EOF'
  Reading it:
    stp x29, x30, [sp, #-64]!   prologue: push frame, save FP + return addr
    stp x19..x24, ...           save the callee-saved regs we will use
    bl  solve                   <-- the RECURSION (saves x30 = where to return)
    ldp x19..x24 / x29, x30     epilogue: restore everything
    ret                         jump back to the saved x30 (the parent frame)
EOF
echo
pause

clear
bold "[4/4]  Live: watch the stack frames stack up  (debugger trace)"
rule
echo "  Stepping a few levels into the recursion. Watch x29 / sp drop by"
echo "  0x40 = 64 bytes (one frame) per level, then a real backtrace."
echo
pause
$GDB -q -batch -x trace.gdb "./$BIN" 2>/dev/null
echo
bold "That backtrace is the same recursion you see in the on-screen call stack."
bold "Done."
