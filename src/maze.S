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
 * libc is called for I/O and timing (putchar, getenv, fflush, usleep) -- all
 * NON-variadic, per the project's "no printf from asm" guidance.  Coordinates
 * are 0..7 (single decimal digit) so numbers print with a plain putchar.
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
    .equ  SLEEP_US, 45000        /* per-frame pause: 45 ms -> watchable */

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
str_path:  .asciz "path:"             /* canonical machine-checked output line */

/* ===========================================================================
 * Mutable data  (the grids are written in place: seen/path bits get set)
 * ==========================================================================*/
    .section .data
    .align 3
grid0:     .byte MAZE_BYTES           /* solvable maze (default)               */
grid1:     .byte MAZE2_BYTES          /* goal sealed off -> unsolvable         */
grid_base: .quad 0                    /* -> active grid, chosen in main        */
cur_r:     .byte 0                    /* runner's current row (for render 'R') */
cur_c:     .byte 0                    /* runner's current col                  */
g_anim:    .byte 1                    /* 1 = animate, 0 = quiet (verify mode)  */

/* ===========================================================================
 * Text
 * ==========================================================================*/
    .text

/* ---------------------------------------------------------------------------
 * cell_addr(w0=row, w1=col) -> x0 = &grid[row*MAZE_W + col]
 * Scaled addressing via madd: index = row*WIDTH + col, then add the base.
 * Leaf routine (calls nothing) so it needs no stack frame.
 * ------------------------------------------------------------------------- */
    .type cell_addr, %function
cell_addr:
    adrp  x3, grid_base               // x3 = page of grid_base (PC-relative)
    add   x3, x3, :lo12:grid_base     //   + low 12 bits -> &grid_base
    ldr   x3, [x3]                    // x3 = base pointer to the active grid
    mov   w4, #MAZE_W                 // w4 = width (row stride in bytes)
    madd  w2, w0, w4, w1              // w2 = row*WIDTH + col   (one multiply-add)
    add   x0, x3, w2, uxtw            // x0 = base + index (zero-extend the index)
    ret                              // return address in x0
    .size cell_addr, .-cell_addr

/* ---------------------------------------------------------------------------
 * is_set(x0=cell_addr, w1=mask) -> w0 = 1 if (cell & mask)!=0 else 0
 * The canonical "read one bit" demo: load the byte, AND with a mask, branch.
 * Used for wall checks (wall_blocked) and flag checks (seen/goal) alike.
 * ------------------------------------------------------------------------- */
    .type is_set, %function
is_set:
    ldrb  w2, [x0]                    // load the 1 cell byte into w2
    and   w2, w2, w1                  // keep only the masked bit(s)
    cmp   w2, #0                      // were any of them set?
    cset  w0, ne                      // w0 = (result != 0) ? 1 : 0
    ret
    .size is_set, .-is_set

/* wall_blocked is exactly the same operation (mask a wall bit); alias it so the
 * call sites read clearly as "is this direction walled?".                     */
    .type wall_blocked, %function
wall_blocked:
    b     is_set                      // tail-call: read the wall bit, return 0/1
    .size wall_blocked, .-wall_blocked

/* ---------------------------------------------------------------------------
 * mark(x0=cell_addr, w1=mask)   set flag bits  -- read / modify / write
 * The classic ldrb -> orr -> strb pattern that turns a flag on in place.
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
 * (Provided for completeness / the bic demo; not needed by the DFS itself.)
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
 * Defensive guard so a bad wall byte can never make us index off the grid.
 * Uses SIGNED compares (b.lt) so a -1 produced by a north/west step fails.
 * ------------------------------------------------------------------------- */
    .type in_bounds, %function
in_bounds:
    cmp   w0, #0                      // row < 0 ?
    b.lt  .Loob                       //   -> out of bounds
    cmp   w0, #MAZE_H                 // row >= H ?
    b.ge  .Loob
    cmp   w1, #0                      // col < 0 ?
    b.lt  .Loob
    cmp   w1, #MAZE_W                 // col >= W ?
    b.ge  .Loob
    mov   w0, #1                      // all four checks passed
    ret
.Loob:
    mov   w0, #0                      // failed at least one bound
    ret
    .size in_bounds, .-in_bounds

/* ---------------------------------------------------------------------------
 * move(w0=row, w1=col, w2=dir) -> (w0=new_row, w1=new_col)
 * Apply the SIGNED delta for the direction.  ldrsb sign-extends the delta byte
 * (two's complement) into a 32-bit register before we add it -- this is the
 * required "signed deltas + sign extension" path.
 * ------------------------------------------------------------------------- */
    .type move, %function
move:
    adrp  x3, drow_tab                // address of the signed row-delta table
    add   x3, x3, :lo12:drow_tab
    ldrsb w4, [x3, w2, sxtw]          // w4 = drow[dir], SIGN-EXTENDED (-1 stays -1)
    adrp  x5, dcol_tab                // address of the signed col-delta table
    add   x5, x5, :lo12:dcol_tab
    ldrsb w5, [x5, w2, sxtw]          // w5 = dcol[dir], sign-extended
    add   w0, w0, w4                  // new_row = row + drow   (signed add)
    add   w1, w1, w5                  // new_col = col + dcol
    ret
    .size move, .-move

/* ---------------------------------------------------------------------------
 * glyph_for(w0=row, w1=col, w2=cellbyte) -> w0 = display character
 * Pure decision logic (leaf): pick what to draw for one cell.  Priority:
 *   runner 'R' > start 'S' > goal 'G' > path '*' > seen '.' > empty ' '
 * ------------------------------------------------------------------------- */
    .type glyph_for, %function
glyph_for:
    adrp  x3, cur_r                   // load the runner's current row
    add   x3, x3, :lo12:cur_r
    ldrb  w3, [x3]
    adrp  x4, cur_c                   // load the runner's current col
    add   x4, x4, :lo12:cur_c
    ldrb  w4, [x4]
    cmp   w0, w3                      // this cell's row == runner row?
    b.ne  .Lg_start
    cmp   w1, w4                      // and col == runner col?
    b.ne  .Lg_start
    mov   w0, #'R'                    // yes -> the runner is here
    ret
.Lg_start:
    tst   w2, #F_START               // start flag set?
    b.eq  .Lg_goal
    mov   w0, #'S'
    ret
.Lg_goal:
    tst   w2, #F_GOAL                // goal flag set?
    b.eq  .Lg_path
    mov   w0, #'G'
    ret
.Lg_path:
    tst   w2, #F_PATH                // on the final solution path?
    b.eq  .Lg_seen
    mov   w0, #'*'
    ret
.Lg_seen:
    tst   w2, #F_SEEN               // visited during the search?
    b.eq  .Lg_blank
    mov   w0, #'.'
    ret
.Lg_blank:
    mov   w0, #' '                   // never touched
    ret
    .size glyph_for, .-glyph_for

/* ---------------------------------------------------------------------------
 * emit_str(x0 = NUL-terminated string)   write a string a byte at a time.
 * Avoids variadic printf and avoids needing the libc `stdout` symbol.
 * Frame: save x19 (cursor) and x30 (we call putchar).
 * ------------------------------------------------------------------------- */
    .type emit_str, %function
emit_str:
    stp   x29, x30, [sp, #-32]!       // push frame; save FP and return address
    mov   x29, sp
    str   x19, [sp, #16]             // save callee-saved x19 (we use it for ptr)
    mov   x19, x0                    // x19 = current character pointer
.Les_loop:
    ldrb  w0, [x19]                  // load next byte
    cbz   w0, .Les_done             // NUL terminator -> stop
    bl    putchar                   // putchar(byte); clobbers caller-saved regs
    add   x19, x19, #1              // advance the pointer
    b     .Les_loop
.Les_done:
    ldr   x19, [sp, #16]            // restore x19
    ldp   x29, x30, [sp], #32       // pop frame, restore FP/LR
    ret
    .size emit_str, .-emit_str

/* ---------------------------------------------------------------------------
 * render()  -- draw the whole grid as ASCII art and pause.
 * No-op when g_anim==0 (quiet/verify mode).  Walls are drawn from bits:
 *   '+---+'  top/bottom edges use N (and final S) wall bits
 *   '|'      left edges use W wall bits (interior E walls == neighbour's W)
 * Frame saves x19 (row), x20 (col), x21 (scratch addr/byte), x30.
 * ------------------------------------------------------------------------- */
    .type render, %function
render:
    adrp  x0, g_anim                 // animation enabled?
    add   x0, x0, :lo12:g_anim
    ldrb  w0, [x0]
    cbnz  w0, .Lr_go
    ret                              // quiet mode: draw nothing, no sleep
.Lr_go:
    stp   x29, x30, [sp, #-48]!      // prologue
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]

    adrp  x0, str_clear              // clear screen + home cursor
    add   x0, x0, :lo12:str_clear
    bl    emit_str

    mov   w19, #0                    // w19 = row index, 0..H-1
.Lr_row:
    cmp   w19, #MAZE_H
    b.ge  .Lr_bottom                 // done all rows -> draw bottom edge

    /* ---- top-wall line for this row: "+" then per cell "---"/"   " then "+" */
    mov   w0, #'+'
    bl    putchar
    mov   w20, #0                    // w20 = col index
.Lr_top:
    cmp   w20, #MAZE_W
    b.ge  .Lr_topend
    mov   w0, w19                    // address of cell (row,col)
    mov   w1, w20
    bl    cell_addr
    ldrb  w21, [x0]                  // w21 = cell byte
    tst   w21, #WALL_N              // north wall present?
    mov   w21, #'-'                // reuse w21 to hold the char ('-' = wall)
    b.ne  1f
    mov   w21, #' '                // no wall -> blank (open passage upward)
1:  mov   w0, w21                  // print that char 3x (a cell is 3 columns wide)
    bl    putchar                  //   w21 is callee-saved -> survives putchar
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

    /* ---- content line: per cell  (W wall ? '|':' ') + ' ' + glyph + ' '     */
    mov   w20, #0
.Lr_mid:
    cmp   w20, #MAZE_W
    b.ge  .Lr_midend
    mov   w0, w19
    mov   w1, w20
    bl    cell_addr
    ldrb  w21, [x0]                  // w21 = cell byte
    tst   w21, #WALL_W              // west wall present?
    mov   w0, #'|'
    b.ne  2f
    mov   w0, #' '                  // open to the west
2:  bl    putchar
    mov   w0, #' '                  // pad before glyph
    bl    putchar
    mov   w0, w19                    // glyph_for(row, col, byte)
    mov   w1, w20
    mov   w2, w21
    bl    glyph_for
    bl    putchar                    // the cell glyph (R/S/G/*/./space)
    mov   w0, #' '                  // pad after glyph
    bl    putchar
    add   w20, w20, #1
    b     .Lr_mid
.Lr_midend:
    /* right border: east wall of the last column cell (row, W-1) */
    mov   w0, w19
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
    /* bottom edge: south walls of the last row (row H-1) */
    mov   w0, #'+'
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
    mov   w21, #'-'                // reuse w21 to hold the char to print
    b.ne  4f
    mov   w21, #' '
4:  mov   w0, w21                  // print that char 3x (cell is 3 columns wide)
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

    mov   x0, #0                     // fflush(NULL) -> flush all streams so the
    bl    fflush                     //   frame appears before we sleep
    mov   w0, #SLEEP_US              // usleep(45000): pause so the step is visible
    bl    usleep

    ldr   x21, [sp, #32]            // epilogue: restore callee-saved + FP/LR
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret
    .size render, .-render

/* ---------------------------------------------------------------------------
 * solve(w0=row, w1=col) -> w0 = 1 if a path to the goal was found, else 0
 *
 * THE CENTREPIECE: a genuinely recursive DFS.  Each invocation owns a stack
 * frame; the chain of frames currently on the stack IS the trail from the start
 * cell to the cell being explored -- visible in `make debug`.
 *
 * Callee-saved registers held across recursive calls:
 *   w19=row  w20=col  x21=this cell's address  w22=dir loop index
 *   w23=neighbour row  w24=neighbour col
 * Frame (64 bytes, 16-byte aligned):
 *   [sp,#0]=x29  [sp,#8]=x30  [16]=x19 [24]=x20 [32]=x21 [40]=x22 [48]=x23 [56]=x24
 * ------------------------------------------------------------------------- */
    .global solve
    .type solve, %function
solve:
    stp   x29, x30, [sp, #-64]!       // prologue: save FP and RETURN ADDRESS (x30)
    mov   x29, sp                     // set frame pointer
    stp   x19, x20, [sp, #16]         // save the callee-saved regs we will use
    stp   x21, x22, [sp, #32]
    stp   x23, x24, [sp, #48]

    mov   w19, w0                     // w19 = row   (preserved across recursion)
    mov   w20, w1                     // w20 = col

    mov   w0, w19                     // x21 = &grid[row][col]
    mov   w1, w20
    bl    cell_addr
    mov   x21, x0

    mov   x0, x21                     // already visited?  (seen bit)
    mov   w1, #F_SEEN
    bl    is_set
    cbnz  w0, .Ls_notfound            // yes -> dead branch, return 0

    mov   x0, x21                     // mark THIS cell as seen (orr read/mod/write)
    mov   w1, #F_SEEN
    bl    mark

    adrp  x0, cur_r                   // record runner position for the renderer
    add   x0, x0, :lo12:cur_r
    strb  w19, [x0]
    adrp  x0, cur_c
    add   x0, x0, :lo12:cur_c
    strb  w20, [x0]
    bl    render                      // draw this step (no-op in quiet mode)

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
    mov   w22, #0                     // dir = 0  (try N, then E, S, W in order)
.Ls_loop:
    cmp   w22, #4
    b.ge  .Ls_notfound                // exhausted all 4 dirs -> dead end, backtrack

    mov   x0, x21                     // is there a wall this way?
    adrp  x1, wall_tab
    add   x1, x1, :lo12:wall_tab
    ldrb  w1, [x1, w22, uxtw]         // w1 = wall mask for this direction
    bl    wall_blocked
    cbnz  w0, .Ls_next                // wall present -> skip this direction

    mov   w0, w19                     // neighbour = move(row,col,dir) (signed)
    mov   w1, w20
    mov   w2, w22
    bl    move
    mov   w23, w0                     // w23 = neighbour row
    mov   w24, w1                     // w24 = neighbour col

    mov   w0, w23                     // bounds guard (defensive; never index off-grid)
    mov   w1, w24
    bl    in_bounds
    cbz   w0, .Ls_next                // out of bounds -> skip

    mov   w0, w23                     // neighbour already seen?
    mov   w1, w24
    bl    cell_addr
    mov   w1, #F_SEEN
    bl    is_set
    cbnz  w0, .Ls_next                // seen -> skip

    mov   w0, w23                     // *** RECURSE into the neighbour ***
    mov   w1, w24
    bl    solve                       // bl saves our x30 via the prologue above
    cbz   w0, .Ls_next                // child found nothing -> try next direction

    mov   x0, x21                     // child reached the goal: mark THIS cell as
    mov   w1, #F_PATH                 //   part of the solution path (set on unwind)
    bl    mark
    bl    render                      // animate the path lighting up as we unwind
    mov   w0, #1                      // propagate "found" up the call chain
    b     .Ls_return

.Ls_next:
    add   w22, w22, #1                // try the next direction
    b     .Ls_loop

.Ls_notfound:
    mov   w0, #0                      // no path from here

.Ls_return:
    ldp   x23, x24, [sp, #48]         // epilogue: restore callee-saved regs ...
    ldp   x21, x22, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #64         // ... and FP + RETURN ADDRESS, pop frame
    ret                              // return to caller (parent frame or main)
    .size solve, .-solve

/* ---------------------------------------------------------------------------
 * print_path()  -- emit the canonical, machine-checkable result line:
 *   "path: (r,c) (r,c) ..."  for every cell with the PATH bit, in row-major
 * order.  Row/col are 0..7 so each prints as a single '0'+digit character.
 * make verify diffs this exact line against the C reference.
 * Frame saves x19 (row), x20 (col), x30.
 * ------------------------------------------------------------------------- */
    .type print_path, %function
print_path:
    stp   x29, x30, [sp, #-32]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]

    adrp  x0, str_path               // print the "path:" prefix
    add   x0, x0, :lo12:str_path
    bl    emit_str

    mov   w19, #0                    // row
.Lp_row:
    cmp   w19, #MAZE_H
    b.ge  .Lp_done
    mov   w20, #0                    // col
.Lp_col:
    cmp   w20, #MAZE_W
    b.ge  .Lp_rownext
    mov   w0, w19                    // address of cell (row,col)
    mov   w1, w20
    bl    cell_addr
    ldrb  w1, [x0]
    tst   w1, #F_PATH               // is this cell on the solution path?
    b.eq  .Lp_colnext
    mov   w0, #' '                  // print " (r,c)"
    bl    putchar
    mov   w0, #'('
    bl    putchar
    add   w0, w19, #'0'             // row digit  ('0'+row, single digit 0..7)
    bl    putchar
    mov   w0, #','
    bl    putchar
    add   w0, w20, #'0'             // col digit
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
    mov   x0, #0                     // flush so the line is on stdout before exit
    bl    fflush

    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #32
    ret
    .size print_path, .-print_path

/* ---------------------------------------------------------------------------
 * main(w0=argc, x1=argv) -> exit code  (0 solved, 1 not solved)
 *   - reads env MAZE_ANIM (=="0" -> quiet, for verify)
 *   - argv[1]=="1" selects the unsolvable maze, else the solvable one
 *   - runs solve() from the start cell, prints the canonical path line
 * Frame saves x19 (argc, then 'found'), x20 (argv), x21 (chosen grid base), x30.
 * ------------------------------------------------------------------------- */
    .global main
    .type main, %function
main:
    stp   x29, x30, [sp, #-48]!
    mov   x29, sp
    stp   x19, x20, [sp, #16]
    str   x21, [sp, #32]
    mov   w19, w0                    // save argc  (getenv below clobbers w0/x1)
    mov   x20, x1                    // save argv

    /* --- animation flag from environment: MAZE_ANIM=0 turns it off --------- */
    adrp  x0, str_env
    add   x0, x0, :lo12:str_env
    bl    getenv                     // x0 = value string or NULL
    mov   w2, #1                     // assume animation ON
    cbz   x0, .Lm_setanim            // unset -> stays ON
    ldrb  w3, [x0]                   // first char of the value
    cmp   w3, #'0'
    b.ne  .Lm_setanim
    mov   w2, #0                     // value begins with '0' -> animation OFF
.Lm_setanim:
    adrp  x0, g_anim
    add   x0, x0, :lo12:g_anim
    strb  w2, [x0]

    /* --- choose which maze: default grid0, "1" arg -> grid1 (unsolvable) --- */
    adrp  x0, grid0
    add   x0, x0, :lo12:grid0
    mov   x21, x0                    // default = solvable maze
    cmp   w19, #2                    // was an argv[1] supplied?
    b.lt  .Lm_setgrid
    ldr   x1, [x20, #8]             // x1 = argv[1]
    ldrb  w2, [x1]                  // first character of argv[1]
    cmp   w2, #'1'
    b.ne  .Lm_setgrid
    adrp  x0, grid1
    add   x0, x0, :lo12:grid1
    mov   x21, x0                    // selected the unsolvable maze
.Lm_setgrid:
    adrp  x0, grid_base            // publish the active grid base for everyone
    add   x0, x0, :lo12:grid_base
    str   x21, [x0]

    /* --- solve from the start cell ---------------------------------------- */
    mov   w0, #START_R
    mov   w1, #START_C
    bl    solve
    mov   w19, w0                   // w19 = found (1/0)

    bl    render                    // final frame (no-op if quiet)
    bl    print_path               // canonical "path: ..." line for verify

    /* --- exit code: 0 when solved, 1 when not ----------------------------- */
    cmp   w19, #0
    cset  w0, eq                    // found==0 -> 1 (not solved); else 0 (solved)

    ldr   x21, [sp, #32]
    ldp   x19, x20, [sp, #16]
    ldp   x29, x30, [sp], #48
    ret                            // returning from main -> libc exit(w0)
    .size main, .-main

    .section .note.GNU-stack,"",%progbits   /* mark stack non-executable */
