# ============================================================================
# Makefile -- CM-203 Project 2, A64 Maze Runner
#
# Native on the Raspberry Pi (aarch64) this Just Works:
#     make run          # build + watch the animated solve (with live call stack)
#     make unsolvable   # watch it fail on a maze with no path (exit code 1)
#     make slow / fast  # same solve, slower / faster animation (for presenting)
#     make bits         # decode cell bytes into labelled binary (Chapter 4)
#     make bytes        # dump the maze as a raw 8x8 hex grid (it IS just bytes)
#     make deltas       # signed deltas: two's complement & sign extension
#     make inspect      # all three data views, in sequence
#     make demo         # full guided walkthrough: data + search + assembly,
#                       #   split across 3 speakers (includes the slow solve)
#     make verify       # confirm the A64 result matches the C reference -> PASS
#     make debug        # break in solve(), inspect the recursive call stack
#
# Off a Pi (x86 dev box) with a cross toolchain + emulator, override CC and RUN:
#     make verify CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"
#
# Interface knobs (environment variables, read by the program):
#     MAZE_ANIM=0    quiet: no animation, just the canonical "path:" line
#     MAZE_COLOR=0   disable ANSI colour
#     MAZE_DELAY=N   per-step delay in milliseconds (default 45)
# ============================================================================

CC      ?= gcc                 # native cc on the Pi; override for cross builds
RUN     ?=                      # empty on the Pi; set to qemu-... for emulation
OBJDUMP ?= objdump             # for `make disasm`; cross: aarch64-linux-gnu-objdump
GDB     ?= gdb                 # for `make trace`;  cross: gdb-multiarch
FUNC    ?= solve               # which routine `make disasm` shows
CFLAGS  ?= -Wall -O2
BUILD    = build

.PHONY: all run unsolvable slow fast bits bytes deltas inspect disasm trace asm-tour demo debug ref verify clean

# --- assemble + link the A64 program (gcc drives cpp -> as -> ld, links libc) --
all: $(BUILD)/maze

$(BUILD)/maze: src/maze.S src/maze_data.h | $(BUILD)
	$(CC) src/maze.S -o $@

# --- build the C reference oracle --------------------------------------------
ref: $(BUILD)/maze_ref

$(BUILD)/maze_ref: src/maze_ref.c src/maze_data.h | $(BUILD)
	$(CC) $(CFLAGS) src/maze_ref.c -o $@

$(BUILD):
	mkdir -p $(BUILD)

# --- run it (animated) -------------------------------------------------------
run: all
	$(RUN) ./$(BUILD)/maze

# --- the unsolvable maze: searches everywhere, finds no path, exits 1 --------
unsolvable: all
	$(RUN) ./$(BUILD)/maze 1 ; echo "exit code: $$?"

# --- presentation pacing -----------------------------------------------------
slow: all
	MAZE_DELAY=140 $(RUN) ./$(BUILD)/maze
fast: all
	MAZE_DELAY=12 $(RUN) ./$(BUILD)/maze

# --- bit / data inspection views (Chapter 4: binary & data representation) ---
bits: all
	$(RUN) ./$(BUILD)/maze bits
bytes: all
	$(RUN) ./$(BUILD)/maze bytes
deltas: all
	$(RUN) ./$(BUILD)/maze deltas
inspect: all
	@$(RUN) ./$(BUILD)/maze bytes
	@$(RUN) ./$(BUILD)/maze bits
	@$(RUN) ./$(BUILD)/maze deltas

# --- assembly deep dive (Chapter 9: A64 + the calling convention) ------------
# disasm: show a routine's source interleaved with the real encoded instructions
#         (override the routine with FUNC=, e.g. `make disasm FUNC=move`)
disasm: src/maze.S src/maze_data.h | $(BUILD)
	$(CC) -g src/maze.S -o $(BUILD)/maze
	$(OBJDUMP) -S --disassemble=$(FUNC) ./$(BUILD)/maze

# trace: automated debugger run -- step into the recursion and show the real
#        stack frames stacking up (sp/x29 dropping 64 bytes per level)
trace: src/maze.S src/maze_data.h trace.gdb | $(BUILD)
	$(CC) -g src/maze.S -o $(BUILD)/maze
	$(GDB) -q -batch -x trace.gdb ./$(BUILD)/maze

# asm-tour: guided, paused deep dive (register roles, disassembly, live trace)
asm-tour:
	CC="$(CC)" OBJDUMP="$(OBJDUMP)" GDB="$(GDB)" ./asm-tour.sh

# --- guided, paused walkthrough: data + search + assembly, 3 speakers --------
#   Combines the behaviour demo AND the assembly deep dive into one flow,
#   split across 3 speakers and balanced by time (includes the SLOW solve).
demo:
	CC="$(CC)" OBJDUMP="$(OBJDUMP)" GDB="$(GDB)" RUN="$(RUN)" ./demo.sh

# --- debug: build with symbols and drop into gdb, ready to break in solve ----
debug: src/maze.S src/maze_data.h | $(BUILD)
	$(CC) -g src/maze.S -o $(BUILD)/maze
	gdb ./$(BUILD)/maze

# --- verify: A64 vs C reference, for BOTH the solvable and unsolvable maze ----
#   Compares the canonical "path: ..." line AND the exit code for each maze,
#   and asserts the exit-code contract (solvable=0, unsolvable=1).  Quiet mode
#   (MAZE_ANIM=0) suppresses animation so the output is a single clean line.
verify: all ref
	@echo "== verify: A64 result vs C reference =="; \
	rc=0; \
	for m in 0 1; do \
	  a_out=`MAZE_ANIM=0 $(RUN) ./$(BUILD)/maze $$m`;     a_rc=$$?; \
	  c_out=`MAZE_ANIM=0 $(RUN) ./$(BUILD)/maze_ref $$m`; c_rc=$$?; \
	  if [ "$$a_out" = "$$c_out" ] && [ "$$a_rc" = "$$c_rc" ]; then \
	    echo "  maze $$m: MATCH  (exit $$a_rc)"; \
	    echo "    $$a_out"; \
	  else \
	    echo "  maze $$m: MISMATCH"; \
	    echo "    A64 (exit $$a_rc): $$a_out"; \
	    echo "    C   (exit $$c_rc): $$c_out"; \
	    rc=1; \
	  fi; \
	  eval ec$$m=$$a_rc; \
	done; \
	if [ "$$ec0" != "0" ]; then echo "  FAIL: solvable maze must exit 0 (got $$ec0)"; rc=1; fi; \
	if [ "$$ec1" != "1" ]; then echo "  FAIL: unsolvable maze must exit 1 (got $$ec1)"; rc=1; fi; \
	if [ $$rc -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi

# --- housekeeping ------------------------------------------------------------
clean:
	rm -rf $(BUILD)
