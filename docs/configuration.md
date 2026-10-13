# Configuration

headrun reads one optional file, `~/.config/headrun/config`. Every setting has a default,
so an empty or missing file is valid. The installer seeds the file from
[`share/config.sample`](../share/config.sample), with every setting commented and set to its
default.

## Format

```ini
# Comments start with #. Blank lines are ignored.
DEFAULT_ENGINE=opencode
DEFAULT_TIMEOUT=90m
OPENCODE_BIN=/home/headrun/.opencode/bin/opencode
```

- One `KEY=value` per line. Spaces around `=` are allowed.
- A value may be wrapped in single or double quotes, which are removed. There is no
  variable expansion: `$HOME` and `~` are taken literally, so use absolute paths.
- An unknown key is an error, which catches typos.
- headrun checks the whole file before doing anything and lists **every** problem at once.
  `headrun doctor` is a quick way to check it.

**Durations** are written as a number of seconds (`90`) or with units `d`, `h`, `m` and `s`,
combined largest first: `45s`, `30m`, `2h`, `1h30m`, `1d`.

## Settings

| Key | Default | Values | Meaning |
|---|---|---|---|
| `DEFAULT_ENGINE` | *(empty)* | engine name, or empty / `null` / `none` | Engine for jobsheets with no `engine:` key. With no default, such jobs fail when they run. |
| `DEFAULT_WORKDIR` | *(empty)* | absolute path | Working directory for jobsheets with no `workdir:` key. Empty means every jobsheet must set one. |
| `DEFAULT_TIMEOUT` | `2h` | duration, more than 0 | Maximum run time per job. A jobsheet's `timeout:` overrides it. |
| `DEFAULT_PRIORITY` | `50` | 0–999 | Priority for jobs that don't set one. Lower runs first. |
| `DEFAULT_PERMISSIONS` | `bypass` | `bypass`, `auto`, `edits`, `readonly` | Permission mode for jobs that don't set one. See [engines](engines.md#permission-modes) and [security](security.md). |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` | Verbosity of the runner log and command messages. |
| `POLL_INTERVAL` | `5s` | duration, more than 0 | How often a watching or paused runner checks the queue. |
| `KILL_GRACE` | `30s` | duration, more than 0 | How long a job may ignore SIGTERM (on timeout or `stop --now`) before its process group is sent SIGKILL. |
| `RECENT_LIMIT` | `10` | 0 or more | Number of finished jobs `headrun ls` shows. `ls --all` shows every job. |
| `PRUNE_AFTER` | `30d` | duration | Default age for `headrun prune`. `--older-than` overrides it. |
| `<NAME>_BIN` | the engine name | command or absolute path | Program run by the engine called `name`. See below. |

## Engine binaries

By default each engine runs its tool by name from `PATH`. A `<NAME>_BIN` setting replaces
that with a command name or an absolute path. The engine name is the key without `_BIN`, in
lower case, with `_` becoming `-`:

| Setting | Engine | Typical value |
|---|---|---|
| `CLAUDE_BIN` | `claude` | `/home/headrun/.local/bin/claude` |
| `OPENCODE_BIN` | `opencode` | `/home/headrun/.opencode/bin/opencode` |
| `CODEX_BIN` | `codex` | `/home/headrun/.local/bin/codex` |
| `GEMINI_BIN` | `gemini` | `/home/headrun/.nvm/versions/node/v24.21.0/bin/gemini` |
| `MY_TOOL_BIN` | `my-tool` (custom adapter) | any |

The adapter receives the value as `HEADRUN_ENGINE_BIN`. `headrun doctor` runs each engine's
binary and shows its version, or a warning if it can't be found.

You need these settings when the runner's `PATH` is narrower than your login shell's,
usually under systemd. `headrun install-service` writes the unit with the `PATH` of the
shell you run it from, so running it from a full login shell often makes them unnecessary.

**Node-based CLIs (Gemini, and Codex or Claude when installed with npm)** start with
`#!/usr/bin/env node`. An absolute path to the script isn't enough on its own: `node` must
also be on the runner's `PATH`. With nvm, both live in the version-specific directory
`~/.nvm/versions/node/<version>/bin`. Run `install-service` from a shell where `node` is on
`PATH`, and update the setting, or rerun `install-service`, after switching Node versions.

## Environment variables

These are read once at start-up, and they decide where everything lives.

| Variable | Effect |
|---|---|
| `HEADRUN_CONFIG_DIR` | Config directory. Default `$XDG_CONFIG_HOME/headrun`, i.e. `~/.config/headrun`. |
| `HEADRUN_HOME` | Data directory (queue, logs, locks). Default `$XDG_DATA_HOME/headrun`, i.e. `~/.local/share/headrun`. |
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME` | Standard XDG bases used for the defaults above. |
| `VISUAL`, `EDITOR` | Editor for `headrun new`, `edit` and `requeue --edit`, in that order of preference, falling back to `vi`. Arguments are allowed, e.g. `emacsclient -t -a ""`. |
| `NO_COLOR` | Any value turns off coloured output. |

`HEADRUN_CONFIG_DIR` and `HEADRUN_HOME` must be absolute paths. Point both at another
location to run a second, independent queue under the same account.

## Other files in the config directory

All of these are optional. Each one replaces a built-in default.

| File | Replaces |
|---|---|
| `preamble.md` | The operating instructions at the start of every prompt ([`share/preamble.md`](../share/preamble.md)). |
| `safety.md` | The safety guide added to every prompt ([`share/safety.md`](../share/safety.md)). |
| `jobsheet-template.md` | The template `headrun new` opens ([`share/jobsheet-template.md`](../share/jobsheet-template.md)). |
| `engines/<name>.sh` | The built-in adapter with the same name, or adds a new engine. See [engines](engines.md#writing-an-adapter). |

A copied guide doesn't change when you upgrade headrun. Copy one only when you want to
customise it. `headrun doctor` shows which copy of each guide is in use.
