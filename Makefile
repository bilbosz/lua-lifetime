# `make test` runs everything (CLAUDE.md, "Rules that apply to everyone",
# rule 8): the unit suite under every interpreter found on PATH among
# lua5.1 and luajit, then the conformance suite once, which itself runs
# every example under every interpreter found (tests/conformance.lua).
# At least one interpreter must be present. Override the list with
# `make test INTERPRETERS="luajit"`.
#
# `make lint` runs luacheck over the runtime, the transpiler, the tests,
# the benchmarks and the command (config in .luacheckrc).
#
# `make bench` (task 010; CLAUDE.md, rule 5) runs bench/run.lua under every
# interpreter found and writes build/bench-<interpreter>.txt, one line per
# benchmark: name<TAB>ns/op<TAB>ratio to its plain-Lua baseline. `make
# bench BASE=<ref>` also checks <ref> out into build/base with `git
# worktree` (detached, recreated on every run), runs the same benchmark
# files, the branch's, on the base's lifetime/ (build/bench-base-*.txt),
# and prints the ratio branch/base per benchmark, marking each beyond the
# threshold of bench/README.md (build/bench-compare-*.txt). BENCH_TIME
# sets the seconds per timed run (default 0.5). Not part of `make test`:
# it is slow and noisy.

INTERPRETERS ?= $(shell for i in lua5.1 luajit; do command -v $$i >/dev/null 2>&1 && echo $$i; done)
FIRST := $(firstword $(INTERPRETERS))
BASE ?=
BASE_DIR := build/base

.PHONY: test unit conformance lint bench clean

test: unit conformance

unit:
	@if [ -z "$(INTERPRETERS)" ]; then \
		echo "make: neither lua5.1 nor luajit found on PATH" >&2; exit 1; fi
	@for i in $(INTERPRETERS); do \
		echo "== unit suite under $$i"; \
		$$i tests/run.lua unit || exit 1; \
	done

conformance:
	@if [ -z "$(FIRST)" ]; then \
		echo "make: neither lua5.1 nor luajit found on PATH" >&2; exit 1; fi
	@echo "== conformance suite (driver: $(FIRST); examples run under every interpreter found)"
	@$(FIRST) tests/run.lua conformance

lint:
	luacheck lifetime tests bench bin/lifetime

bench:
	@if [ -z "$(INTERPRETERS)" ]; then \
		echo "make: neither lua5.1 nor luajit found on PATH" >&2; exit 1; fi
	@mkdir -p build
	@if [ -n "$(BASE)" ]; then \
		git rev-parse --verify --quiet "$(BASE)^{commit}" >/dev/null || { \
			echo "make: BASE=$(BASE) is not a commit" >&2; exit 1; }; \
		if [ -e $(BASE_DIR) ]; then \
			git worktree remove --force $(BASE_DIR) 2>/dev/null || rm -rf $(BASE_DIR); fi; \
		git worktree prune; \
		git worktree add --quiet --detach $(BASE_DIR) "$(BASE)" || exit 1; \
		echo "== base: $(BASE) at $$(git -C $(BASE_DIR) rev-parse --short HEAD), checked out in $(BASE_DIR)"; \
	fi
	@status=0; \
	for i in $(INTERPRETERS); do \
		echo "== bench under $$i: name, ns/op, ratio to plain Lua (build/bench-$$i.txt)"; \
		{ $$i bench/run.lua; echo $$? >build/bench-$$i.status; } | tee build/bench-$$i.txt; \
		[ "$$(cat build/bench-$$i.status)" = 0 ] || status=1; \
		rm -f build/bench-$$i.status; \
		if [ -n "$(BASE)" ]; then \
			echo "== bench under $$i on the lifetime/ of $(BASE) (build/bench-base-$$i.txt)"; \
			$$i bench/run.lua --lifetime $(BASE_DIR) | tee build/bench-base-$$i.txt; \
			echo "== branch/base under $$i: name, branch ns/op, base ns/op, ratio, mark (build/bench-compare-$$i.txt)"; \
			$$i bench/compare.lua build/bench-$$i.txt build/bench-base-$$i.txt | tee build/bench-compare-$$i.txt; \
		fi; \
	done; \
	exit $$status

clean:
	@if [ -e $(BASE_DIR) ]; then git worktree remove --force $(BASE_DIR) 2>/dev/null || true; fi
	rm -rf build
	@git worktree prune
