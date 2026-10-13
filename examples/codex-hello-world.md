---
title: Hello world in C with a Makefile
engine: codex
workdir: /home/you/Projects/hello-world
create_workdir: yes
permissions: edits
timeout: 15m
---

# Hello world in C with a Makefile

Create a minimal, traditional C "hello world" program in the working directory and build it.

## Requirements

- `hello.c`: prints `Hello, world!` followed by a newline, and returns 0. Standard C (C99 or
  later), no compiler extensions.
- `Makefile`: a conventional hand-written one, no generators.
  - Variables `CC ?= cc`, `CFLAGS ?= -std=c99 -Wall -Wextra -Wpedantic -O2`, `TARGET = hello`.
  - Targets: `all` (the default), `clean` and `run`. Mark them `.PHONY`.
  - Build the object file and link it as separate steps (`hello.o` → `hello`).
  - Recipe lines must use tabs.
- `.gitignore` ignoring `hello` and `*.o`.

## Done means

1. `make clean && make` builds with no warnings.
2. `./hello` prints exactly `Hello, world!` and exits 0.
3. `make run` does the same.
4. `make clean` removes `hello` and `hello.o`.
5. Running `make` twice in a row reports nothing to do the second time.

Report each check's actual output in your response.
