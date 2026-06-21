/* ============================================================================
 * maze_ref.c -- C reference solver for the A64 maze (verification oracle).
 *
 * It uses the SAME maze bytes (via maze_data.h) and the SAME DFS direction order
 * (N, E, S, W) as src/maze.s, and prints the SAME canonical line:
 *     path: (r,c) (r,c) ...
 * with the SAME exit code (0 solved / 1 not).  `make verify` diffs the two.
 *
 * Deliberately plain C -- no animation; this exists only to confirm the
 * assembly's result is sound across the whole maze.
 * ==========================================================================*/
#include <stdio.h>
#include <string.h>
#include "maze_data.h"

/* flag bits (walls live in the low nibble; see maze_data.h / README) */
enum { SEEN = 0x10, PATH = 0x20, GOAL = 0x80 };

/* working grid (mutated in place, exactly like the asm) */
static unsigned char grid[MAZE_H * MAZE_W];

/* the two source mazes, expanded from the shared single-source macros */
static const unsigned char maze0[MAZE_H * MAZE_W] = { MAZE_BYTES };
static const unsigned char maze1[MAZE_H * MAZE_W] = { MAZE2_BYTES };

/* signed deltas + wall masks, order N, E, S, W -- identical to the asm tables */
static const int           drow[4]  = { -1,  0,  1,  0 };
static const int           dcol[4]  = {  0,  1,  0, -1 };
static const unsigned char wmask[4] = { 0x01, 0x02, 0x04, 0x08 };

static int idx(int r, int c) { return r * MAZE_W + c; }

/* Recursive DFS mirroring solve() in maze.s:
 *   mark seen on entry, stop if already seen, report found at the goal,
 *   otherwise try N,E,S,W; set PATH on the way back up a successful branch. */
static int solve(int r, int c)
{
    unsigned char *cell = &grid[idx(r, c)];
    if (*cell & SEEN) return 0;              /* already visited -> dead branch */
    *cell |= SEEN;                           /* mark visited                   */
    if (*cell & GOAL) { *cell |= PATH; return 1; }

    for (int d = 0; d < 4; d++) {
        if (*cell & wmask[d]) continue;      /* wall this way -> skip          */
        int nr = r + drow[d], nc = c + dcol[d];
        if (nr < 0 || nr >= MAZE_H || nc < 0 || nc >= MAZE_W) continue; /* bounds */
        if (grid[idx(nr, nc)] & SEEN) continue;
        if (solve(nr, nc)) { *cell |= PATH; return 1; }  /* found below -> on path */
    }
    return 0;                                /* dead end -> backtrack          */
}

int main(int argc, char **argv)
{
    const unsigned char *src = maze0;
    if (argc >= 2 && argv[1][0] == '1') src = maze1;   /* '1' -> unsolvable maze */
    memcpy(grid, src, sizeof grid);

    int found = solve(START_R, START_C);

    /* canonical, machine-comparable line: PATH cells in row-major order */
    fputs("path:", stdout);
    for (int r = 0; r < MAZE_H; r++)
        for (int c = 0; c < MAZE_W; c++)
            if (grid[idx(r, c)] & PATH) {
                putchar(' '); putchar('(');
                putchar('0' + r); putchar(',');   /* coords 0..7 -> one digit */
                putchar('0' + c); putchar(')');
            }
    putchar('\n');

    return found ? 0 : 1;                     /* same exit-code contract as asm */
}
