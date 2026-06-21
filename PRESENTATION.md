# 8-Minute Presentation Guide

A turnkey script for demoing the A64 Maze Runner. Total ≈ 8 minutes. The live
demo does the heavy lifting — you mostly narrate what's on screen.

> **Before you start:** open a **maximised** terminal on the Pi (so the maze +
> HUD don't scroll), and pre-build: `make all ref`. Optionally split the time
> across teammates — the routines in `maze.S` are small and each owns one idea.

The single best moment to sell: **"the call stack on screen IS the path."**
Keep coming back to that.

---

## Timeline

### 0:00 – 1:00 — The idea (no slides needed, or one diagram)
- "We wrote a maze solver in **pure ARM64 assembly** that runs natively on this Pi."
- Two course ideas in one program:
  - **Ch.4 (bits/data):** every cell is **one byte**; the 4 walls and the
    `seen`/`path`/`start`/`goal` state are individual **bits** in that byte.
    Movement uses **signed** deltas (two's complement, sign-extended).
  - **Ch.9 (A64):** load/store, scaled addressing, `cmp`/branch, and a
    **recursive** depth-first search using the real **AAPCS64 stack frame**.

### 1:00 – 3:30 — Watch it solve  (`make slow` while talking, or `make run`)
Run it and narrate the HUD live:
- "`R` (cyan) is the runner. Grey `.` are cells it has visited."
- **Point at `stack depth`:** "That's the live recursion depth — how many copies
  of `solve` are on the stack right now."
- **Point at `call stack`:** "These are the actual frames — the trail from the
  start cell to the runner. **This list is the path.**"
- **When it hits a dead end:** "No open direction — `solve` returns, the frame is
  popped (`backtracks` ticks up), and the runner **walks back**. That return is
  `ldp x29, x30 … ret` restoring the saved link register."
- When it reaches the goal: "Found it — now as each call returns it marks its cell
  on the path, so the **green path lights up from the goal back to the start**."
- "It finished with exit code **0** = solved."

> Tip: `make slow` (≈140 ms/step) is good while explaining; `make fast` for a
> quick re-run. You can also `MAZE_DELAY=200 ./build/maze` for very slow.

### 3:30 – 4:30 — The unsolvable maze  (`make unsolvable`)
- "Same assembly, different **data** — this maze has the goal walled off."
- "Watch it exhaust every reachable cell, backtrack all the way out, and report
  failure through the **exit code**: `1`." (`echo $?` shows it.)
- This is the Ch.4 point: behaviour changed by flipping **wall bits**, not code.

### 4:30 – 5:30 — Prove it's correct  (`make verify`)
- "How do we know the assembly is right? A **C reference** solves the *same* maze
  bytes in the *same* order and prints the *same* canonical line. We diff them."
- Run `make verify` → **PASS** for both mazes, both exit codes.
- "The maze is defined **once** in a shared header that both the assembly and the
  C include — so they can't silently drift apart."

### 5:30 – 7:00 — Show the real stack in gdb  (`make debug`)
This is the payoff that ties the visual to the assembly.
```
make debug
(gdb) break solve
(gdb) run
(gdb) bt                 # frames stack up as it goes deeper
(gdb) info reg x19 x20   # row / col held in callee-saved registers
(gdb) continue           # step the recursion; watch bt grow / shrink
```
- "Every line of this backtrace is one `solve` frame — exactly the on-screen
  `call stack`. The depth grows as we recurse and shrinks as we `ret`."
- Show the prologue/epilogue in `src/maze.S` (`stp x29, x30, [sp,#-64]!` …
  `ldp … ret`): "This is the calling convention — saving the frame pointer and
  return address so recursion works."

### 7:00 – 8:00 — Wrap + one code highlight
Pick **one** short routine and read it aloud (every line is commented). Good
choices:
- `wall_blocked` / `is_set` — "read one **bit**: `ldrb`, `and` with a mask, branch."
- `move` — "**signed** delta, `ldrsb` **sign-extends** −1 before we add it."
- `solve` prologue/epilogue — the recursion + calling convention.

Close: "One byte per cell, bits for walls, a recursive DFS where the **call stack
is the path** — verified against C, native on the Pi. Thanks."

---

## One-button option
`make demo` runs a **paused, guided** version of all of the above (it waits for
Enter between stages). Use it if you'd rather not type commands live.

## Cheat sheet (commands)
| Command | What it shows |
|---|---|
| `make run` | animated solve + live call-stack HUD |
| `make slow` / `make fast` | same, slower / faster (presenting) |
| `make unsolvable` | no-path maze, exit code 1 |
| `make verify` | A64 == C reference → PASS |
| `make debug` | gdb: `break solve`, `bt`, `info reg x19 x20` |
| `make demo` | hands-free guided walkthrough |

## If something goes wrong
- **Maze scrolls / looks broken:** terminal too short — maximise it, or use a
  smaller font; the maze + HUD need ~24 rows.
- **No colour:** `MAZE_COLOR=0 make run`, or your terminal lacks ANSI — the demo
  still works in plain text.
- **Too fast/slow:** `MAZE_DELAY=<ms> ./build/maze` (e.g. 150 slow, 15 fast).
