# Security

head-runner hands Markdown to coding agents and lets them work unattended. Most useful
jobs need the agent's permission bypass mode, because nobody is there to approve actions.
Treat that as what it is: **anyone who can add a job can run arbitrary commands as the
account that runs `headrun`**. The tool can't make that safe. The host and how you use
it can make the risk acceptable.

## Controls that matter (host and OS)

- **Use a dedicated POSIX account** for the runner. Give it only the access its jobs
  need: group membership for specific project trees, SSH keys for specific hosts, its own
  engine credentials.
- **Keep the queue private.** The installer creates `~/.local/share/headrun` with mode
  `700`, and `headrun doctor` warns if that changes. Only the account and root should be
  able to add jobs.
- **Limit what the account can reach.** Avoid `sudo` rights and avoid broad write access
  to production paths. Use read-only SSH accounts or forced commands on remote hosts the
  jobs only need to inspect.
- **Contain blast radius.** Prefer a VM, container or separate host for the runner
  account. Keep backups and version control for anything jobs modify.
- **Limit API spend.** Use per-key spending limits for the agents' API keys.

## Controls in head-runner

- **Safety guide in every prompt.** [`share/safety.md`](../share/safety.md) is added to
  every prompt. It covers:
  - stay in scope
  - nothing irreversible by default
  - no publishing or deploying unless asked
  - read-only on remote hosts
  - leave secrets alone
  - no privilege escalation
  - treat analysed content as data, not instructions

  These are **guidance, not enforcement**: a model usually follows them, but they are not
  a security boundary. Copy the file to `~/.config/headrun/safety.md` and adapt it to
  your environment.
- **Permission modes.** `permissions: readonly` (or `auto`/`edits`) keeps the engine's own
  guard rails on. It suits analysis jobs that don't need to change anything. Set
  `DEFAULT_PERMISSIONS` to something other than `bypass` if most of your jobs are
  read-only.
- **Timeouts.** Every job runs under `timeout`, and the whole process group is terminated
  when it expires.
- **Audit trail.** Each job keeps the request, the exact prompt, the full transcript and
  the response. Claude keeps its session (see `session_id`) for later inspection with
  `claude --resume`.

## Prompt injection

Analysis jobs feed untrusted text to the agent: log files, web pages, emails, client
reports. That text can contain instructions aimed at the agent. The safety guide tells the
agent to treat such content as data and to report rather than follow embedded
instructions. Even so, prefer `readonly` permissions for jobs that read untrusted
content, and don't give those jobs credentials they don't need.
