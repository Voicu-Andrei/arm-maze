# ============================================================================
# Makefile -- CM-203 Project 2, A64 Maze Runner
#
# Native on the Raspberry Pi (aarch64) this Just Works:
#     make run        # build + watch the animated solve
#     make verify     # confirm the A64 result matches the C reference -> PASS
#     make debug      # break in solve(), inspect the recursive call stack
#
# To build/run OFF a Pi (x86 dev box) with a cross toolchain + emulator, override:
#     make verify CC=aarch64-linux-gnu-gcc RUN="qemu-aarch64 -L /usr/aarch64-linux-gnu"
# ============================================================================

CC      ?= gcc                 # native cc on the Pi; override for cross builds
RUN     ?=                      # empty on the Pi; set to qemu-... for emulation
CFLAGS  ?= -Wall -O2
BUILD    = build

.PHONY: all run debug ref verify clean

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
