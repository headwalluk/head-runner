---
title: Fancy plugin one — milestone 1 (scaffold)
engine: claude
model: opus
workdir: /var/www/devsite.local/web/wp-content/plugins/fancy-plugin-one
create_workdir: yes
dirs: /var/www/devsite.local/web/wp-content/plugins/my-reference-plugin
priority: 50
timeout: 2h
---

# Fancy plugin one: milestone 1, scaffold

Create a WordPress plugin in the working directory.

Use `/var/www/devsite.local/web/wp-content/plugins/my-reference-plugin/` as the reference
for:

- plugin file and directory layout
- coding style and comment conventions
- an `AGENTS.md` for the new plugin (adapt the reference plugin's)
- translatable strings (text domain `fancy-plugin-one`)

## Requirements

<INSERT THE PLUGIN'S DETAILED REQUIREMENT SPEC HERE>

## This milestone

Scaffold only: the main plugin file, the autoloading or bootstrap structure, the settings
page skeleton, and `AGENTS.md`. Later milestones are queued as separate jobs.

## Notes and documentation

- Write design decisions and anything a later milestone needs to know to
  `dev-notes/milestone-1.md` in the plugin.
- Do not activate the plugin or modify the database.
