# `make test` runs everything (CLAUDE.md, "Rules that apply to everyone",
# rule 8): the unit suite under every interpreter found on PATH among
# lua5.1 and luajit, then the conformance suite once, which itself runs
# every example under every interpreter found (tests/conformance.lua).
# At least one interpreter must be present. Override the list with
# `make test INTERPRETERS="luajit"`.
#
# `make lint` runs luacheck over the runtime, the transpiler, the tests and
# the command (config in .luacheckrc).

INTERPRETERS ?= $(shell for i in lua5.1 luajit; do command -v $$i >/dev/null 2>&1 && echo $$i; done)
FIRST := $(firstword $(INTERPRETERS))

.PHONY: test unit conformance lint clean

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
	luacheck lifetime tests bin/lifetime

clean:
	rm -rf build
