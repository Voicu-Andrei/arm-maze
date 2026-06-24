# Presentation Guide — 3 speakers, terminal only

No slides. One command runs the whole thing:

```bash
make demo
```

`make demo` is a single guided walkthrough that combines the **behaviour demo**
and the **assembly deep dive**. It shows a full-screen **hand-off card** before
each speaker and **waits at every slide** — including after the maze finishes
solving (keystrokes pressed *during* the animation are discarded, so it never
skips ahead). Navigate with:

```
  [Enter] / n   next slide
  b / p         back to the previous slide
  r             replay this slide  (re-run the maze, re-show a view)
  q             quit
```

You just narrate what's on screen; press `b` if you need to revisit a slide, or
`r` to replay the solve.

> Maximise the terminal first (the maze + HUD need ~24 rows). Total run ≈ **10 min**.
> To land nearer 8, skip the slides marked **[trim]** below.

The slides are split across 3 speakers and **balanced by time** — not by count —
because the slow solve alone is ~2 minutes, so Speaker 2 owns fewer slides.

**The one thesis to keep repeating:** *the recursion you watch on screen IS the
call stack.*

---

## Speaker 1 — “It’s all bytes and bits” (Chapter 4) · ~3:00

| Slide | ~Time | You say |
|---|---|---|
| 1. maze as 64 raw bytes (`bytes`) | 0:45 | "The whole maze is **64 bytes** in `.data`, one per cell. A cell address is `base + row*8 + col` — that's the `madd` instruction." |
| 2. inside one byte (`bits`) | 0:55 | "Each byte is 8 bits: low nibble = the four **walls**, high nibble = **state** (seen/path/start/goal). Reading a wall is `ldrb` + `and`; setting `seen` is `ldrb`→`orr`→`strb`." |
| 3. signed deltas (`deltas`) | 0:50 | "North is row **−1** = `1111 1111` in two's complement. `ldrsb` **sign-extends** it to `0xFFFFFFFF` so the add subtracts 1. `ldrb` would give 255 — wrong." |

(+ the ~0:30 title/framing card.)

## Speaker 2 — “Watch it think” (the search) · ~3:25

| Slide | ~Time | You say |
|---|---|---|
| 1. the **slow** animated solve | 2:00 | Narrate the HUD: **`stack depth`** = live recursion depth; **`call stack`** = the live frames, *this list is the path*; **`runner cell`** = that cell's byte in binary, watch the **`seen` bit flip**; on a dead end the frame **pops and the runner walks back**; at the goal the **green path lights up** back to the start. |
| 2. unsolvable maze | 0:50 | "Same assembly, different **data** — goal walled off. It searches everything, backtracks all the way out, and reports failure via **exit code 1**." |
| 3. verify vs C **[trim]** | 0:35 | "A **C reference** solves the same bytes in the same order; we diff them — **PASS**. Same maze defined once in a shared header, so they can't drift." |

## Speaker 3 — “Down to the metal” (Chapter 9 / AAPCS64) · ~3:30

| Slide | ~Time | You say |
|---|---|---|
| 1. register roles | 0:45 | "`x0–x7` args; `x19–x28` **callee-saved** (we keep row/col there across recursion); `x29` frame pointer; `x30` link register — where `ret` returns; `sp` grows down. Recursion works because each call saves its **own** `x30`." |
| 2. `move()` disassembled | 0:45 | "Source comment, mnemonic, and the 32-bit encoding `0x38e2c864` are the **same** `ldrsb` — the sign-extending load from Speaker 1, for real." |
| 3. `solve()` prologue/call/epilogue | 0:50 | "`stp x29, x30, [sp,#-64]!` pushes the frame; **`bl <solve>` branches to its own address** — that's the recursion; `ldp … ret` restores the frame and returns." |
| 4. **live** gdb trace **[trim]** | 0:55 | "Stepping into the recursion: `x29`/`sp` drop by exactly **0x40 = 64 bytes** per level, then a backtrace of nested `solve` frames. **This is the on-screen call stack — for real.**" |

(+ the ~0:15 wrap card: "bytes, bits, signed deltas, and a recursive DFS where the
call stack is the path — pure A64, verified against C, native on the Pi. Thanks.")

---

## Individual commands (for rehearsal / Q&A)
Everything `make demo` does is also a standalone target:

| Command | Owner | Shows |
|---|---|---|
| `make bytes` / `bits` / `deltas` | S1 | the data views |
| `make slow` (or `run` / `fast`) | S2 | animated solve + live call stack + live byte |
| `make unsolvable` | S2 | no-path maze, exit code 1 |
| `make verify` | S2 | A64 == C reference → PASS |
| `make disasm` (`FUNC=move`, …) | S3 | source interleaved with real machine code |
| `make trace` | S3 | automated gdb: stack frames stacking up |
| `make asm-tour` | S3 | just the assembly deep-dive, guided |
| `make debug` | S3 | manual gdb: `break solve`, `bt`, `info reg x19 x20` |

## If something goes wrong
- **Maze scrolls / looks broken:** terminal too short — maximise it or shrink the
  font; the maze + HUD need ~24 rows.
- **No colour:** `MAZE_COLOR=0 make run`, or the terminal lacks ANSI — still works
  in plain text.
- **Solve too slow / fast for the room:** the demo uses `MAZE_DELAY=130`; override
  with `MAZE_DELAY=90 make demo` (faster) or `200` (slower).
- **`make trace` / `make disasm` error:** need `gdb` / `objdump` — already present
  on the Pi via `build-essential gdb`.
