# Engines

An engine is a small Bash adapter that runs one tool for one job. The built-in adapters
live in `engines/` in the program directory. Yours go in `~/.config/headrun/engines/`,
and a user adapter with the same name replaces the built-in one.

| Engine | Tool | Notes |
|---|---|---|
| `claude` | Claude Code, `claude --print` | Streams JSON; with `jq`, the transcript is rendered readably and the session ID, cost and turns are recorded |
| `opencode` | OpenCode, `opencode run` | With `jq`, uses JSON events and recovers the final message and cost from `opencode export` |
| `codex` | OpenAI Codex CLI, `codex exec` | Written from Codex's documented flags; **not yet tested against a live install** |
| `shell` | `bash -c "$command"` | Runs the jobsheet's `command:` with the request body on stdin; stdout becomes the response |
| `stub` | none | Deterministic response, no LLM. For testing the queue and runner |

`headrun doctor` shows each engine's status and version.

## Engine binaries

By default each engine runs its tool by name from `PATH`. Under systemd, or for tools
installed outside `PATH` (OpenCode installs to `~/.opencode/bin`), set the path in the
config:

```ini
CLAUDE_BIN=/home/headrun/.local/bin/claude
OPENCODE_BIN=/home/headrun/.opencode/bin/opencode
```

Any `<NAME>_BIN` setting is passed to the adapter for engine `name` as
`HEADRUN_ENGINE_BIN`.

## Permission modes

The jobsheet's `permissions:` key (default `DEFAULT_PERMISSIONS=bypass`) is mapped by each
adapter:

| Mode | `claude` | `opencode` | `codex` |
|---|---|---|---|
| `bypass` | `--dangerously-skip-permissions` | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` |
| `auto` | `--permission-mode auto` | `opencode.json` rules; prompts auto-rejected | `--full-auto` |
| `edits` | `--permission-mode acceptEdits` | `opencode.json` rules; prompts auto-rejected | `--full-auto` |
| `readonly` | `--permission-mode plan` | `opencode.json` rules; prompts auto-rejected | `--sandbox read-only` |

Nobody is present to approve actions, so most real work needs `bypass`. Read
[security](security.md) before relying on it. The other modes suit read-only analysis.
In those modes the agent can't write `response.md` (it sits outside the working
directory), so the runner tells it to make its final message the response instead.

## `shell` engine

The `shell` engine turns any Unix filter into a job:

```markdown
---
title: Word count
engine: shell
workdir: /srv/docs
command: wc -w *.md | sort -n
---

(The body is sent on stdin; this command ignores it.)
```

The command runs with `bash -c` in `workdir`:

- stdin is the request body
- stdout becomes `response.md`, unless the command writes `$HEADRUN_RESPONSE` itself
- stderr goes to the transcript
- the exit status decides success or failure

## `stub` engine

The `stub` engine writes a Markdown response with the date and time, job ID and request
size. It accepts these test keys:

| Key | Effect |
|---|---|
| `stub_sleep: 10` | Work for N seconds, printing progress (for testing `tail`, `pause`, `stop`, timeouts) |
| `stub_exit: 3` | Exit with this status |
| `stub_outcome: blocked` | Report this outcome (`completed`, `partial`, `blocked`) |
| `stub_silent: yes` | Write no response |

## Writing an adapter

An adapter is a Bash script `~/.config/headrun/engines/<name>.sh`. The runner calls it
with one argument:

- `check`: print a one-line status (such as the tool's version) and exit 0 if the engine
  is usable. Used by `headrun doctor`.
- `run`: do the job.

It runs with `workdir` as the current directory, inside its own process session, under
`timeout`. stdin is `/dev/null`. stdout and stderr go to `transcript.log`, and the
terminal shows them when the runner is in the foreground.

| Variable | Meaning |
|---|---|
| `HEADRUN_JOB_ID`, `HEADRUN_JOB_DIR` | The job ID and its directory |
| `HEADRUN_REQUEST` | `request.md`, the jobsheet as queued (with frontmatter) |
| `HEADRUN_PROMPT` | `prompt.md`, the composed prompt to send to an LLM |
| `HEADRUN_RESPONSE` | Where the response belongs |
| `HEADRUN_ENGINE_META` | Append `key=value` lines here to record `session_id`, `cost_usd`, `num_turns`, `engine_version`, `engine_note` |
| `HEADRUN_WORKDIR`, `HEADRUN_DIRS` | Working directory; extra directories (comma-separated) |
| `HEADRUN_ENGINE`, `HEADRUN_ENGINE_BIN` | Engine name; configured binary (default: the engine name) |
| `HEADRUN_MODEL`, `HEADRUN_PERMISSIONS`, `HEADRUN_TIMEOUT` | From the frontmatter or config (timeout in seconds) |
| `HEADRUN_TITLE` | Job title |
| `HEADRUN_FM_<KEY>` | Every frontmatter key, upper-cased |
| `HEADRUN_APP_ROOT` | The program directory (e.g. for the built-in `.jq` renderers) |

Exit 0 for success and non-zero for failure. If the tool can't write `HEADRUN_RESPONSE`
itself, have the adapter write it from the tool's final output. The runner adds the
frontmatter.

To declare extra frontmatter keys so `add` doesn't warn about them, add a comment line:

```bash
# headrun-keys: command, retries
```

The built-in `stub.sh` and `shell.sh` are good starting points.
