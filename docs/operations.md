# Operations

## Where things live

| Path | Contents |
|---|---|
| `~/.local/bin/headrun` | Link to the program |
| `~/.local/share/headrun/app/` | The program: `bin/`, `lib/`, `engines/`, `share/` |
| `~/.config/headrun/config` | Settings (see [`config.sample`](../share/config.sample)) |
| `~/.config/headrun/preamble.md`, `safety.md` | Optional overrides of the built-in prompt guides |
| `~/.config/headrun/engines/*.sh` | Optional custom engine adapters |
| `~/.local/share/headrun/jobs/` | The queue: one directory per job, grouped by state |
| `~/.local/share/headrun/headrun.log` | Runner log |
| `~/.local/share/headrun/runner.out` | Raw stdout/stderr of a detached runner (crash traces) |
| `~/.local/share/headrun/runner.lock`, `queue.lock` | `flock` lock files |
| `~/.local/share/headrun/paused`, `stop-requested` | Flag files set by `pause` and `stop` |

`XDG_CONFIG_HOME` and `XDG_DATA_HOME` are honoured. `HEADRUN_CONFIG_DIR` and
`HEADRUN_HOME` move the config and data directories, which is useful for a second queue
or for testing.

## A dedicated account on a headless host

On the server:

```bash
sudo adduser --disabled-password --gecos "head-runner" headrun
sudo loginctl enable-linger headrun     # let its systemd user services run without a login
sudo -iu headrun
```

As `headrun`:

```bash
curl -fsSL https://raw.githubusercontent.com/headwalluk/head-runner/main/install.sh | bash
exec bash -l                            # pick up ~/.local/bin on PATH if it was just added

# Install and log in to each agent CLI you intend to use, then check each one works:
claude            # complete login, run a test prompt, exit
opencode          # configure providers/keys, run a test prompt, exit

headrun doctor
```

Things `headrun` deliberately leaves to the host:

- **File ownership.** If jobs write into shared trees such as `/var/www/…`, give the
  account group access, e.g. a shared group plus setgid directories. Your existing
  ownership and permissions maintenance still applies.
- **SSH keys.** Jobs that reach other hosts use the account's own `~/.ssh/` keys and
  config.
- **Engine credentials.** Each CLI keeps its own login under the account's home directory.

Queue jobs from your own machine over SSH:

```bash
ssh headrun@box headrun add - < job.md
ssh headrun@box headrun ls
ssh headrun@box headrun show fancy
```

## Running the runner

| Command | Behaviour |
|---|---|
| `headrun run` | Foreground; streams each transcript; exits when the queue is empty |
| `headrun run --once` | Runs one job and exits |
| `headrun run --watch` | Never exits on an empty queue; polls every `POLL_INTERVAL` |
| `headrun run --detach [--watch]` | Same, in the background (`setsid`); output goes to `headrun.log` |
| `headrun run --quiet` | No transcript streaming (log lines only) |

Only one runner can run per data directory. A second one refuses to start.

### As a systemd user service

```bash
headrun install-service --enable
systemctl --user status headrun
journalctl --user -u headrun -f
```

The unit runs `headrun run --watch --quiet` with the `PATH` you had when you ran
`install-service`, so run it from a shell where every engine CLI is found. On stop,
systemd sends `SIGTERM`. The runner stops the current job, marks it failed ("stopped by
SIGTERM") and exits. If you'd rather let the job finish, use `headrun pause` and wait,
then stop the service.

On a headless account, `loginctl enable-linger <user>` (as root) is required, or the
service stops when you log out. `headrun doctor` reports the linger state.

## Pause, stop and recovery

- **`headrun pause`:** the runner finishes its current job, then claims nothing new.
  - A watching runner waits.
  - A draining runner exits.
  - New jobs can still be added.
- **`headrun resume`:** the runner claims jobs again.
- **`headrun stop`:** the runner exits after the current job.
- **`headrun stop --now`:** the current job is terminated, marked failed, and the runner
  exits. Repeating the signal (e.g. a second Ctrl-C) kills the job outright.
- **Crashes:** if the runner dies abruptly, its lock is released by the kernel. The next
  runner moves anything left in `running/` to `failed/` ("orphaned"), terminating the
  engine's process group if it is still alive.

## Monitoring

```bash
headrun status          # runner state, current job and elapsed time, counts per state
headrun ls              # queue plus the last RECENT_LIMIT finished jobs
headrun tail            # follow the running job's transcript
headrun log -f          # follow the runner log
grep -l 'status: failed' ~/.local/share/headrun/jobs/*/*/response.md
```

## Housekeeping

`headrun prune` moves finished jobs older than `PRUNE_AFTER` (default 30 days) to
`archive/`, hiding them from `headrun ls` but keeping them on disk.
`headrun prune --older-than 90d --delete` removes them for good. `--dry-run` shows what
would happen.

## Upgrading and removal

Re-run the installer. It replaces `~/.local/share/headrun/app` in one step and leaves your
config, guides and jobs alone. A running runner keeps the code it started with, so restart
it (or the service) afterwards.

To uninstall, run `install.sh --uninstall`. It removes the program and the link and keeps
`~/.config/headrun` and the jobs. Delete those by hand if you want them gone.
