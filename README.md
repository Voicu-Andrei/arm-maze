# CM-203 Project 2 — ARM64 (A64) Maze Runner

A maze solver written in **pure AArch64 / A64 assembly** that runs **natively on a
Raspberry Pi** and animates its depth-first search in the terminal. The runner explores,
**backtracks** at dead ends, and lights up the final path as the recursion unwinds. The
result is checked against a C reference and returned via the process **exit code**.

```
+---+---+---+---+---+---+---+---+
| S   *   .   .   . | . | . | . |
+---+   +---+   +---+   +   +   +
|     * | . | . | . | .   .   . |
+---+   +   +---+   +   +---+   +
| *   * | .   . | *   *   * | . |
+   +---+   +---+   +---+   +---+
| *   *   *   *   *     | *   * |
+   +   +---+   +---+---+   +   +
|   |   |   |           |   | * |
...
path: (0,0) (0,1) (1,1) (2,0) ... (7,7)
```

`S` start · `R` runner (current cell) · `*` solution path · `.` visited/backtracked ·
`G` goal (until reached) · walls drawn from the cell's wall bits.

---

## What it demonstrates

- **Ch.4 — Binary & Data Representation:** one **byte per cell**; walls and state packed
  into individual **bits** (`and`/`orr`/`bic` masks); movement uses **signed** deltas
  (two's complement) with **sign extension** (`ldrsb`).
- **Ch.9 — ARM64 / A64:** GNU toolchain (assemble + link via `gcc`); `ldrb`/`strb`;
  scaled addressing (`madd`); `cmp` + `b.cond` / `cbz` / `cbnz`; and the **AAPCS64
  calling convention** — `stp`/`ldp`, `x29`, `x30`, and a real stack frame — via a
  **recursive** DFS where the **call stack literally is the trail** from start to runner.

---

## Build / run / debug / verify (on the Pi)

Requires a 64-bit OS (`uname -m` → `aarch64`) and `build-essential gdb git`.

```bash
make run        # build, then watch it solve (animated)
make verify     # build A64 + C reference, compare results -> PASS
make debug      # build with -g and open gdb, ready to break in solve()
make ref        # build only the C reference
make clean      # remove build/
```

Native on the Pi needs no special flags — `make` invokes `gcc src/maze.S` which runs the
preprocessor, assembler, and linker, and links against libc in one step.

### Try the unsolvable maze (exit-code demo)

```bash
./build/maze        # solvable maze   -> animates, exit code 0
./build/maze 1      # goal walled off -> no path,  exit code 1
echo $?             # inspect the exit code
```

### Quiet mode

Set `MAZE_ANIM=0` to suppress the animation and print only the canonical result line
(this is what `make verify` uses so its diff is clean and instant):

```bash
MAZE_ANIM=0 ./build/maze        # -> "path: (0,0) (0,1) ... (7,7)"
```

### Debugging the recursion

```bash
make debug
(gdb) break solve
(gdb) run
(gdb) bt          # each frame is one cell on the current trail
(gdb) info reg x19 x20   # this frame's row / col
(gdb) continue
```

---

## Off-Pi testing (optional, x86 dev box)

You can build and run under emulation with a cross toolchain + QEMU:

```bash
sudo apt install -y gcc-aarch64-linux-gnu qemu-user
make verify CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"
make run    CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"
```

Native on the Pi remains the primary demo. (This repo was developed and verified this way:
the A64 build matches the C reference for both the solvable and unsolvable maze — **PASS**.)

---

## Data model — the cell byte

The maze is a `MAZE_W × MAZE_H` array of bytes, one byte per cell, **row-major**:

```
cell_addr = grid_base + row * MAZE_W + col
```

Each byte packs **walls** in the low nibble and **state** in the high nibble:

| Bit | Mask  | Meaning                       |
|-----|-------|-------------------------------|
| 0   | 0x01  | North wall present            |
| 1   | 0x02  | East wall present             |
| 2   | 0x04  | South wall present            |
| 3   | 0x08  | West wall present             |
| 4   | 0x10  | `seen`  — runner has visited  |
| 5   | 0x20  | `path`  — on the final path   |
| 6   | 0x40  | `start` cell                  |
| 7   | 0x80  | `goal`  cell                  |

**Directions and signed deltas** (note the negatives — these exercise two's complement
and sign extension; the DFS tries them in this fixed order):

| Dir | Wall mask | drow | dcol |
|-----|-----------|------|------|
| N   | 0x01      | −1   |  0   |
| E   | 0x02      |  0   | +1   |
| S   | 0x04      | **+1** |  0   |
| W   | 0x08      |  0   | −1   |

> **Correction vs. the original brief:** the brief's §4 table listed South in the
> *column* slot (`drow=0, dcol=−1→+1`), contradicting its own note. South is a **row**
> move: `drow = +1, dcol = 0` (south increases the row index). This repo implements the
> corrected values, and the same table feeds the verification, so it's confirmed correct.

Walls are kept **symmetric** (if cell A has an east wall, its eastern neighbour has a west
wall), so checking the current cell's wall bit alone is sufficient.

---

## Repository layout

```
.
├── README.md            # this file
├── Makefile             # all, run, debug, ref, verify, clean
├── src/
│   ├── maze.S           # the A64 implementation (heavily commented)
│   ├── maze_data.h      # SINGLE SOURCE of the maze bytes/dims (shared by asm + C)
│   └── maze_ref.c       # C reference: same maze, same DFS order, for verification
└── .gitignore
```

### Routines in `src/maze.S`

| Routine | Idea it demonstrates |
|---|---|
| `cell_addr` | scaled addressing (`madd row,#W,col` + base) |
| `wall_blocked` / `is_set` | read one **bit**: `ldrb` → `and` → branch |
| `mark` / `unmark` | read-modify-write flags: `ldrb` → `orr`/`bic` → `strb` |
| `move` | **signed** deltas with **sign extension** (`ldrsb`) |
| `in_bounds` | `cmp` + `b.cond` guards (defensive bounds check) |
| `solve` | **recursive DFS** — `stp`/`ldp` prologue/epilogue, `x30`, callee-saved regs |
| `render` | animate the grid (libc `putchar`/`fflush`/`usleep`, non-variadic) |
| `main` | env/argv handling, run, canonical output, exit code |

---

## How the maze data stays trustworthy

`src/maze_data.h` defines the maze **once**, as macros that expand in *both* assembly and C:

```c
#define MAZE_BYTES  0x4D, 0x01, ...      /* asm:  .byte MAZE_BYTES                */
                                          /* C:    unsigned char g[] = {MAZE_BYTES} */
```

So `maze.S` and `maze_ref.c` can never drift apart. The maze was produced by a
randomized-Prim generator and **verified solvable**; the unsolvable variant
(`MAZE2_BYTES`) seals the goal cell on all four sides. `make verify` runs both mazes
through both solvers, compares the canonical `path:` line, and asserts the exit-code
contract (solvable → 0, unsolvable → 1).

---

## Acceptance criteria

- [x] `uname -m` = `aarch64`; `make run` builds and animates the solve.
- [x] Runner explores, marks `seen`, **backtracks**, highlights the final `path`.
- [x] `solve` is genuinely **recursive** with a correct prologue/epilogue; `make debug`
      shows call-stack frames matching the current trail.
- [x] Walls/flags read & written by **bit masking** (`and`/`orr`/`bic` + load/store).
- [x] At least one path uses **signed deltas with sign extension** (`ldrsb` in `move`).
- [x] Exit code `0` solved, `1` not — both exercised by `make verify`.
- [x] `make verify` prints **PASS** (A64 matches the C reference).
- [x] Every instruction in `maze.S` is commented.
