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
# benchmark: name<TAB>ns/op<TAB>ratio to its plain-Lua baseline.
#
# `make bench BASE=<ref>` (task 011) checks <ref> out into build/base with
# `git worktree` (detached, recreated on every run) and, per interpreter,
# runs branch, base, branch, base: four bench/run.lua processes, the base
# ones on the base's lifetime/ with the branch's benchmark files
# (build/bench-<interpreter>-<n>.txt, build/bench-base-<interpreter>-<n>.txt,
# n = 1, 2). bench/compare.lua then prints per benchmark the ratio
# branch/base of each pairing and of the medians, marking SLOWER only when
# both pairings exceed the threshold of bench/README.md
# (build/bench-compare-<interpreter>.txt). `BASE_DIR=<dir>` compares with
# an existing tree instead of checking <ref> out, and never touches it
# (BASE then only names the base and turns the comparison on).
#
# Exit status: 1 when a branch run fails, when a base run prints no
# benchmark line at all, or when bench/compare.lua fails. A base run that
# fails only some benchmark files passes; its errors stay on stderr and
# compare prints "-" for what it could not run.
#
# BENCH_TIME sets the seconds per timed run (default 0.5); BENCH_FILES
# restricts the runs to the given benchmark files (default: every
# bench/bench-*.lua); BENCH_OUT is the output directory (default build).
# Not part of `make test`: it is slow and noisy.

INTERPRETERS ?= $(shell for i in lua5.1 luajit; do command -v $$i >/dev/null 2>&1 && echo $$i; done)
FIRST := $(firstword $(INTERPRETERS))
BASE ?=
BASE_WORKTREE := build/base
BASE_DIR ?= $(BASE_WORKTREE)
BENCH_FILES ?=
BENCH_OUT ?= build

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
	@mkdir -p $(BENCH_OUT)
	@if [ -n "$(BASE)" ] && [ "$(BASE_DIR)" = "$(BASE_WORKTREE)" ]; then \
		git rev-parse --verify --quiet "$(BASE)^{commit}" >/dev/null || { \
			echo "make: BASE=$(BASE) is not a commit" >&2; exit 1; }; \
		if [ -e $(BASE_WORKTREE) ]; then \
			git worktree remove --force $(BASE_WORKTREE) 2>/dev/null || rm -rf $(BASE_WORKTREE); fi; \
		git worktree prune; \
		git worktree add --quiet --detach $(BASE_WORKTREE) "$(BASE)" || exit 1; \
		echo "== base: $(BASE) at $$(git -C $(BASE_WORKTREE) rev-parse --short HEAD), checked out in $(BASE_WORKTREE)"; \
	elif [ -n "$(BASE)" ]; then \
		echo "== base: $(BASE), the existing tree $(BASE_DIR)"; \
	fi
	@status=0; \
	bench_to() { out=$$1; shift; \
		{ "$$@"; echo $$? >"$$out.status"; } | tee "$$out"; \
		code=$$(cat "$$out.status"); rm -f "$$out.status"; return $${code:-1}; }; \
	for i in $(INTERPRETERS); do \
		if [ -z "$(BASE)" ]; then \
			echo "== bench under $$i: name, ns/op, ratio to plain Lua ($(BENCH_OUT)/bench-$$i.txt)"; \
			bench_to $(BENCH_OUT)/bench-$$i.txt $$i bench/run.lua $(BENCH_FILES) || status=1; \
			continue; \
		fi; \
		rm -f $(BENCH_OUT)/bench-$$i-1.txt $(BENCH_OUT)/bench-$$i-2.txt \
			$(BENCH_OUT)/bench-base-$$i-1.txt $(BENCH_OUT)/bench-base-$$i-2.txt \
			$(BENCH_OUT)/bench-compare-$$i.txt; \
		for n in 1 2; do \
			echo "== bench under $$i, pairing $$n of 2, branch: name, ns/op, ratio to plain Lua ($(BENCH_OUT)/bench-$$i-$$n.txt)"; \
			bench_to $(BENCH_OUT)/bench-$$i-$$n.txt $$i bench/run.lua $(BENCH_FILES) || status=1; \
			echo "== bench under $$i, pairing $$n of 2, on the lifetime/ of $(BASE) ($(BENCH_OUT)/bench-base-$$i-$$n.txt)"; \
			bench_to $(BENCH_OUT)/bench-base-$$i-$$n.txt $$i bench/run.lua --lifetime $(BASE_DIR) $(BENCH_FILES); \
			if [ ! -s $(BENCH_OUT)/bench-base-$$i-$$n.txt ]; then \
				echo "make: bench under $$i: the base run of pairing $$n (lifetime/ of $(BASE) in $(BASE_DIR)) printed no benchmark line" >&2; \
				status=1; continue 2; \
			fi; \
		done; \
		echo "== branch/base under $$i: name, branch ns/op, base ns/op, pairing 1, pairing 2, branch/base, mark ($(BENCH_OUT)/bench-compare-$$i.txt)"; \
		bench_to $(BENCH_OUT)/bench-compare-$$i.txt $$i bench/compare.lua \
			$(BENCH_OUT)/bench-$$i-1.txt $(BENCH_OUT)/bench-base-$$i-1.txt \
			$(BENCH_OUT)/bench-$$i-2.txt $(BENCH_OUT)/bench-base-$$i-2.txt || status=1; \
	done; \
	exit $$status

clean:
	@if [ -e $(BASE_WORKTREE) ]; then git worktree remove --force $(BASE_WORKTREE) 2>/dev/null || true; fi
	rm -rf build
	@git worktree prune
