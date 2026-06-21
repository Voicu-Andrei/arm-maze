/* ============================================================================
 * maze.s  --  AArch64 / A64 recursive maze solver with animated terminal render
 *
 * CM-203 Project 2.  Pure A64, AAPCS64 calling convention, assembled by the GNU
 * toolchain.  This file is a ".S" (capital S) so the C preprocessor runs first
 * and lets us #include the shared maze geometry.  (Because cpp runs, NO assembly
 * line may begin with '#'; mid-line immediates like `mov w0, #1` are fine.)
 *
 * Demonstrates:
 *   - Ch.4 Binary/Data: one byte per cell, walls & state packed into individual
 *     BITS (and/orr/bic masks), SIGNED movement deltas with SIGN EXTENSION.
 *   - Ch.9 A64: ldrb/strb, scaled addressing (madd), cmp + b.cond / cbz / cbnz,
 *     and a genuinely RECURSIVE depth-first search whose call stack IS the path
 *     (stp/ldp prologue/epilogue, x30, AAPCS64 stack frame).
 *
 * SHOWCASE INTERFACE: the renderer draws the maze in colour AND a live readout
 * of the recursion -- "stack depth", the running "call stack" of cells, cells
 * visited, and backtracks -- so the audience literally watches the AAPCS64 call
 * stack grow and shrink.  On a dead end the runner walks back (a frame is drawn
 * after each pop) so backtracking is visible.
 *
 * libc is called for I/O and timing (putchar, getenv, atoi, fflush, usleep) --
 * all NON-variadic, per the project's "no printf from asm" guidance.
 * ==========================================================================*/

    .arch armv8-a

/* Pull in MAZE_W/MAZE_H, START/GOAL, and the MAZE_BYTES / MAZE2_BYTES tables.
 * Same header the C reference includes -> the two can never disagree.        */
#include "maze_data.h"

/* ---- cell-byte bit masks (mirror the table in maze_data.h / README) ------ */
    .equ  WALL_N, 0x01
    .equ  WALL_E, 0x02
    .equ  WALL_S, 0x04
    .equ  WALL_W, 0x08
    .equ  F_SEEN, 0x10
    .equ  F_PATH, 0x20
    .equ  F_START,0x40
    .equ  F_GOAL, 0x80
    .equ  TRAIL_TAIL, 6          /* show at most this many recent stack cells  */

/* ===========================================================================
 * Read-only data
 * ==========================================================================*/
    .section .rodata
    .align 3
/* Signed per-direction deltas, order N,E,S,W.  These are SIGNED bytes: note the
 * -1 entries -- loading them with ldrsb sign-extends (two's complement) before
 * we add them to a coordinate.  (South is +1 row, 0 col -- the corrected §4.)  */
drow_tab:  .byte  -1,  0,  1,  0      /* N=-1  E=0  S=+1  W=0   */
dcol_tab:  .byte   0,  1,  0, -1      /* N=0   E=+1 S=0    W=-1 */
wall_tab:  .byte  WALL_N, WALL_E, WALL_S, WALL_W

str_clear: .asciz "\033[2J\033[H"     /* ANSI: clear screen + cursor home      */
str_env:   .asciz "MAZE_ANIM"         /* set MAZE_ANIM=0 to disable animation  */
str_envcol:.asciz "MAZE_COLOR"        /* set MAZE_COLOR=0 to disable colour     */
str_envdly:.asciz "MAZE_DELAY"        /* per-step delay in ms (default 45)      */
str_path:  .asciz "path:"             /* canonical machine-checked output line  */

/* ANSI colour codes (only emitted when colour is enabled) */
c_reset:   .asciz "\033[0m"
c_runner:  .asciz "\033[1;96m"        /* bright cyan  -> R (current cell)       */
c_path:    .asciz "\033[1;92m"        /* bright green -> * (solution path)      */
c_seen:    .asciz "\033[90m"          /* grey         -> . (visited/backtracked)*/
c_start:   .asciz "\033[1;93m"        /* bright yellow-> S                       */
c_goal:    .asciz "\033[1;95m"        /* bright magenta->G                       */
c_ok:      .asciz "\033[1;92m"        /* SOLVED!  in green                       */
c_no:      .asciz "\033[1;91m"        /* NO PATH  in red                         */
c_hud:     .asciz "\033[1m"           /* bold for the HUD numbers                */

/* HUD label strings */
str_vis:   .asciz "  cells visited: "
str_dep:   .asciz "    stack depth: "
str_back:  .asciz "    backtracks: "
str_stk:   .asciz "  call stack:  "
str_arrow: .asciz " -> "
str_dots:  .asciz "..."
str_stat:  .asciz "  status: "
str_search:.asciz "searching..."
str_solved:.asciz "SOLVED!  (path found)"
str_nopath:.asciz "NO PATH  (maze is unsolvable)"
str_legend:.asciz "  legend:  R runner   * path   . visited   S start   G goal"

/* ---- strings for the bit-inspection sub-commands -------------------------- */
sc_bits:   .asciz "bits"
sc_bytes:  .asciz "bytes"
sc_deltas: .asciz "deltas"
str_dirs:  .asciz "NESW"
hdr_bits:  .asciz "CELL BYTE FORMAT  --  one byte per cell, eight bits\n\n  bit:    7      6      5     4      3    2    1    0\n  mean:  goal  start  path  seen    W    S    E    N\n         \\------- state -------/    \\----- walls -----/\n\nDecoding real cells straight from the maze bytes:\n\n"
hdr_bytes: .asciz "MAZE AS RAW BYTES  --  .data, row-major, 64 bytes total\n\n"
bv_cols:   .asciz "        c0   c1   c2   c3   c4   c5   c6   c7\n"
bv_rpfx:   .asciz "  r"
bv_gap:    .asciz "   "
bv_foot:   .asciz "\n  (each byte = walls in the low nibble, state flags in the high nibble)\n"
hdr_delta: .asciz "SIGNED MOVEMENT DELTAS  --  two's complement & sign extension\n  order N, E, S, W;  deltas are signed bytes stored in .rodata\n\n  dir   drow  dcol     drow byte     ldrsb -> 32-bit\n"
dl_foot:   .asciz "\n  ldrsb sign-extends bit 7 across the whole register (0xFF -> -1),\n  while ldrb would zero-extend (0xFF -> 255).  Sign extension is what\n  makes a north/west step (delta -1) actually subtract 1 from the index.\n"
lbl_walls: .asciz "        walls:  N="
lbl_e:     .asciz "  E="
lbl_s:     .asciz "  S="
lbl_w:     .asciz "  W="
lbl_state: .asciz "        state:  seen="
lbl_path:  .asciz "  path="
lbl_start: .asciz "  start="
lbl_goal:  .asciz "  goal="
cb_run:    .asciz "  runner cell ("
cb_byte:   .asciz "):  byte = 0x"
cb_seen:   .asciz "    seen="
cb_pathb:  .asciz "  path="
dl_d1:     .asciz "    "
dl_d2:     .asciz "     "
dl_d3:     .asciz "      0x"

/* ===========================================================================
 * Mutable data  (the grids are written in place: seen/path bits get set)
 * ==========================================================================*/
    .section .data
    .align 3
grid0:     .byte MAZE_BYTES           /* solvable maze (default)               */
grid1:     .byte MAZE2_BYTES          /* goal sealed off -> unsolvable         */
    .align 3
grid_base: .quad 0                    /* -> active grid, chosen in main        */
cur_r:     .byte 0                    /* runner's current row (for render 'R') */
cur_c:     .byte 0                    /* runner's current col                  */
g_anim:    .byte 1                    /* 1 = animate, 0 = quiet (verify mode)  */
g_color:   .byte 1                    /* 1 = ANSI colour, 0 = plain            */
    .align 2
g_steps:   .word 0                    /* cells entered (visited)               */
g_depth:   .word 0                    /* CURRENT recursion depth = live frames */
g_maxdepth:.word 0                    /* high-water mark of the stack          */
g_back:    .word 0                    /* number of dead-end backtracks         */
g_state:   .word 0                    /* 0 searching, 1 solved, 2 no-path      */
g_delay_us:.word 45000                /* per-frame sleep, microseconds         */
/* explicit mirror of the call stack: (row,col) pair per live frame, for the HUD */
g_stack:   .zero  MAZE_W * MAZE_H * 2

/* ===========================================================================
 * Text
 * ==========================================================================*/
    .text

/* ---------------------------------------------------------------------------
 * cell_addr(w0=row, w1=col) -> x0 = &grid[row*MAZE_W + col]
 * Scaled addressing via madd: index = row*WIDTH + col, then add the base.
 * ------------------------------------------------------------------------- */
    .type cell_addr, %function
cell_addr:
    adrp  x3, grid_base               // x3 = page of grid_base (PC-relative)
    add   x3, x3, :lo12:grid_base     //   + low 12 bits -> &grid_base
    ldr   x3, [x3]                    // x3 = base pointer to the active grid
    mov   w4, #MAZE_W                 // w4 = width (row stride in bytes)
    madd  w2, w0, w4, w1              // w2 = row*WIDTH + col   (one multiply-add)
    add   x0, x3, w2, uxtw            // x0 = base + index (zero-extend the index)
    ret
    .size cell_addr, .-cell_addr

/* ---------------------------------------------------------------------------
 * is_set(x0=cell_addr, w1=mask) -> w0 = 1 if (cell & mask)!=0 else 0
 * The canonical "read one bit": load the byte, AND with a mask, branch.
 * ------------------------------------------------------------------------- */
    .type is_set, %function
is_set:
    ldrb  w2, [x0]                    // load the 1 cell byte into w2
    and   w2, w2, w1                  // keep only the masked bit(s)
    cmp   w2, #0                      // were any of them set?
    cset  w0, ne                      // w0 = (result != 0) ? 1 : 0
    ret
    .size is_set, .-is_set

    .type wall_blocked, %function
wall_blocked:
    b     is_set                      // "is this direction walled?" -> read bit
    .size wall_blocked, .-wall_blocked

/* ---------------------------------------------------------------------------
 * mark(x0=cell_addr, w1=mask)   set flag bits  -- read / modify / write
 * ------------------------------------------------------------------------- */
    .type mark, %function
mark:
    ldrb  w2, [x0]                    // read current cell byte
    orr   w2, w2, w1                  // turn ON the requested bit(s)
    strb  w2, [x0]                    // write it back
    ret
    .size mark, .-mark

/* ---------------------------------------------------------------------------
 * unmark(x0=cell_addr, w1=mask)   clear flag bits  -- ldrb -> bic -> strb
 * ------------------------------------------------------------------------- */
    .type unmark, %function
unmark:
    ldrb  w2, [x0]                    // read current cell byte
    bic   w2, w2, w1                  // BIt-Clear: turn OFF the masked bit(s)
    strb  w2, [x0]                    // write it back
    ret
    .size unmark, .-unmark

/* ---------------------------------------------------------------------------
 * in_bounds(w0=row, w1=col) -> w0 = 1 if 0<=row<H and 0<=col<W else 0
 * SIGNED compares (b.lt) so a -1 from a north/west step fails cleanly.
 * ------------------------------------------------------------------------- */
    .type in_bounds, %function
in_bounds:
    cmp   w0, #0
    b.lt  .Loob
    cmp   w0, #MAZE_H
    b.ge  .Loob
    cmp   w1, #0
    b.lt  .Loob
    cmp   w1, #MAZE_W
    b.ge  .Loob
    mov   w0, #1
    ret
.Loob:
    mov   w0, #0
    ret
    .size in_bounds, .-in_bounds

/* ---------------------------------------------------------------------------
 * move(w0=row, w1=col, w2=dir) -> (w0=new_row, w1=new_col)
 * SIGNED delta with SIGN EXTENSION (ldrsb) -- the required signed path.
 * ------------------------------------------------------------------------- */
    .type move, %function
move:
    adrp  x3, drow_tab
    add   x3, x3, :lo12:drow_tab
    ldrsb w4, [x3, w2, sxtw]          // w4 = drow[dir], SIGN-EXTENDED (-1 stays -1)
    adrp  x5, dcol_tab
    add   x5, x5, :lo12:dcol_tab
    ldrsb w5, [x5, w2, sxtw]          // w5 = dcol[dir], sign-extended
    add   w0, w0, w4                  // new_row = row + drow   (signed add)
    add   w1, w1, w5                  // new_col = col + dcol
    ret
    .size move, .-move

/* ---------------------------------------------------------------------------
 * emit_str(x0 = NUL-terminated string)   write a string a byte at a time.
 * ------------------------------------------------------------------------- */
    .type emit_str, %function
emit_str:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    str   x19, [sp, #16]
    mov   x19, x0                     // x19 = current character pointer
.Les_loop:
    ldrb  w0, [x19]                   // load next byte
    cbz   w0, .Les_done               // NUL terminator -> stop
    bl    putchar
    add   x19, x19, #1
    b     .Les_loop
.Les_done:
    ldr   x19, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size emit_str, .-emit_str

/* ---------------------------------------------------------------------------
 * emit_uint(w0 = unsigned value)   print a number in decimal.
 * Itself RECURSIVE (print high digits, then this one) -- a second small example
 * of the call stack at work.
 * ------------------------------------------------------------------------- */
    .type emit_uint, %function
emit_uint:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    str   x19, [sp, #16]
    mov   w19, w0                     // w19 = n  (preserved across recursion)
    mov   w1, #10
    udiv  w2, w19, w1                 // w2 = n / 10
    cbz   w2, .Lu_print               // no high digits -> just print the last
    mov   w0, w2
    bl    emit_uint                   // recurse to print the high-order digits
.Lu_print:
    mov   w1, #10
    udiv  w2, w19, w1                 // recompute n/10 (w2 was clobbered)
    msub  w0, w2, w1, w19             // w0 = n - (n/10)*10 = n % 10
    add   w0, w0, #'0'                // ASCII digit
    bl    putchar
    ldr   x19, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size emit_uint, .-emit_uint

/* ---------------------------------------------------------------------------
 * set_color(x0=color string)  /  reset_color()
 * Emit an ANSI code only when colour is enabled (g_color!=0).
 * ------------------------------------------------------------------------- */
    .type set_color, %function
set_color:
    adrp  x1, g_color
    add   x1, x1, :lo12:g_color
    ldrb  w1, [x1]
    cbz   w1, .Lsc_off                // colour disabled -> do nothing
    b     emit_str                    // tail-call emit_str(x0)
.Lsc_off:
    ret
    .size set_color, .-set_color

    .type reset_color, %function
reset_color:
    adrp  x1, g_color
    add   x1, x1, :lo12:g_color
    ldrb  w1, [x1]
    cbz   w1, .Lrc_off
    adrp  x0, c_reset
    add   x0, x0, :lo12:c_reset
    b     emit_str
.Lrc_off:
    ret
    .size reset_color, .-reset_color

/* ---------------------------------------------------------------------------
 * glyph_for(w0=row, w1=col, w2=cellbyte) -> w0 = display character
 * Priority: runner 'R' > start 'S' > goal 'G' > path '*' > seen '.' > ' '
 * ------------------------------------------------------------------------- */
    .type glyph_for, %function
glyph_for:
    adrp  x3, cur_r
    add   x3, x3, :lo12:cur_r
    ldrb  w3, [x3]
    adrp  x4, cur_c
    add   x4, x4, :lo12:cur_c
    ldrb  w4, [x4]
    cmp   w0, w3                      // this cell's row == runner row?
    b.ne  .Lg_start
    cmp   w1, w4                      // and col == runner col?
    b.ne  .Lg_start
    mov   w0, #'R'
    ret
.Lg_start:
    tst   w2, #F_START
    b.eq  .Lg_goal
    mov   w0, #'S'
    ret
.Lg_goal:
    tst   w2, #F_GOAL
    b.eq  .Lg_path
    mov   w0, #'G'
    ret
.Lg_path:
    tst   w2, #F_PATH
    b.eq  .Lg_seen
    mov   w0, #'*'
    ret
.Lg_seen:
    tst   w2, #F_SEEN
    b.eq  .Lg_blank
    mov   w0, #'.'
    ret
.Lg_blank:
    mov   w0, #' '
    ret
    .size glyph_for, .-glyph_for

/* ---------------------------------------------------------------------------
 * color_for(w0=glyph char) -> x0 = pointer to its ANSI colour string (leaf)
 * ------------------------------------------------------------------------- */
    .type color_for, %function
color_for:
    cmp   w0, #'R'
    b.eq  .Lcf_runner
    cmp   w0, #'*'
    b.eq  .Lcf_path
    cmp   w0, #'S'
    b.eq  .Lcf_start
    cmp   w0, #'G'
    b.eq  .Lcf_goal
    cmp   w0, #'.'
    b.eq  .Lcf_seen
    adrp  x0, c_reset                 // default: no colour
    add   x0, x0, :lo12:c_reset
    ret
.Lcf_runner: adrp x0, c_runner ; add x0, x0, :lo12:c_runner ; ret
.Lcf_path:   adrp x0, c_path   ; add x0, x0, :lo12:c_path   ; ret
.Lcf_start:  adrp x0, c_start  ; add x0, x0, :lo12:c_start  ; ret
.Lcf_goal:   adrp x0, c_goal   ; add x0, x0, :lo12:c_goal   ; ret
.Lcf_seen:   adrp x0, c_seen   ; add x0, x0, :lo12:c_seen   ; ret
    .size color_for, .-color_for

/* ---------------------------------------------------------------------------
 * put_glyph(w0=glyph char)   print it wrapped in its colour code.
 * ------------------------------------------------------------------------- */
    .type put_glyph, %function
put_glyph:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    str   x19, [sp, #16]
    mov   w19, w0                     // save the char
    bl    color_for                   // x0 = colour ptr for this glyph
    bl    set_color                   // emit colour (if enabled)
    mov   w0, w19                     // the glyph itself
    bl    putchar
    bl    reset_color                 // back to default
    ldr   x19, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size put_glyph, .-put_glyph

/* ---------------------------------------------------------------------------
 * push_cell(w0=row, w1=col)   record a new live frame for the HUD.
 *   g_stack[g_depth] = (row,col); g_depth++; track max; g_steps++.  (leaf)
 * pop_cell()                  drop the top live frame: g_depth--.   (leaf)
 * Neither touches w0..w1's callers' callee-saved regs.
 * ------------------------------------------------------------------------- */
    .type push_cell, %function
push_cell:
    adrp  x9, g_depth
    add   x9, x9, :lo12:g_depth
    ldr   w10, [x9]                   // w10 = current depth
    lsl   w11, w10, #1                // byte offset = depth * 2
    adrp  x12, g_stack
    add   x12, x12, :lo12:g_stack
    add   x12, x12, w11, uxtw
    strb  w0, [x12]                   // store row
    strb  w1, [x12, #1]              // store col
    add   w10, w10, #1               // depth++
    str   w10, [x9]
    adrp  x9, g_maxdepth             // track high-water mark
    add   x9, x9, :lo12:g_maxdepth
    ldr   w11, [x9]
    cmp   w10, w11
    csel  w11, w10, w11, gt
    str   w11, [x9]
    adrp  x9, g_steps               // cells visited++
    add   x9, x9, :lo12:g_steps
    ldr   w11, [x9]
    add   w11, w11, #1
    str   w11, [x9]
    ret
    .size push_cell, .-push_cell

    .type pop_cell, %function
pop_cell:
    adrp  x9, g_depth
    add   x9, x9, :lo12:g_depth
    ldr   w10, [x9]
    sub   w10, w10, #1               // depth--
    str   w10, [x9]
    ret
    .size pop_cell, .-pop_cell

/* ---------------------------------------------------------------------------
 * set_cur_from_top()   point the runner 'R' at the cell now on top of the
 * stack (the parent we just backed up into), so retreats are visible. (leaf)
 * ------------------------------------------------------------------------- */
    .type set_cur_from_top, %function
set_cur_from_top:
    adrp  x9, g_depth
    add   x9, x9, :lo12:g_depth
    ldr   w10, [x9]
    cmp   w10, #0
    b.le  .Lsct_done                 // empty stack -> leave runner where it is
    sub   w11, w10, #1
    lsl   w11, w11, #1
    adrp  x9, g_stack
    add   x9, x9, :lo12:g_stack
    add   x9, x9, w11, uxtw
    ldrb  w12, [x9]                  // parent row
    ldrb  w13, [x9, #1]             // parent col
    adrp  x9, cur_r
    add   x9, x9, :lo12:cur_r
    strb  w12, [x9]
    adrp  x9, cur_c
    add   x9, x9, :lo12:cur_c
    strb  w13, [x9]
.Lsct_done:
    ret
    .size set_cur_from_top, .-set_cur_from_top

/* ---------------------------------------------------------------------------
 * emit_status()   print "  status: <searching|SOLVED|NO PATH>" in colour.
 * ------------------------------------------------------------------------- */
    .type emit_status, %function
emit_status:
    stp   x29, x30, [sp, #-16]!
    mov   x29, sp
    adrp  x0, str_stat
    add   x0, x0, :lo12:str_stat
    bl    emit_str
    adrp  x0, g_state
    add   x0, x0, :lo12:g_state
    ldr   w1, [x0]
    cmp   w1, #1
    b.eq  .Lst_solved
    cmp   w1, #2
    b.eq  .Lst_nopath
    adrp  x0, str_search             // 0: searching
    add   x0, x0, :lo12:str_search
    bl    emit_str
    b     .Lst_done
.Lst_solved:
    adrp  x0, c_ok
    add   x0, x0, :lo12:c_ok
    bl    set_color
    adrp  x0, str_solved
    add   x0, x0, :lo12:str_solved
    bl    emit_str
    bl    reset_color
    b     .Lst_done
.Lst_nopath:
    adrp  x0, c_no
    add   x0, x0, :lo12:c_no
    bl    set_color
    adrp  x0, str_nopath
    add   x0, x0, :lo12:str_nopath
    bl    emit_str
    bl    reset_color
.Lst_done:
    ldp   x29, x30, [sp], #16
    ret
    .size emit_status, .-emit_status

/* ---------------------------------------------------------------------------
 * emit_stack_cell(w0=index)   print g_stack[index] as "(r,c)".
 * ------------------------------------------------------------------------- */
    .type emit_stack_cell, %function
emit_stack_cell:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    str   x19, [sp, #16]
    mov   w19, w0                    // index
    mov   w0, #'('
    bl    putchar
    lsl   w0, w19, #1                // row at g_stack[index*2]
    adrp  x1, g_stack
    add   x1, x1, :lo12:g_stack
    add   x1, x1, w0, uxtw
    ldrb  w0, [x1]
    bl    emit_uint
    mov   w0, #','
    bl    putchar
    lsl   w0, w19, #1                // col at g_stack[index*2 + 1]
    adrp  x1, g_stack
    add   x1, x1, :lo12:g_stack
    add   x1, x1, w0, uxtw
    ldrb  w0, [x1, #1]
    bl    emit_uint
    mov   w0, #')'
    bl    putchar
    ldr   x19, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size emit_stack_cell, .-emit_stack_cell

/* ---------------------------------------------------------------------------
 * emit_hud()   print the live recursion readout below the maze:
 *   cells visited / stack depth (cur/max) / backtracks
 *   call stack:  start -> (r,c) -> ... -> (r,c)     (last TRAIL_TAIL cells)
 *   status:  ...
 *   legend:  ...
 * Callee-saved used: w19=loop index, w20=depth(end), w21=printed-flag.
 * ------------------------------------------------------------------------- */
    .type emit_hud, %function
emit_hud:
    stp   x29, x30, [sp, #-48]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]

    adrp  x0, c_hud                  // bold for the numbers row
    add   x0, x0, :lo12:c_hud
    bl    set_color
    adrp  x0, str_vis                // "  cells visited: "
    add   x0, x0, :lo12:str_vis
    bl    emit_str
    adrp  x0, g_steps
    add   x0, x0, :lo12:g_steps
    ldr   w0, [x0]
    bl    emit_uint
    adrp  x0, str_dep                // "    stack depth: "
    add   x0, x0, :lo12:str_dep
    bl    emit_str
    adrp  x0, g_depth
    add   x0, x0, :lo12:g_depth
    ldr   w0, [x0]
    bl    emit_uint
    mov   w0, #'/'
    bl    putchar
    adrp  x0, g_maxdepth
    add   x0, x0, :lo12:g_maxdepth
    ldr   w0, [x0]
    bl    emit_uint
    adrp  x0, str_back               // "    backtracks: "
    add   x0, x0, :lo12:str_back
    bl    emit_str
    adrp  x0, g_back
    add   x0, x0, :lo12:g_back
    ldr   w0, [x0]
    bl    emit_uint
    bl    reset_color
    mov   w0, #'\n'
    bl    putchar

    /* ---- the live call-stack trail: root frame, then the most recent ------ */
    adrp  x0, str_stk                // "  call stack:  "
    add   x0, x0, :lo12:str_stk
    bl    emit_str
    adrp  x0, g_depth
    add   x0, x0, :lo12:g_depth
    ldr   w20, [x0]                  // w20 = depth
    mov   w0, #0                     // always show the root frame (start cell)
    bl    emit_stack_cell
    subs  w19, w20, #TRAIL_TAIL      // w19 = tail start = max(1, depth - TAIL)
    cmp   w19, #1
    b.ge  1f
    mov   w19, #1
1:
    cmp   w19, #1                    // were frames skipped between root and tail?
    b.le  .Lhud_loop
    adrp  x0, str_arrow              // show the gap as " -> ..."
    add   x0, x0, :lo12:str_arrow
    bl    emit_str
    adrp  x0, str_dots
    add   x0, x0, :lo12:str_dots
    bl    emit_str
.Lhud_loop:
    cmp   w19, w20
    b.ge  .Lhud_trail_done
    adrp  x0, str_arrow              // " -> " before each tail cell
    add   x0, x0, :lo12:str_arrow
    bl    emit_str
    mov   w0, w19
    bl    emit_stack_cell
    add   w19, w19, #1
    b     .Lhud_loop
.Lhud_trail_done:
    mov   w0, #'\n'
    bl    putchar

    bl    emit_curbyte               // live runner-cell byte (watch the bits flip)
    bl    emit_status                // "  status: ..."
    mov   w0, #'\n'
    bl    putchar
    adrp  x0, str_legend             // "  legend: ..."
    add   x0, x0, :lo12:str_legend
    bl    emit_str
    mov   w0, #'\n'
    bl    putchar

    ldr   x21, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret
    .size emit_hud, .-emit_hud

/* ---------------------------------------------------------------------------
 * render()  -- draw the whole grid as colour ASCII art plus the HUD, then pause.
 * No-op when g_anim==0 (quiet/verify mode).
 * Frame saves x19 (row), x20 (col), x21 (cell byte / scratch), x30.
 * ------------------------------------------------------------------------- */
    .type render, %function
render:
    adrp  x0, g_anim
    add   x0, x0, :lo12:g_anim
    ldrb  w0, [x0]
    cbnz  w0, .Lr_go
    ret                              // quiet mode: draw nothing, no sleep
.Lr_go:
    stp   x29, x30, [sp, #-48]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]

    adrp  x0, str_clear              // clear screen + home cursor
    add   x0, x0, :lo12:str_clear
    bl    emit_str

    mov   w19, #0                    // w19 = row index, 0..H-1
.Lr_row:
    cmp   w19, #MAZE_H
    b.ge  .Lr_bottom

    /* ---- top-wall line: "+" then per cell "---"/"   " then "+" ------------ */
    mov   w0, #'+'
    bl    putchar
    mov   w20, #0
.Lr_top:
    cmp   w20, #MAZE_W
    b.ge  .Lr_topend
    mov   w0, w19
    mov   w1, w20
    bl    cell_addr
    ldrb  w21, [x0]                  // cell byte
    tst   w21, #WALL_N
    mov   w21, #'-'                  // reuse w21 to hold the char ('-' = wall)
    b.ne  1f
    mov   w21, #' '                 // no wall -> blank (open passage upward)
1:  mov   w0, w21
    bl    putchar                   // 3 wide per cell; w21 survives putchar
    mov   w0, w21
    bl    putchar
    mov   w0, w21
    bl    putchar
    mov   w0, #'+'
    bl    putchar
    add   w20, w20, #1
    b     .Lr_top
.Lr_topend:
    mov   w0, #'\n'
    bl    putchar

    /* ---- content line: (W wall?'|':' ') + ' ' + coloured glyph + ' ' ------ */
    mov   w20, #0
.Lr_mid:
    cmp   w20, #MAZE_W
    b.ge  .Lr_midend
    mov   w0, w19
    mov   w1, w20
    bl    cell_addr
    ldrb  w21, [x0]
    tst   w21, #WALL_W
    mov   w0, #'|'
    b.ne  2f
    mov   w0, #' '
2:  bl    putchar
    mov   w0, #' '
    bl    putchar
    mov   w0, w19                    // glyph_for(row, col, byte) -> char
    mov   w1, w20
    mov   w2, w21
    bl    glyph_for
    bl    put_glyph                  // print it in its colour
    mov   w0, #' '
    bl    putchar
    add   w20, w20, #1
    b     .Lr_mid
.Lr_midend:
    mov   w0, w19                    // right border: east wall of cell (row,W-1)
    mov   w1, #(MAZE_W - 1)
    bl    cell_addr
    ldrb  w21, [x0]
    tst   w21, #WALL_E
    mov   w0, #'|'
    b.ne  3f
    mov   w0, #' '
3:  bl    putchar
    mov   w0, #'\n'
    bl    putchar

    add   w19, w19, #1
    b     .Lr_row

.Lr_bottom:
    mov   w0, #'+'                   // bottom edge from the last row's S walls
    bl    putchar
    mov   w20, #0
.Lr_bot:
    cmp   w20, #MAZE_W
    b.ge  .Lr_botend
    mov   w0, #(MAZE_H - 1)
    mov   w1, w20
    bl    cell_addr
    ldrb  w21, [x0]
    tst   w21, #WALL_S
    mov   w21, #'-'                  // reuse w21 to hold the char to print
    b.ne  4f
    mov   w21, #' '
4:  mov   w0, w21
    bl    putchar
    mov   w0, w21
    bl    putchar
    mov   w0, w21
    bl    putchar
    mov   w0, #'+'
    bl    putchar
    add   w20, w20, #1
    b     .Lr_bot
.Lr_botend:
    mov   w0, #'\n'
    bl    putchar

    bl    emit_hud                   // the live recursion readout

    mov   x0, #0                     // fflush(NULL): show the frame before sleep
    bl    fflush
    adrp  x0, g_delay_us             // usleep(g_delay_us)
    add   x0, x0, :lo12:g_delay_us
    ldr   w0, [x0]
    bl    usleep

    ldr   x21, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret
    .size render, .-render

/* ---------------------------------------------------------------------------
 * solve(w0=row, w1=col) -> w0 = 1 if a path to the goal was found, else 0
 *
 * THE CENTREPIECE: a genuinely recursive DFS.  Each invocation owns a stack
 * frame; the chain of frames currently on the stack IS the trail from the start
 * cell to the cell being explored (mirrored live in the HUD's "call stack").
 *
 * Callee-saved across recursive calls:
 *   w19=row w20=col x21=this cell's address w22=dir index / saved return value
 *   w23=neighbour row  w24=neighbour col
 * Frame (64 bytes): [0]x29 [8]x30 [16]x19 [24]x20 [32]x21 [40]x22 [48]x23 [56]x24
 * ------------------------------------------------------------------------- */
    .global solve
    .type solve, %function
solve:
    stp   x29, x30, [sp, #-64]!       // prologue: save FP and RETURN ADDRESS (x30)
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    stp   x21, x22, [sp, #32]
    stp   x23, x24, [sp, #48]

    mov   w19, w0                     // w19 = row
    mov   w20, w1                     // w20 = col

    mov   w0, w19                     // x21 = &grid[row][col]
    mov   w1, w20
    bl    cell_addr
    mov   x21, x0

    mov   x0, x21                     // already visited?
    mov   w1, #F_SEEN
    bl    is_set
    cbnz  w0, .Ls_seen                // yes -> dead branch (no frame to pop)

    mov   x0, x21                     // mark THIS cell seen (orr read/mod/write)
    mov   w1, #F_SEEN
    bl    mark
    mov   w0, w19                     // push this cell as a live frame (HUD mirror)
    mov   w1, w20
    bl    push_cell

    adrp  x0, cur_r                   // runner is now here
    add   x0, x0, :lo12:cur_r
    strb  w19, [x0]
    adrp  x0, cur_c
    add   x0, x0, :lo12:cur_c
    strb  w20, [x0]
    bl    render                      // draw the "arrive" frame

    mov   x0, x21                     // reached the goal?
    mov   w1, #F_GOAL
    bl    is_set
    cbz   w0, .Ls_explore
    mov   x0, x21                     // yes: light the goal as path, report found
    mov   w1, #F_PATH
    bl    mark
    mov   w0, #1
    b     .Ls_return

.Ls_explore:
    mov   w22, #0                     // dir = 0  (try N, then E, S, W)
.Ls_loop:
    cmp   w22, #4
    b.ge  .Ls_deadend                 // no direction worked -> backtrack

    mov   x0, x21                     // wall this way?
    adrp  x1, wall_tab
    add   x1, x1, :lo12:wall_tab
    ldrb  w1, [x1, w22, uxtw]
    bl    wall_blocked
    cbnz  w0, .Ls_next

    mov   w0, w19                     // neighbour = move(row,col,dir)  (signed)
    mov   w1, w20
    mov   w2, w22
    bl    move
    mov   w23, w0                     // w23 = neighbour row
    mov   w24, w1                     // w24 = neighbour col

    mov   w0, w23                     // defensive bounds guard
    mov   w1, w24
    bl    in_bounds
    cbz   w0, .Ls_next

    mov   w0, w23                     // neighbour already seen?
    mov   w1, w24
    bl    cell_addr
    mov   w1, #F_SEEN
    bl    is_set
    cbnz  w0, .Ls_next

    mov   w0, w23                     // *** RECURSE into the neighbour ***
    mov   w1, w24
    bl    solve                       // bl saved our x30 in the prologue above
    cbz   w0, .Ls_next                // child found nothing -> try next direction

    mov   x0, x21                     // child reached goal: mark THIS cell on path
    mov   w1, #F_PATH
    bl    mark
    bl    render                      // animate the path lighting up as we unwind
    mov   w0, #1
    b     .Ls_return

.Ls_next:
    add   w22, w22, #1
    b     .Ls_loop

.Ls_deadend:
    adrp  x0, g_back                  // count the backtrack
    add   x0, x0, :lo12:g_back
    ldr   w1, [x0]
    add   w1, w1, #1
    str   w1, [x0]
    mov   w0, #0                      // report "no path from here"

.Ls_return:
    mov   w22, w0                     // save return value across pop/render
    bl    pop_cell                    // this frame leaves the live stack
    bl    set_cur_from_top            // runner steps back to the parent cell
    bl    render                      // draw the "retreat / unwind" frame
    mov   w0, w22                     // restore return value

.Ls_seen:
    ldp   x23, x24, [sp, #48]         // epilogue: restore callee-saved regs ...
    ldp   x21, x22, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #64         // ... and FP + RETURN ADDRESS, pop frame
    ret
    .size solve, .-solve

/* ---------------------------------------------------------------------------
 * print_path()  -- canonical machine-checkable line:
 *   "path: (r,c) (r,c) ..."  PATH-bit cells in row-major order.
 * Coords are 0..(<=9) so each prints as a single '0'+digit character; this is
 * what make verify diffs against the C reference.
 * ------------------------------------------------------------------------- */
    .type print_path, %function
print_path:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    adrp  x0, str_path
    add   x0, x0, :lo12:str_path
    bl    emit_str
    mov   w19, #0
.Lp_row:
    cmp   w19, #MAZE_H
    b.ge  .Lp_done
    mov   w20, #0
.Lp_col:
    cmp   w20, #MAZE_W
    b.ge  .Lp_rownext
    mov   w0, w19
    mov   w1, w20
    bl    cell_addr
    ldrb  w1, [x0]
    tst   w1, #F_PATH
    b.eq  .Lp_colnext
    mov   w0, #' '
    bl    putchar
    mov   w0, #'('
    bl    putchar
    add   w0, w19, #'0'
    bl    putchar
    mov   w0, #','
    bl    putchar
    add   w0, w20, #'0'
    bl    putchar
    mov   w0, #')'
    bl    putchar
.Lp_colnext:
    add   w20, w20, #1
    b     .Lp_col
.Lp_rownext:
    add   w19, w19, #1
    b     .Lp_row
.Lp_done:
    mov   w0, #'\n'
    bl    putchar
    mov   x0, #0
    bl    fflush
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size print_path, .-print_path

/* ===========================================================================
 * BIT-INSPECTION sub-commands  --  "go deeper": show the raw binary/data.
 * (Chapter 4: every cell is one byte; walls & flags are individual bits;
 *  movement deltas are two's-complement signed bytes, sign-extended.)
 * ==========================================================================*/

/* emit_hex(w0=value, w1=ndigits)  print ndigits hex digits, most significant
 * first.  Used for bytes (2 digits) and sign-extended words (8 digits).      */
    .type emit_hex, %function
emit_hex:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    mov   w19, w0                    // value
    mov   w20, w1                    // digits remaining
.Lhx_loop:
    cmp   w20, #0
    b.le  .Lhx_done
    sub   w1, w20, #1
    lsl   w1, w1, #2                 // shift = (remaining-1)*4
    lsr   w0, w19, w1
    and   w0, w0, #0xF               // isolate one nibble
    cmp   w0, #10
    b.lt  1f
    add   w0, w0, #('A' - 10)        // 10..15 -> 'A'..'F'
    b     2f
1:  add   w0, w0, #'0'               // 0..9 -> '0'..'9'
2:  bl    putchar
    sub   w20, w20, #1
    b     .Lhx_loop
.Lhx_done:
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size emit_hex, .-emit_hex

/* emit_bin8(w0=byte)  print the 8 bits MSB-first, with a space between the
 * two nibbles, e.g. 0x4D -> "0100 1101".                                     */
    .type emit_bin8, %function
emit_bin8:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    mov   w19, w0                    // byte
    mov   w20, #7                    // bit index, 7 down to 0
.Lb8_loop:
    cmp   w20, #0
    b.lt  .Lb8_done
    lsr   w0, w19, w20               // bit = (byte >> i) & 1
    and   w0, w0, #1
    add   w0, w0, #'0'
    bl    putchar
    cmp   w20, #4                    // after the high nibble, print a space
    b.ne  1f
    mov   w0, #' '
    bl    putchar
1:  sub   w20, w20, #1
    b     .Lb8_loop
.Lb8_done:
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size emit_bin8, .-emit_bin8

/* emit_bitval(w0=byte, w1=mask)  print '1' if any masked bit is set, else '0'. */
    .type emit_bitval, %function
emit_bitval:
    stp   x29, x30, [sp, #-16]!
    mov   x29, sp
    and   w0, w0, w1
    cmp   w0, #0
    cset  w0, ne
    add   w0, w0, #'0'
    bl    putchar
    ldp   x29, x30, [sp], #16
    ret
    .size emit_bitval, .-emit_bitval

/* emit_int(w0=signed)  print a signed decimal (handles the negative deltas).  */
    .type emit_int, %function
emit_int:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    str   x19, [sp, #16]
    mov   w19, w0
    cmp   w19, #0
    b.ge  1f
    mov   w0, #'-'                   // negative: print sign, then magnitude
    bl    putchar
    neg   w19, w19
1:  mov   w0, w19
    bl    emit_uint
    ldr   x19, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size emit_int, .-emit_int

/* decode_cell(w0=row, w1=col)  print one cell's byte fully decoded:
 *   (r,c) = 0xHH = 0bBBBB BBBB
 *           walls:  N=. E=. S=. W=.
 *           state:  seen=. path=. start=. goal=.
 * Saves x19=row, x20=col, x21=byte.                                          */
    .type decode_cell, %function
decode_cell:
    stp   x29, x30, [sp, #-48]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]
    mov   w19, w0
    mov   w20, w1
    bl    cell_addr                  // x0 = &cell
    ldrb  w21, [x0]                  // w21 = the cell byte

    mov   w0, #' '
    bl    putchar
    mov   w0, #' '
    bl    putchar
    mov   w0, #'('                   // "(r,c)"
    bl    putchar
    mov   w0, w19
    bl    emit_uint
    mov   w0, #','
    bl    putchar
    mov   w0, w20
    bl    emit_uint
    mov   w0, #')'
    bl    putchar
    mov   w0, #' '
    bl    putchar
    mov   w0, #'='
    bl    putchar
    mov   w0, #' '
    bl    putchar
    mov   w0, #'0'                   // "0xHH"
    bl    putchar
    mov   w0, #'x'
    bl    putchar
    mov   w0, w21
    mov   w1, #2
    bl    emit_hex
    mov   w0, #' '
    bl    putchar
    mov   w0, #'='
    bl    putchar
    mov   w0, #' '
    bl    putchar
    mov   w0, #'0'                   // "0bBBBB BBBB"
    bl    putchar
    mov   w0, #'b'
    bl    putchar
    mov   w0, w21
    bl    emit_bin8
    mov   w0, #'\n'
    bl    putchar

    adrp  x0, lbl_walls              // "        walls:  N="
    add   x0, x0, :lo12:lbl_walls
    bl    emit_str
    mov   w0, w21
    mov   w1, #WALL_N
    bl    emit_bitval
    adrp  x0, lbl_e
    add   x0, x0, :lo12:lbl_e
    bl    emit_str
    mov   w0, w21
    mov   w1, #WALL_E
    bl    emit_bitval
    adrp  x0, lbl_s
    add   x0, x0, :lo12:lbl_s
    bl    emit_str
    mov   w0, w21
    mov   w1, #WALL_S
    bl    emit_bitval
    adrp  x0, lbl_w
    add   x0, x0, :lo12:lbl_w
    bl    emit_str
    mov   w0, w21
    mov   w1, #WALL_W
    bl    emit_bitval
    mov   w0, #'\n'
    bl    putchar

    adrp  x0, lbl_state              // "        state:  seen="
    add   x0, x0, :lo12:lbl_state
    bl    emit_str
    mov   w0, w21
    mov   w1, #F_SEEN
    bl    emit_bitval
    adrp  x0, lbl_path
    add   x0, x0, :lo12:lbl_path
    bl    emit_str
    mov   w0, w21
    mov   w1, #F_PATH
    bl    emit_bitval
    adrp  x0, lbl_start
    add   x0, x0, :lo12:lbl_start
    bl    emit_str
    mov   w0, w21
    mov   w1, #F_START
    bl    emit_bitval
    adrp  x0, lbl_goal
    add   x0, x0, :lo12:lbl_goal
    bl    emit_str
    mov   w0, w21
    mov   w1, #F_GOAL
    bl    emit_bitval
    mov   w0, #'\n'
    bl    putchar
    mov   w0, #'\n'
    bl    putchar

    ldr   x21, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret
    .size decode_cell, .-decode_cell

/* view_bits()  the "bits" sub-command: explain the byte format, then decode a
 * handful of representative cells (start, goal, and two interior cells).      */
    .type view_bits, %function
view_bits:
    stp   x29, x30, [sp, #-16]!
    mov   x29, sp
    adrp  x0, hdr_bits
    add   x0, x0, :lo12:hdr_bits
    bl    emit_str
    mov   w0, #START_R               // the start cell
    mov   w1, #START_C
    bl    decode_cell
    mov   w0, #GOAL_R                // the goal cell
    mov   w1, #GOAL_C
    bl    decode_cell
    mov   w0, #0                     // a wall-heavy interior cell
    mov   w1, #4
    bl    decode_cell
    mov   w0, #3
    mov   w1, #3
    bl    decode_cell
    ldp   x29, x30, [sp], #16
    ret
    .size view_bits, .-view_bits

/* view_bytes()  the "bytes" sub-command: dump the maze as an 8x8 hex grid so
 * the audience sees the maze IS just 64 bytes of data.                       */
    .type view_bytes, %function
view_bytes:
    stp   x29, x30, [sp, #-48]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]
    adrp  x0, hdr_bytes
    add   x0, x0, :lo12:hdr_bytes
    bl    emit_str
    adrp  x0, bv_cols
    add   x0, x0, :lo12:bv_cols
    bl    emit_str
    mov   w19, #0                    // row
.Lvb_row:
    cmp   w19, #MAZE_H
    b.ge  .Lvb_done
    adrp  x0, bv_rpfx                // "  r"
    add   x0, x0, :lo12:bv_rpfx
    bl    emit_str
    mov   w0, w19
    bl    emit_uint
    mov   w0, #' '
    bl    putchar
    mov   w20, #0                    // col
.Lvb_col:
    cmp   w20, #MAZE_W
    b.ge  .Lvb_rownext
    mov   w0, #' '
    bl    putchar
    mov   w0, #'0'
    bl    putchar
    mov   w0, #'x'
    bl    putchar
    mov   w0, w19                    // load byte (r,c)
    mov   w1, w20
    bl    cell_addr
    ldrb  w21, [x0]
    mov   w0, w21
    mov   w1, #2
    bl    emit_hex
    add   w20, w20, #1
    b     .Lvb_col
.Lvb_rownext:
    mov   w0, #'\n'
    bl    putchar
    add   w19, w19, #1
    b     .Lvb_row
.Lvb_done:
    adrp  x0, bv_foot
    add   x0, x0, :lo12:bv_foot
    bl    emit_str
    ldr   x21, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret
    .size view_bytes, .-view_bytes

/* view_deltas()  the "deltas" sub-command: show each direction's SIGNED delta,
 * the raw byte in binary, and the 32-bit value ldrsb produces (sign extended).*/
    .type view_deltas, %function
view_deltas:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    str   x19, [sp, #16]
    adrp  x0, hdr_delta
    add   x0, x0, :lo12:hdr_delta
    bl    emit_str
    mov   w19, #0                    // direction index 0..3
.Lvd_loop:
    cmp   w19, #4
    b.ge  .Lvd_done
    adrp  x0, dl_d1                  // "    "  then the direction letter
    add   x0, x0, :lo12:dl_d1
    bl    emit_str
    adrp  x0, str_dirs
    add   x0, x0, :lo12:str_dirs
    ldrb  w0, [x0, w19, uxtw]
    bl    putchar
    adrp  x0, dl_d1                  // gap, then signed drow
    add   x0, x0, :lo12:dl_d1
    bl    emit_str
    adrp  x1, drow_tab
    add   x1, x1, :lo12:drow_tab
    ldrsb w0, [x1, w19, uxtw]        // SIGN-EXTENDED load of drow
    bl    emit_int
    adrp  x0, dl_d2                  // gap, then signed dcol
    add   x0, x0, :lo12:dl_d2
    bl    emit_str
    adrp  x1, dcol_tab
    add   x1, x1, :lo12:dcol_tab
    ldrsb w0, [x1, w19, uxtw]
    bl    emit_int
    adrp  x0, dl_d2                  // gap, then drow's raw byte in binary
    add   x0, x0, :lo12:dl_d2
    bl    emit_str
    adrp  x1, drow_tab
    add   x1, x1, :lo12:drow_tab
    ldrb  w0, [x1, w19, uxtw]        // ZERO-extended (raw 8 bits)
    bl    emit_bin8
    adrp  x0, dl_d3                  // "      0x", then sign-extended 32 bits
    add   x0, x0, :lo12:dl_d3
    bl    emit_str
    adrp  x1, drow_tab
    add   x1, x1, :lo12:drow_tab
    ldrsb w0, [x1, w19, uxtw]        // ldrsb result as a 32-bit value
    mov   w1, #8
    bl    emit_hex
    mov   w0, #'\n'
    bl    putchar
    add   w19, w19, #1
    b     .Lvd_loop
.Lvd_done:
    adrp  x0, dl_foot
    add   x0, x0, :lo12:dl_foot
    bl    emit_str
    ldr   x19, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size view_deltas, .-view_deltas

/* emit_curbyte()  one HUD line that shows the runner cell's byte live, so the
 * audience watches the seen/path BITS flip during the search.                */
    .type emit_curbyte, %function
emit_curbyte:
    stp   x29, x30, [sp, #-48]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]
    adrp  x0, cur_r
    add   x0, x0, :lo12:cur_r
    ldrb  w20, [x0]                  // runner row
    adrp  x0, cur_c
    add   x0, x0, :lo12:cur_c
    ldrb  w21, [x0]                  // runner col
    mov   w0, w20
    mov   w1, w21
    bl    cell_addr
    ldrb  w19, [x0]                  // the runner cell byte
    adrp  x0, cb_run                 // "  runner cell ("
    add   x0, x0, :lo12:cb_run
    bl    emit_str
    mov   w0, w20
    bl    emit_uint
    mov   w0, #','
    bl    putchar
    mov   w0, w21
    bl    emit_uint
    adrp  x0, cb_byte                // "):  byte = 0x"
    add   x0, x0, :lo12:cb_byte
    bl    emit_str
    mov   w0, w19
    mov   w1, #2
    bl    emit_hex
    mov   w0, #' '
    bl    putchar
    mov   w0, #'='
    bl    putchar
    mov   w0, #' '
    bl    putchar
    mov   w0, w19
    bl    emit_bin8                  // the live 8 bits
    adrp  x0, cb_seen                // "    seen="
    add   x0, x0, :lo12:cb_seen
    bl    emit_str
    mov   w0, w19
    mov   w1, #F_SEEN
    bl    emit_bitval
    adrp  x0, cb_pathb               // "  path="
    add   x0, x0, :lo12:cb_pathb
    bl    emit_str
    mov   w0, w19
    mov   w1, #F_PATH
    bl    emit_bitval
    mov   w0, #'\n'
    bl    putchar
    ldr   x21, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret
    .size emit_curbyte, .-emit_curbyte

/* ---------------------------------------------------------------------------
 * read_flag_env(x0=name) -> w0 = 0 if value begins with '0', else 1
 * Small helper for the on/off env switches (MAZE_ANIM, MAZE_COLOR).
 * ------------------------------------------------------------------------- */
    .type read_flag_env, %function
read_flag_env:
    stp   x29, x30, [sp, #-16]!
    mov   x29, sp
    bl    getenv                      // x0 = value or NULL
    cbz   x0, .Lrf_on                 // unset -> default ON
    ldrb  w1, [x0]
    cmp   w1, #'0'
    b.eq  .Lrf_off
.Lrf_on:
    mov   w0, #1
    b     .Lrf_ret
.Lrf_off:
    mov   w0, #0
.Lrf_ret:
    ldp   x29, x30, [sp], #16
    ret
    .size read_flag_env, .-read_flag_env

/* ---------------------------------------------------------------------------
 * main(w0=argc, x1=argv) -> exit code (0 solved, 1 not)
 *   env MAZE_ANIM=0 -> quiet (verify);  MAZE_COLOR=0 -> no colour;
 *   env MAZE_DELAY=<ms> -> per-step speed;  argv[1]=="1" -> unsolvable maze.
 * Frame saves x19 (argc/found), x20 (argv), x21 (chosen grid base), x30.
 * ------------------------------------------------------------------------- */
    .global main
    .type main, %function
main:
    stp   x29, x30, [sp, #-48]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]
    mov   w19, w0                    // save argc
    mov   x20, x1                    // save argv

    adrp  x0, str_env                // g_anim = (MAZE_ANIM != "0")
    add   x0, x0, :lo12:str_env
    bl    read_flag_env
    adrp  x1, g_anim
    add   x1, x1, :lo12:g_anim
    strb  w0, [x1]

    adrp  x0, str_envcol             // g_color = (MAZE_COLOR != "0")
    add   x0, x0, :lo12:str_envcol
    bl    read_flag_env
    adrp  x1, g_color
    add   x1, x1, :lo12:g_color
    strb  w0, [x1]

    adrp  x0, str_envdly             // MAZE_DELAY=<ms> -> g_delay_us
    add   x0, x0, :lo12:str_envdly
    bl    getenv
    cbz   x0, .Lm_grid               // unset -> keep default 45 ms
    bl    atoi                       // w0 = milliseconds (non-variadic libc)
    cmp   w0, #0
    b.le  .Lm_grid                   // <=0 or junk -> keep default
    mov   w1, #1000                  // ms -> microseconds
    mul   w0, w0, w1
    adrp  x1, g_delay_us
    add   x1, x1, :lo12:g_delay_us
    str   w0, [x1]

.Lm_grid:
    adrp  x0, grid0                  // default active grid = solvable maze
    add   x0, x0, :lo12:grid0        //   (publish early: the views read it too)
    adrp  x1, grid_base
    add   x1, x1, :lo12:grid_base
    str   x0, [x1]

    cmp   w19, #2                    // was an argv[1] supplied?
    b.lt  .Lm_solve
    ldr   x21, [x20, #8]             // x21 = argv[1]

    mov   x0, x21                    // "bits"   -> bit-decode view
    adrp  x1, sc_bits
    add   x1, x1, :lo12:sc_bits
    bl    strcmp
    cbz   w0, .Lm_bits
    mov   x0, x21                    // "bytes"  -> raw hex-grid view
    adrp  x1, sc_bytes
    add   x1, x1, :lo12:sc_bytes
    bl    strcmp
    cbz   w0, .Lm_bytes
    mov   x0, x21                    // "deltas" -> signed/two's-complement view
    adrp  x1, sc_deltas
    add   x1, x1, :lo12:sc_deltas
    bl    strcmp
    cbz   w0, .Lm_deltas

    ldrb  w2, [x21]                  // otherwise: "1" selects the unsolvable maze
    cmp   w2, #'1'
    b.ne  .Lm_solve
    adrp  x0, grid1
    add   x0, x0, :lo12:grid1
    adrp  x1, grid_base
    add   x1, x1, :lo12:grid_base
    str   x0, [x1]
    b     .Lm_solve

.Lm_bits:
    bl    view_bits
    b     .Lm_viewdone
.Lm_bytes:
    bl    view_bytes
    b     .Lm_viewdone
.Lm_deltas:
    bl    view_deltas
.Lm_viewdone:
    mov   w0, #0                     // inspection views always exit 0
    b     .Lm_exit

.Lm_solve:
    mov   w0, #START_R               // solve from the start cell
    mov   w1, #START_C
    bl    solve
    mov   w19, w0                    // w19 = found

    adrp  x0, g_state               // record final state for the HUD status line
    add   x0, x0, :lo12:g_state
    cmp   w19, #0
    mov   w1, #1                     // solved
    mov   w2, #2                     // no path
    csel  w1, w1, w2, ne
    str   w1, [x0]

    bl    render                    // final frame (no-op if quiet)
    bl    print_path                // canonical "path: ..." line for verify

    cmp   w19, #0                   // exit code: 0 solved, 1 not
    cset  w0, eq

.Lm_exit:
    ldr   x21, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret
    .size main, .-main

    .section .note.GNU-stack,"",%progbits   /* mark stack non-executable */
