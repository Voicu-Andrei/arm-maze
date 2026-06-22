# CM-203 Project 2 — ARM64 (A64) Maze Runner

A maze solver written in **pure AArch64 / A64 assembly** that runs **natively on a
Raspberry Pi** and animates its depth-first search in the terminal — in colour, with a
**live readout of the recursion**: the current **stack depth**, the running **call stack**
of cells, cells visited, and backtracks. The runner explores, **backtracks** at dead ends
(physically walking back), and lights up the final path as the recursion unwinds. The
result is checked against a C reference and returned via the process **exit code**.

```
+---+---+---+---+---+---+---+---+
| S   .   .   .   . | . | . | . |
+---+   +---+   +---+   +   +   +
|     . | . | . | . | R         |
...
+---+---+---+---+---+---+---+---+
  cells visited: 21    stack depth: 13/16    backtracks: 8
  call stack:  (0,0) -> ... -> (3,3) -> (3,4) -> (2,4) -> (2,5) -> (1,5)
  status: searching...
  legend:  R runner   * path   . visited   S start   G goal
```

The **call stack** line is the whole point made visible: it is exactly the chain of live
`solve` frames (start → runner), and you watch it grow on recursion and shrink on `ret`.

`S` start · `R` runner (current cell) · `*` solution path · `.` visited/backtracked ·
`G` goal (until reached) · walls drawn from the cell's wall bits.

> **Presenting this?** See **[PRESENTATION.md](PRESENTATION.md)** for a 3-speaker script,
> and run **`make demo`** — one hands-free, paused walkthrough that combines the
> behaviour demo and the assembly deep dive (with speaker hand-off cards).

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
make run          # build, then watch it solve (animated, with the call-stack HUD)
make unsolvable   # the no-path maze: searches, fails, exits 1
make slow / fast  # same solve, slower / faster animation (handy when presenting)
make bits         # decode cell bytes into labelled binary       (Chapter 4)
make bytes        # dump the maze as a raw 8x8 hex grid           (Chapter 4)
make deltas       # signed deltas: two's complement & sign ext.   (Chapter 4)
make inspect      # all three data views in sequence
make demo         # full guided walkthrough (data + search + assembly, 3 speakers)
make verify       # build A64 + C reference, compare results -> PASS
make debug        # build with -g and open gdb, ready to break in solve()
make ref          # build only the C reference
make clean        # remove build/
```

### Going deeper — visualise the raw bytes and bits (Chapter 4)

Three static sub-commands let you inspect the data representation directly. They
take no animation and are ideal for talking through:

```bash
./build/maze bytes      # the maze IS 64 bytes -- shown as an 8x8 hex grid
./build/maze bits       # decode cell bytes:  (0,0) = 0x4D = 0100 1101  + labels
./build/maze deltas     # signed move deltas: -1 = 1111 1111, ldrsb -> 0xFFFFFFFF
```

For example, `maze bits` prints, per cell, the byte in hex and **binary** with every
bit labelled (`walls: N E S W`, `state: seen path start goal`); `maze deltas` shows
two's complement and how `ldrsb` **sign-extends** a −1 delta where `ldrb` would not.
During an animated solve the HUD also shows the **runner cell's byte live in binary**,
so you can watch the `seen` and `path` bits flip as the search runs.

### Going deeper — the assembly itself (Chapter 9)

Three commands drop below the source to the real machine code and the live stack:

```bash
make disasm           # solve() with source comments interleaved with the
                      #   actual encoded instructions (FUNC=move, cell_addr, ...)
make trace            # automated gdb run: step into the recursion and watch the
                      #   real stack frames stack up (sp/x29 drop 64 bytes/level)
make asm-tour         # guided, paused deep dive: register roles -> disassembly
                      #   -> prologue/epilogue -> live debugger trace
```

`make disasm` shows, e.g., `ldrsb w4, [x3, w2, sxtw]` next to its encoding `0x38e2c864`,
and the `solve` skeleton reveals `bl <solve>` — the function branching to its *own*
address (recursion) — bracketed by the `stp …` prologue and `ldp … ret` epilogue.
`make trace` prints a backtrace of nested `solve` frames — exactly the on-screen
"call stack", now with real addresses. (Both need `gdb`/`objdump`, already on the Pi.)

Native on the Pi needs no special flags — `make` invokes `gcc src/maze.S` which runs the
preprocessor, assembler, and linker, and links against libc in one step.

### Try the unsolvable maze (exit-code demo)

```bash
./build/maze        # solvable maze   -> animates, exit code 0
./build/maze 1      # goal walled off -> no path,  exit code 1   (or: make unsolvable)
echo $?             # inspect the exit code
```

### Interface knobs (environment variables)

| Variable | Effect |
|---|---|
| `MAZE_ANIM=0`  | quiet mode: no animation, just the canonical `path:` line (used by `make verify`) |
| `MAZE_COLOR=0` | disable ANSI colour (plain text) |
| `MAZE_DELAY=N` | per-step delay in **milliseconds** (default `45`; e.g. `150` slow, `15` fast) |

```bash
MAZE_ANIM=0 ./build/maze        # -> "path: (0,0) (0,1) ... (7,7)"
MAZE_DELAY=150 ./build/maze     # slow enough to narrate each step
MAZE_COLOR=0 ./build/maze       # plain text (e.g. for logging / a B&W terminal)
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
├── PRESENTATION.md      # talk script (3 speakers, balanced by time)
├── Makefile             # build/run/inspect/disasm/trace/verify/... targets
├── demo.sh              # combined 3-speaker walkthrough (used by `make demo`)
├── asm-tour.sh          # guided assembly deep dive (used by `make asm-tour`)
├── trace.gdb            # automated debugger recursion trace (used by `make trace`)
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
| `push_cell`/`pop_cell` | mirror the live call stack for the HUD |
| `emit_uint` | print a number — itself recursive (another tiny call-stack demo) |
| `render` / `emit_hud` | animate the grid + live recursion readout (non-variadic libc) |
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
