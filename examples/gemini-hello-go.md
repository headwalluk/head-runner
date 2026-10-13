---
title: Hello Go banner, centred in the terminal
engine: gemini
workdir: /home/you/Projects/hello-go
create_workdir: yes
permissions: bypass
timeout: 20m
---

# Hello Go banner, centred in the terminal

Write a small Go program that prints "Hello Go!" in large figlet-style lettering, centred
horizontally and vertically in the terminal.

## Requirements

- Module name `hello-go`, binary `hello-go`. Use the latest stable Go on this machine.
- **Lettering:** build the banner from a small font defined in the source: block letters at
  least 5 rows high, covering only the characters needed. Don't depend on the `figlet` program.
  Use plain ASCII or Unicode block characters (`█`) and measure width in runes, not bytes.
- **Centring:** read the terminal size at startup. Clear the screen. Print the banner so
  that its left and right margins differ by at most one column, and its top and bottom
  margins differ by at most one row. Leave the cursor below the banner when the program
  exits.
- **Too small:** if the terminal is smaller than the banner, plus one row/column of margin
  on each side, don't draw anything. Print an error to stderr giving the required and
  actual sizes, e.g. `hello-go: terminal too small: need 62x9, have 40x20`, and exit 1.
- **Not a terminal:** if stdout isn't a terminal, print a clear error to stderr and exit 1.
- **Dependencies:** standard library only, except `golang.org/x/term`, which is allowed
  for the terminal size check.
- Keep the layout logic in a pure function that takes the terminal width and height, for
  example `layout(banner []string, width, height int) (lines []string, err error)`, so it
  can be tested without a terminal.

## Done means

1. `gofmt -l .` prints nothing, and `go vet ./...` passes.
2. `go test ./...` passes. Cover these cases:
   - exact centring for even and odd spare space
   - the minimum size that fits
   - one column too narrow
   - one row too short
3. `go build -o hello-go .` succeeds.
4. `./hello-go > /tmp/hello-go.out; echo $?` reports the "not a terminal" error and `1`.
5. Run it in a real pseudo-terminal of a known size:
   - `script -qec "stty cols 100 rows 30; ./hello-go" /dev/null` draws the banner. Include
     the captured output in your response.
   - `script -qec "stty cols 30 rows 10; ./hello-go; echo exit=\$?" /dev/null` reports
     "too small" and `exit=1`.

Report each check's actual output in your response.
