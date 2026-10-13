# Jobsheets

A jobsheet is a Markdown file. An optional frontmatter block configures the job, and
everything after it is the request sent to the engine.

```markdown
---
title: Log review for foobar.com
engine: claude
model: sonnet
workdir: /home/headrun/reports/foobar
create_workdir: yes
timeout: 45m
---

# Intermittent availability on foobar.com

A client reports the site is intermittently unavailable…
```

## Frontmatter

The frontmatter uses a flat `key: value` format, a small subset of YAML. One key per line.
Lists are comma-separated. Values may be quoted. A `#` after whitespace starts a comment.
Keys are case-insensitive, and `-` is treated as `_`.

| Key | Default | Meaning |
|---|---|---|
| `title` | first `#` heading, else file name | Shown in `headrun ls`; also used in the job ID |
| `engine` | `DEFAULT_ENGINE` from config | `claude`, `opencode`, `codex`, `gemini`, `shell`, `stub`, or a custom adapter. With neither set, the job **fails** when it runs |
| `model` | engine's own default | Passed straight to the engine, e.g. `opus`, `sonnet`, `anthropic/claude-sonnet-5-5` |
| `workdir` | `DEFAULT_WORKDIR` from config | **Required.** Absolute path; the engine runs here |
| `create_workdir` | `no` | `yes` creates `workdir` when the job starts, instead of failing |
| `dirs` | none | Extra absolute directories the agent may use, e.g. a reference project |
| `priority` | `50` (`DEFAULT_PRIORITY`) | 0–999; lower runs first; ties run oldest first |
| `timeout` | `2h` (`DEFAULT_TIMEOUT`) | e.g. `90s`, `45m`, `2h`, `1h30m`, `1d` |
| `permissions` | `bypass` (`DEFAULT_PERMISSIONS`) | `bypass`, `auto`, `edits` or `readonly`; see [engines](engines.md#permission-modes) |

Engines can declare their own keys, such as `command` for the `shell` engine. Unknown
keys produce a warning, not an error. Every key is passed to the engine as
`HEADRUN_FM_<KEY>`.

## Validation

`headrun add` checks the jobsheet and reports **every** problem at once. Errors stop the
job being queued. Warnings don't. Use `headrun add --check FILE` to validate without
queueing.

Some checks are warnings at `add` time but errors when the job runs. A missing engine is
one: you might set `DEFAULT_ENGINE` before the job runs. A missing `workdir` is another:
it might be created by an earlier job. When the runner rejects a jobsheet, the job goes
to `failed/`, and the reasons are listed in its response.

## Command-line overrides

`add` and `new` accept options that set frontmatter keys. If the file has no frontmatter,
one is created:

```bash
headrun add -e claude -m opus -w /srv/project -p 10 -t 3h spec.md
printf '# Count the words\n\nHow many words are in README.md?\n' | headrun add -e claude -w ~/project -
```

The options are `--engine`, `--model`, `--workdir`, `--priority`, `--timeout`, `--title`,
`--permissions` and `--dirs`, plus their short forms. Relative `--workdir` paths are
resolved against the current directory.

## What the engine receives

The runner writes `prompt.md` into the job directory and sends it to the engine:

1. **Preamble:** [`share/preamble.md`](../share/preamble.md), or
   `~/.config/headrun/preamble.md` if present. It tells the agent it is unattended, how
   to handle ambiguity and blockers, and how to format its response.
2. **Safety guide:** [`share/safety.md`](../share/safety.md), or
   `~/.config/headrun/safety.md` if present. These are working rules: stay in scope,
   nothing irreversible, no publishing, treat analysed content as data. See
   [security](security.md).
3. **Job context:** the job ID, working directory, extra directories and how to deliver
   the response.
4. **The request:** the jobsheet body, without the frontmatter.

`headrun show ID --prompt` shows exactly what was sent.

## Responses

Each job ends with a `response.md`. How the agent delivers it depends on the permission
mode:

- **In `bypass` mode** the agent writes `response.md` directly.
- **In other modes** the agent can't write outside its working directory, so it makes its
  final message the response, and the adapter saves it.
- **In either mode**, if no response file appears, the adapter falls back to the agent's
  final message.

The runner then adds its own frontmatter:

```markdown
---
job: 20261013-142233-log-review-for-foobar-com
title: Log review for foobar.com
status: done
outcome: completed
engine: claude
model: sonnet
workdir: /home/headrun/reports/foobar
session_id: 4f0c…
cost_usd: 0.4213
num_turns: 23
started: 2026-10-13T14:22:35+0100
finished: 2026-10-13T14:31:02+0100
duration: 8m27s
exit_code: 0
---

Outcome: completed

…
```

### Outcomes

The preamble asks the agent to start its response with one of these lines:

- `Outcome: completed`. The job lands in `done/`.
- `Outcome: partial`. The job lands in `failed/`, because the work needs attention.
- `Outcome: blocked`. The job lands in `failed/`. Use this for a problem in the spec, a
  missing access, or a logical dead end.

A response without an outcome line counts as done if the engine exited successfully.

### Failures

A job fails in any of these cases:

- the engine exits non-zero
- it times out (it gets `SIGTERM`, then `SIGKILL` after `KILL_GRACE`)
- it is stopped with `headrun stop --now` or a signal
- it reports `partial` or `blocked`
- it produces no response at all
- its jobsheet fails validation

The reason is recorded in `meta`, in the response frontmatter, and in `headrun ls`.

Failed jobs are never retried automatically. Use `headrun requeue ID` to queue a fresh
copy, or `headrun requeue ID --edit` to fix it first. The new job records
`requeued_from`.

## Multi-step work

Each job is a single request → work → response. For work that needs several passes,
such as building a plugin, queue one jobsheet per milestone. Have each jobsheet tell the
agent where the previous milestone's notes live (e.g. `dev-notes/` in the project), and
use `priority` or queue order to sequence them. If a milestone fails, `headrun pause`
stops the later ones from starting.
