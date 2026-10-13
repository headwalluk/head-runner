---
title: Disk usage report
engine: shell
workdir: /var/www
command: printf 'Outcome: completed\n\n# Disk usage\n\n```text\n'; du -sh -- */ 2>/dev/null | sort -rh | head -20; printf '```\n'
---

# Disk usage

Non-LLM job: the `shell` engine runs `command:` and its stdout becomes the response.
