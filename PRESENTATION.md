# 8-Minute Presentation Guide (3 speakers, terminal-only)

No slides — the program *is* the presentation. Three speakers, ~8 minutes.
The live demos carry it; you narrate what's on screen.

> **Before you start:** maximise the terminal on the Pi (so the maze + HUD don't
> scroll — it needs ~24 rows), and pre-build: `make all ref`.
>
> One-button option: **`make demo`** runs this whole flow paused between stages
> (it even labels which speaker is up). Use it if you'd rather not type live.

The thesis to keep hammering: **a maze is just bytes and bits, and the recursive
call stack you see on screen IS the path.**

---

## Speaker 1 — “It’s all bytes and bits” (Chapter 4) · ~2.5 min

**0:00 – 0:30 — Framing.** "We wrote a maze solver in **pure ARM64 assembly**,
running natively on this Pi. No graphics library — just bytes, bits, and the CPU."

**0:30 – 1:10 — The maze is data.** Run:
```
make bytes
```
- "The entire maze is **64 bytes** in `.data` — one byte per cell, row-major."
- "Address of a cell is `base + row*8 + col` — that's scaled addressing in `madd`."

**1:10 – 2:00 — Inside one byte.** Run:
```
make bits
```
- "Each byte is **8 bits**: the low nibble is the four **walls** (N/E/S/W), the
  high nibble is **state** — seen, path, start, goal."
- Point at `(0,0) = 0x4D = 0100 1101`: "Reading a wall is one `ldrb` + `and` with
  a mask. Setting `seen` is `ldrb` → `orr` → `strb`."

**2:00 – 2:30 — Signed deltas.** Run:
```
make deltas
```
- "Moving north is row **−1**. In a byte that's `1111 1111` — **two's complement**.
  `ldrsb` **sign-extends** it to `0xFFFFFFFF` so the add actually subtracts 1."
- "Use `ldrb` instead and you'd get 255 — wrong direction. This is the whole
  point of signed loads." *(Hand off to Speaker 2.)*

---

## Speaker 2 — “Watch the recursion run” (Chapter 9) · ~3 min

**2:30 – 4:30 — The animated solve.** Run (slow enough to talk over):
```
make slow      # or: make run
```
Narrate the HUD live:
- "`R` (cyan) is the runner; grey `.` are visited cells."
- **`runner cell` line:** "That's the current cell's byte in **binary** — watch the
  **seen bit flip 0→1** the moment we step in. That's the `orr` from Speaker 1."
- **`stack depth`:** "The live recursion depth — how many `solve` calls are on the
  stack right now."
- **`call stack`:** "These are the actual frames, start → runner. **This list is
  the path.**"
- **At a dead end:** "No open direction — `solve` returns, the frame is **popped**
  (`backtracks` ticks up), and the runner **walks back**. That return is
  `ldp x29, x30 … ret` restoring the saved link register."
- **At the goal:** "Found it — as each call returns it marks its cell, so the
  **green path lights up from the goal back to the start.** Exit code 0."

**4:30 – 5:30 — Unsolvable maze.** Run:
```
make unsolvable
```
- "Same assembly, different **data** — the goal is walled off. It searches every
  reachable cell, backtracks all the way out, and reports failure via the
  **exit code: 1**." *(Hand off to Speaker 3.)*

---

## Speaker 3 — “Prove it’s right” · ~2 min + buffer

**5:30 – 6:30 — Verify against C.** Run:
```
make verify
```
- "How do we know the assembly is correct? A **C reference** solves the *same*
  maze bytes in the *same* order and prints the *same* canonical line — we diff
  them for both mazes. **PASS.**"
- "The maze is defined **once** in a header both the assembly and the C `#include`,
  so they can't silently drift apart."

**6:30 – 7:45 — The real stack in gdb.** Run:
```
make debug
(gdb) break solve
(gdb) run
(gdb) bt                 # frames stack up as it recurses
(gdb) info reg x19 x20   # row / col, held in callee-saved registers
(gdb) continue
```
- "Every line of this backtrace is one `solve` frame — **exactly** the on-screen
  `call stack`. It grows as we recurse and shrinks as we `ret`."
- Optionally show the prologue/epilogue in `src/maze.S`
  (`stp x29, x30, [sp,#-64]!` … `ldp … ret`).

**7:45 – 8:00 — Close.** "One byte per cell, bits for walls, signed deltas, and a
recursive DFS where the **call stack is the path** — verified against C, running
native on the Pi. Thanks."

---

## Command cheat sheet
| Command | Owner | Shows |
|---|---|---|
| `make bytes` | S1 | maze as a 64-byte hex grid |
| `make bits` | S1 | cell bytes decoded into labelled binary |
| `make deltas` | S1 | signed deltas, two's complement, sign extension |
| `make slow` / `make run` / `make fast` | S2 | animated solve + live call stack + live byte |
| `make unsolvable` | S2 | no-path maze, exit code 1 |
| `make verify` | S3 | A64 == C reference → PASS |
| `make debug` | S3 | gdb: `break solve`, `bt`, `info reg x19 x20` |
| `make demo` | all | hands-free, paused, labelled walkthrough |

## If something goes wrong
- **Maze scrolls / looks broken:** terminal too short — maximise it or shrink the
  font; the maze + HUD need ~24 rows.
- **No colour:** `MAZE_COLOR=0 make run`, or the terminal lacks ANSI — still works
  in plain text.
- **Too fast / slow:** `MAZE_DELAY=<ms> ./build/maze` (e.g. 150 slow, 15 fast).
