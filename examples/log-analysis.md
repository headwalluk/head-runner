---
title: Intermittent availability — foobar.com log review
engine: claude
model: sonnet
workdir: /home/headrun/reports/foobar.com
create_workdir: yes
timeout: 45m
---

# Intermittent availability on foobar.com

A client has reported that their website is intermittently unavailable, without further
detail. The client's IP address is `XX.XX.XX.XX`.

SSH to the website's host (`webserver1.example.com`) and review:

- `/var/www/foobar.com/log/access.log`
- `/var/www/foobar.com/log/error.log`

Look for:

- malfunctioning plugins (PHP fatals, exceptions, timeouts, memory exhaustion)
- security events: did the client's IP trip a lock-out, rate limit or WAF rule?
- patterns in time (bursts, regular intervals) and status codes (5xx, 403, 429)

The host is **read-only** for this job: do not restart services or change files there.

## Output

Write a short report to `report.md` in the working directory covering findings, evidence
(log excerpts with timestamps), and a conclusion: is this our problem (hosting), the
client's problem, or something in between (network, transport, infrastructure)? Include
recommended next steps.

The response should summarise the conclusion and point to `report.md`.
