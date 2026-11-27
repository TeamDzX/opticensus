# OptiCensus

Every AI on this Mac that can touch your work, whether you allowed it, and
what changed since you last looked. Free and open source (MIT), for macOS 13
or later, Intel and Apple silicon. Pair it with the WorkFlow app and WorkFlow
becomes its console: a task for each item that needs you, decided from your
phone.

## Install

    npm install -g opticensus

The package is the compiled tool and nothing else: no install script, nothing
downloaded at install time. Each release is built from this repository by
GitHub Actions and published with npm provenance, which links the package to
the commit and workflow that built it. Or build it yourself:

    swift build -c release          # .build/release/opticensus
    swift test                      # fixture tests; never scans the real Mac

## Use

    opticensus scan                    # look now; prints what is new or different
    opticensus show [KIND] [-v]        # the register: Needs a Decision, Unexpected, Allowed, Not Allowed
    opticensus diff [--since 2026-03-01]
    opticensus allow ITEM [--until 2027-03-31] [--reason TEXT] [--all]
    opticensus deny ITEM [--reason TEXT]
    opticensus clear ITEM
    opticensus export [--csv] [-o FILE]
    opticensus reads                   # what it reads and what it never keeps

`ITEM` is the six-character id from `show`, or part of a name or key. Add
`--json` to `scan`, `show` and `diff` for machine-readable output.

The register lives in `~/Library/Application Support/OptiCensus`
(`register.json` for the current state, `events.jsonl` for history). Use
`--store DIR` or `OPTICENSUS_STORE` to keep it elsewhere, and `--fixture DIR` to
scan a fake Mac in a folder instead of this one.

A background scan exists only if you install it:

    opticensus schedule install [--every 60]   # one launch agent, local.opticensus.scan
    opticensus schedule status
    opticensus schedule uninstall

It runs a copy of the tool kept in the store folder and writes one line per
scan to `scan.log` there. Desktop, Documents, Downloads, iCloud folders and
external drives are left alone unless you pass `--protected`, so a scan
never raises a macOS permission prompt.

## WorkFlow as the console

    opticensus workflow connect [--bridge DIR]   # link once; WorkFlow's Agent Bridge must be on
    opticensus workflow status | sync | disconnect

Once linked, every item that needs a person becomes a task in an
"OptiCensus" project in [WorkFlow](https://opticell-limited.com), on the Mac
and the phone. Reply on the task to decide:

    allow, because we use it for client work
    allow until 2027-03-31, trial
    deny, not ours

The next scan (or `opticensus workflow sync`) records the decision, says so
on the task and closes it. A change to an open item is posted as a comment;
an allowed item that changes gets a new task. Decisions made with `allow` and
`deny` here close their task too. It goes through WorkFlow's Agent Bridge
folder only (command files in, receipts and a snapshot out), so WorkFlow
needs no add-on and has to be running for tasks to appear.

WorkFlow holds an assistant's "mark done" for your OK when its Ask-before
setting says so. To let OptiCensus close the tasks you have answered, set
WorkFlow → Settings → Agent Bridge → Briefs, Check-ins & Approvals →
OptiCensus → Ask before: Nothing (the entry appears after its first task).

## What it looks at

Installed apps, running processes, launch agents and crontab, MCP
configuration (Claude Code, Claude desktop, Cursor, VS Code, Windsurf,
Gemini, Codex), listening ports, command-line assistants on the PATH, names
of AI keys in shell start-up files, Chromium browser extensions, Claude Code
plugins (and the MCP servers, language servers and hooks they bring), what
assistants may do without asking (Claude Code permission rules and default
mode, Codex approval policy and sandbox mode, Gemini auto-accept), and hooks
that run commands on assistant events.
`opticensus reads` prints the exact wording shown to the owner.

It keeps names, paths, versions and hashes. Arguments, scripts and
permission lists are stored only as a hash, so a change is noticed without
the content being kept. The test `testNothingSecretIsKept` plants keys and
prompts in every source and fails if one reaches the register, the history
or an export; `testAssistantSettingsAreFound` does the same for permission
rules and hook commands.

## How it decides what to say

- **new**: never seen before.
- **changed**: what the item is or can do is different (another MCP command,
  an edited launch-agent script). An allowed item goes back to Needs a Decision.
- **updated**: an ordinary version change. Recorded; an allowance stands.
- **exposed**: a model server is listening beyond this Mac.
- **back**: something marked not allowed is present again.
- **gone**: an allowed item unseen for 30 days (running state is exempt).

The tool never allows or denies anything by itself.

## Layout

- `Sources/OptiCensusCore/Sources.swift`: one small type per source.
- `Sources/OptiCensusCore/Signatures.swift`: what counts as AI. A
  `signatures.json` in the store folder replaces the built-in list.
- `Sources/OptiCensusCore/Engine.swift`: folding a scan into the register.
- `Sources/OptiCensusCore/Product.swift`: the name, in one place.
- `Tests/OptiCensusCoreTests`: a fake Mac built in a temporary folder.

## Known gaps

- The signature list was written from memory; most bundle ids are unchecked.
- A launch agent is recognised by its label and the names in its command.
  A job that starts AI from inside a plainly named script is missed.
- MCP servers that arrive through Claude Code plugins or claude.ai
  connectors are not read; nor are an assistant's pre-approved commands
  (`~/.claude/settings.json`).
- Keys kept in `.env` files or loose text files, and a proxy that forwards
  to a model server on an unlisted port, are not found.
- Safari and editor extensions, and network traffic, are out of scope for now.
