# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.9.0] - 2026-10-13

### Added

- `gemini` engine for Google Gemini CLI. It sends the prompt on stdin with
  `--output-format stream-json`, renders the transcript through `gemini-render.jq`, and
  maps permissions to `--approval-mode` (`yolo`, `auto_edit`, `plan`). `dirs` becomes
  `--include-directories`, and `--skip-trust` is added when supported. The session ID and
  token counts are recorded; Gemini reports no cost. Written from the documented flags and
  tested against a simulated CLI, but not yet against a live install.

### Fixed

- `headrun doctor` no longer shows "opencode opencode" for OpenCode 2.x.

## [0.8.0] - 2026-10-13

### Fixed

- `headrun ls` sizes the ID column to the longest ID shown, so long job titles no longer
  push the other columns out of line.

### Verified

- OpenCode 2.x in `bypass` mode on a headless host: two Go milestone jobs completed with
  session ID, cost and engine version recorded.

## [0.7.0] - 2026-10-13

### Fixed

- OpenCode 2.x support. 2.x dropped `--dir` and `--dangerously-skip-permissions`, so jobs
  only got its help text. The adapter now detects the major version: 2.x runs
  `opencode run --standalone` in `workdir`, maps `bypass` to `--auto`, and reads the
  final message and cost from `opencode session export`, whose format changed. 1.x
  behaves as before. The OpenCode version is recorded in `meta` as `engine_version`.

### Documentation

- SSH examples call `.local/bin/headrun`, because non-login SSH shells usually lack
  `~/.local/bin` on `PATH`.
- `dirs:` with OpenCode in non-`bypass` modes needs `opencode.json` rules.

## [0.6.0] - 2026-10-13

### Fixed

- Runner no longer dies (SIGPIPE under `pipefail`) when claiming from a large queue; other
  early-exit pipelines removed for the same reason.
- Processes a job leaves behind (e.g. ones ignoring SIGTERM) are now terminated after
  timeout, `stop --now` and orphan recovery: SIGTERM, then SIGKILL after `KILL_GRACE`.
- Background helpers (`tail`, `sleep`) no longer inherit the runner lock, so a killed
  runner no longer blocks a new one until the orphaned job ends.
- A signal arriving between claiming and finishing a job no longer abandons it in
  `running/`; a job stopped before its engine starts returns to `pending/`. Response
  finalisation is atomic.
- An idle runner exits 0 on SIGTERM/SIGINT (clean `systemctl stop`).
- A `workdir` that cannot be created, or exists as a file, fails that job instead of the
  runner.
- Option values containing `#`, backslashes or leading quotes are stored intact; tabs and
  line breaks are rejected.
- `$EDITOR`/`$VISUAL` commands with quoted arguments (e.g. `emacsclient -t -a ""`) work.
- `KILL_GRACE=0` is rejected (it would disable the SIGKILL escalation).
- A runner start no longer fails if a `status` probe holds the lock at that instant.
- Installer: explains when it falls back to `main`, and cleans up a failed staging copy.

### Changed

- `--help` is handled once for every subcommand.

## [0.5.0] - 2026-10-13

### Added

- Documentation: README with one-line installer and quick start; `docs/jobsheets.md`,
  `docs/engines.md`, `docs/operations.md`, `docs/security.md`.
- Example jobsheets: WordPress plugin milestone, log analysis, stub, shell report.

### Fixed

- Jobs queued within the same second now run strictly first-in, first-out
  (nanosecond `queued_order`), rather than alphabetically by ID.

## [0.4.0] - 2026-10-13

### Changed

- The job context now tells the agent how to deliver its response: write `response.md` in
  `bypass` mode, otherwise make the final message the response (other modes cannot write
  outside the working directory).
- A job that exits successfully without producing a response is now marked failed.

### Fixed

- OpenCode: the final message is recovered from `opencode export`, because `opencode run
  --format json` can exit before flushing its last events. Cost comes from the export too.
- Whitespace-only responses are treated as missing.

### Verified

- Live runs of the `claude` and `opencode` adapters in `readonly` mode (streaming
  transcript, session id, cost, final-message fallback, outcome parsing).

## [0.3.0] - 2026-10-13

### Added

- `install.sh`: one-line installer (`curl -fsSL …/install.sh | bash`) that installs the
  latest release (or `HEADRUN_REF`) into `~/.local/share/headrun/app`, links
  `~/.local/bin/headrun`, seeds `~/.config/headrun/config`, and supports `--local` and
  `--uninstall`. Upgrades replace the program atomically and keep config and jobs.

## [0.2.0] - 2026-10-13

### Added

- Test suite (`make test`): a dependency-free harness running each test in an isolated
  sandbox, covering parsing, validation, queue ordering, lookup, prune, runner outcomes,
  timeouts, pause/stop, lock contention and orphan recovery. Passes with gawk and mawk.
- `make lint` runs shellcheck over the whole program.

## [0.1.0] - 2026-10-13

### Added

- `headrun` CLI with a filesystem queue: one directory per job, state given by the parent
  directory (`pending/`, `running/`, `done/`, `failed/`, `cancelled/`, `archive/`).
- Locking with `flock`: one runner per account, short queue lock for mutations.
- Commands: `add`, `new`, `ls`, `show`, `tail`, `log`, `edit`, `bump`, `cancel`, `requeue`,
  `run`, `pause`, `resume`, `stop`, `status`, `prune`, `doctor`, `install-service`.
- Jobsheet frontmatter (flat `key: value`) with validation that reports every problem at once.
- Runner: priority then FIFO ordering, per-job timeout, orphan recovery, pause/stop between
  jobs, signal handling, foreground streaming or detached mode.
- Response finalisation: runner frontmatter on `response.md`, fallback response when the
  engine writes none, `Outcome:` line parsing (partial/blocked jobs are marked failed).
- Engine adapters: `claude`, `opencode`, `codex` (untested), `shell`, `stub`.
- Default preamble and safety guide prepended to every prompt.
