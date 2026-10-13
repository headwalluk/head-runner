# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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
