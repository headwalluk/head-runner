# head-runner

**Markdown in, Markdown out.** A filesystem job queue for agentic coding tasks.

You write a *jobsheet*: a Markdown file with a short frontmatter block (which engine, which
project directory) and a detailed request. `headrun` queues it, and a runner works through
the queue one job at a time. Each job goes to Claude Code, OpenCode, Codex or a plain shell
command, and the result is a Markdown response saying what was done.

- **Near-zero dependencies.** Bash 4.4+, `flock`, coreutils and awk. `jq` is optional.
- **Greppable.** Every job is a directory of plain files, and its state is the folder it
  sits in.
- **One job at a time per account.** Locking uses `flock`. For parallel queues, use
  another POSIX account.
- **Works headless or on a workstation.** Use a dedicated account on a server, or
  `~/.local/bin/headrun` on your own login.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/headwalluk/head-runner/main/install.sh | bash
```

This installs the latest release into `~/.local/share/headrun/app` and links
`~/.local/bin/headrun`. It also creates `~/.config/headrun/config`. No root needed. Re-run
the same command to upgrade.

Then check everything is in place:

```bash
headrun doctor
```

To pin a version, set `HEADRUN_REF=v1.0.0` before running the installer. To remove the
program but keep your config and jobs: `curl -fsSL …/install.sh | bash -s -- --uninstall`.

Each agent CLI (`claude`, `opencode`, `codex`) must already be installed, logged in and
working in a terminal for the account that runs `headrun`.

## Quick start

```bash
cat > hello.md <<'EOF'
---
title: Hello from the stub engine
engine: stub
workdir: /tmp
---

# Hello

The stub engine needs no LLM. It writes a deterministic response for testing.
EOF

headrun add hello.md     # queue it (prints the job ID)
headrun ls               # see the queue
headrun run              # run jobs in the foreground until the queue is empty
headrun show             # read the latest response
```

A real job looks like this:

```markdown
---
title: Fancy plugin one — milestone 1
engine: claude
model: opus
workdir: /var/www/devsite.local/web/wp-content/plugins/fancy-plugin-one
create_workdir: yes
dirs: /var/www/devsite.local/web/wp-content/plugins/my-reference-plugin
timeout: 2h
---

# Fancy plugin one: scaffold and settings page

Create a WordPress plugin in the working directory. Use `my-reference-plugin` as the
reference for layout, coding style, `AGENTS.md`, translatable strings and comments…
```

See [`examples/`](examples/) for complete jobsheets.

## Commands

| Command | What it does |
|---|---|
| `headrun add FILE` / `add -` | Queue a jobsheet from a file or stdin (`ssh box .local/bin/headrun add - < job.md`) |
| `headrun new` | Write a jobsheet in `$EDITOR` from a template, then queue it |
| `headrun ls [--all] [--state S]` | Running and pending jobs, plus recent finished ones |
| `headrun show [ID] [--request\|--prompt\|--log\|--meta\|--path]` | A job's response (default: running or latest job) |
| `headrun tail [ID]` | Follow the running job's transcript |
| `headrun edit ID` / `bump ID N` / `cancel ID…` | Change, reprioritise or cancel pending jobs |
| `headrun requeue ID [--edit]` | Queue a fresh copy of a finished or failed job |
| `headrun run [--once\|--watch] [--detach] [--quiet]` | Run the queue in the foreground, or detached |
| `headrun pause` / `resume` | Stop/start claiming jobs (the current job finishes first) |
| `headrun stop [--now]` | Runner exits after the current job (`--now` kills the job) |
| `headrun status` / `log [-f]` | Runner state and the runner log |
| `headrun prune [--older-than 30d] [--delete]` | Move old finished jobs to `archive/` (or delete them) |
| `headrun doctor` | Check dependencies, configuration and engines |
| `headrun install-service [--enable]` | systemd user unit that runs `headrun run --watch` |

Job IDs look like `20261013-142233-fancy-plugin-one`. Any unique prefix or substring
works, e.g. `headrun show fancy`.

## How it works

```
~/.local/share/headrun/jobs/
  pending/   running/   done/   failed/   cancelled/   archive/
     └── 20261013-142233-fancy-plugin-one/
           request.md       the jobsheet as queued
           prompt.md        what the engine received (preamble + safety guide + request)
           transcript.log   the engine's output, as it streamed
           response.md      the result, with runner frontmatter (status, timings, cost)
           meta             key=value state (times, exit code, reason, session id)
```

- **Moving between states:** a job moves from one state to the next with an atomic
  `mv`. One runner per account holds `runner.lock`.
- **Order:** jobs run by priority (lower first), then oldest first.
- **Failures:** a failure (non-zero exit, timeout, or the agent reporting
  `Outcome: blocked` or `partial`) lands in `failed/` and the runner moves on. Fix the
  jobsheet if needed and `headrun requeue ID --edit`.
- **Prompt preamble:** every prompt starts with a short [preamble](share/preamble.md) for
  unattended work and a [safety guide](share/safety.md). Copy either into
  `~/.config/headrun/` to customise it.

## Documentation

- [Jobsheets](docs/jobsheets.md): frontmatter reference, responses and outcomes
- [Engines](docs/engines.md): built-in engines, permission modes, writing your own adapter
- [Operations](docs/operations.md): dedicated account, systemd, monitoring and upgrades
- [Security](docs/security.md): the risks of unattended agents and how to manage them
- [Configuration](share/config.sample): every setting, with defaults
- [Changelog](CHANGELOG.md)

## Development

```bash
make check     # shellcheck + test suite (needs shellcheck)
./install.sh --local    # install from this checkout
```

## Licence

MIT. See [LICENSE](LICENSE).
