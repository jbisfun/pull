# pull

A multi-repo git wrapper. `pullfile.plist` lists the repos, their upstreams and pinned
commits. Each repo is cloned to `{pullfile-root}/{repo-name}`. A single `pull commit` writes
one commit, with the same message, identity and signature, to every repo that has changes,
then records the new pins.

## Packages and features

pull is built with Zig (0.17.1). The core is always built; everything else is an
optional package (`pkgs/<name>`) behind a build feature of the `pull` binary, and no
feature requires another:

    package        feature        what
    pkgs/core      (always)       pullfile.plist / local.toml model, identity, path routing
    pkgs/git       (always)       clone/sync, status, stage, commit across repos, push
                   https, ssh     git transports
    pkgs/env       env            pullfile `env` + local.toml `[env]`; pull env / pull shell
    pkgs/hooks     hooks          pullfile `hooks` (precommit, postcommit, pull)
    pkgs/lint      lint           pullfile `lint`; pull lint
                   conventional   lint `conventional` (Conventional Commits parser)
    pkgs/ignore    ignore         pullfile `ignore` -> each repo's .git/info/exclude
    pkgs/worktree  worktree       pull worktree
    pkgs/tool      tool           pullfile `tool`; pull tool
    pkgs/launchd   launchd        pullfile `jobs`; pull launchctl / pull session
    pkgs/haxy      haxy           pull haxy (issues on haxy's `haxy/events` branch)
    pkgs/mcp       mcp            pull mcp (session/job tools only with `launchd`,
                                  haxy_* tools only with `haxy`)

All features are on by default. Install to ~/.local/bin:

    zig build -Doptimize=ReleaseSafe --prefix ~/.local

or build a smaller pull with e.g. `-Dfeatures=https,env,hooks`. `zig build test` runs
every built package's tests.

Features meet only in the binary (`src/workspace.zig`): without `env`, hooks, jobs, `each`
and MCP `exec` get just PULL_ROOT; without `hooks` or `lint`, commits skip them; without
`launchd`, the MCP server has no session tools. Only `identity` and `repos` are core
pullfile keys: every other top-level key is a section owned by its feature package, kept
verbatim (and reported as ignored) when that feature isn't built, so a lean build never
drops another build's settings. `pull --version` and `pull status --json` (`features`)
list what a binary was built with.

## Files

`pullfile.plist` (shared, committed):

    identity: org (selects [orgs.<org>] in local.toml), email = none|local, require_signing
    repos:    [{name, upstream, branch, commit}]
    env:      path, vars                    (feature env)
    lint:     no_description, max_subject_length, conventional, no_trailing_period
                                            (feature lint)
    hooks:    precommit, postcommit, pull   (feature hooks; arrays of `sh -c` commands,
                                            run in the root)
    ignore:   [patterns]                    (feature ignore)
    jobs:     [launchd jobs]                (feature launchd)

Hook env: PULL_ROOT, PULL_HOOK, PULL_REPOS (space-separated), PULL_MESSAGE (commit hooks).

`local.toml` (per machine, gitignored; falls back to ~/.config/pull/local.toml):

    name = "jp"
    # email = "..."          # only used if the pullfile says email = "local"
    signing_key = "FPR"      # gpg key; omit to use gpg's default key
    sign = true
    # gpg_program = "gpg"

    [orgs.acme]              # overrides used when the pullfile sets org = "acme"
    name = "jp@acme"
    signing_key = "FPR"

With the default `email = none`, commits are written as `name <>`, so no email gets published.

## Commands

    pull init [--org X]            create pullfile.plist and local.toml
    pull repo add URL [--name] [--branch]   |  repo rm NAME  |  repo list
    pull sync                      clone missing repos, fetch, fast-forward to the pins
    pull update                    fast-forward to upstream branches and re-pin
    pull status [--json]           --json: root, features, lint rules, per-repo
                                   branch/head/pin, ahead/behind and changed files
    pull add PATHS...              each path is staged in the repo that contains it
    pull unstage PATHS...          back to HEAD, routed the same way
    pull commit -m MSG [-a] [PATHS...] [--no-verify]
    pull push
    pull lint MSG  |  pull whoami  |  pull each CMD...

If the root is itself a git repo, `pull commit` also commits the updated pullfile.plist
there with the same message.

## Ignore

The pullfile's `ignore` array holds gitignore patterns for every repo, e.g.
`__pycache__/`, `*.pyc`, `.DS_Store`. pull keeps them in each repo's `.git/info/exclude`
(between `# >>> pull ignore` markers) on every command, so repos don't need their own
.gitignore entries and nothing is committed for it. Patterns don't untrack files that are
already committed; `git rm --cached` those.

## MCP server

`pull mcp [--root DIR]` serves the workspace to agents over MCP (stdio):

    workspace                      repos, branches, pins, ahead/behind, changes, env, jobs
    status / diff / log            per repo or across all repos
    grep / list_files / read_file  ripgrep's engine, .gitignore-aware, confined to the root
    exec                           run a command to completion with the workspace env
    session_new / session_run / session_send / session_capture / session_list /
    session_kill                   stateful terminals (the sessions below); a human can
                                   `pull session attach` to the same one
    job                            start/stop/restart/unload pullfile jobs
    haxy_issues / haxy_issue / haxy_new_issue / haxy_comment / haxy_close /
    haxy_reopen / haxy_sync        haxy issues (below)
    haxy_stacks / haxy_stack / haxy_patch /
    haxy_merge                     haxy stacks (below)

Register it with an agent, e.g. Hermes:

    hermes mcp add pull --command pull --args mcp --root /path/to/workspace

`pull mcp-servers` prints `pull` itself plus every pullfile `mcp_servers` entry as JSON
(`{name: {command, args, env}}`, command resolved on `$PATH`, `PULL_ROOT` set), for an
editor/agent to register the whole set at once. A pullfile entry needs only a `command`
(defaults to the key) and `args`:

    <key>mcp_servers</key>
    <dict>
        <key>radar</key>
        <dict><key>args</key><array><string>mcp</string></array></dict>
    </dict>

ycode-pull reads `pull mcp-servers` to register all of them in one go.

## haxy issues

[haxy](https://github.com/jbisfun/haxy) keeps a repo's issues as JSON event commits on a
`haxy/events` branch. `pull sync` fetches that branch too (to `origin/haxy/events`), and:

    pull haxy issues [REPO] [--all] [--json]   open (--all: every) issue per repo
    pull haxy show REPO ISSUE                  description and comments
    pull haxy new REPO -t TITLE [-b BODY] [-l LABELS]
    pull haxy comment REPO ISSUE TEXT  |  close REPO ISSUE  |  reopen REPO ISSUE
    pull haxy sync [REPO...]                   fetch, fast-forward or merge, push
    pull haxy open [REPO]                      run `haxy` (TUI + local web UI) there,
                                               or over the whole workspace

ISSUE is an id or a unique prefix of one. Events are written as haxy's local mode writes
them, with pull's identity (and GPG signature), so `haxy` reads them; sync is haxy's own
(an empty-tree merge commit when both sides moved). Listing replays the events (local
branch, else origin's); concurrent edits of one issue resolve by causal order then time,
where haxy would flag a field conflict.

## haxy stacks

A stack is one change across several repos: a haxy patch per repo, merged together and
pinned in one pullfile commit. It is a `stack` event naming the member patches, kept in
the workspace's events repo: the root repo when the root is a git repo, else the repo
the pullfile `haxy` section names:

    <key>haxy</key>
    <dict><key>events</key><string>dotenv</string></dict>

The commands:

    pull haxy patch [-t TITLE] [-b BODY] [-l LABELS] [--branch NAME]
                                  a patch per repo with unmerged work on a branch other
                                  than its pullfile one (or on NAME), and the stack
    pull haxy stacks [--json]     every stack, newest first
    pull haxy stack [--json] ID   members, their patches and pins (--json: haxy's view,
                                  including whether each member merges)
    pull haxy merge [-m MSG] ID   merge every member (all or nothing), then pin
    pull haxy pin [-m MSG] ID     pin an already merged stack
    pull haxy checkout ID [NAME]  a worktree (.worktrees/NAME) with each member on its
                                  patch's branch

pull runs haxy to create and merge stacks (`haxy stack new|merge`), so `haxy` must be on
`PATH`. haxy merges the members into their target branches without touching the work
trees, and records the merged commits on the stack. pull then pins those commits and
commits the pullfile the way `pull commit` does: precommit hook, signed commit, postcommit
hook. The message is the stack title, or `pin stack <id>` if lint rejects the title.
Pinning refuses when repos already have staged changes, so the commit holds only the pins.
A merged stack can't change. `pull haxy open` (no repo) shows the workspace in haxy's
web UI, with stack pages under `/home/stacks` and a merge button that runs
`pull haxy pin`. `pull haxy sync` also syncs the root repo's events when it holds the
stacks.

## Jobs and sessions (launchd)

pull ports launchd's job model (Apple's launchd, `liblaunch/launch.h`) to the workspace.
Jobs use launchd plist keys, either in the pullfile's `jobs` array or in standalone
`.plist` files:

    Label, Program, ProgramArguments, EnvironmentVariables, WorkingDirectory, RunAtLoad,
    KeepAlive (bool or {SuccessfulExit}), StartInterval, ThrottleInterval,
    StandardOutPath, Disabled, LaunchOnlyOnce

A per-workspace daemon (`pull launchd`, started automatically, socket `.pull/launchd.sock`)
supervises them. Every job runs in a pseudo-terminal with the workspace env (`pull env`)
plus its own EnvironmentVariables and `PULL_JOB`, so every job is also a session.

    pull launchctl load [FILE.plist...]   load pullfile jobs, or launchd plists
    pull launchctl list | print LABEL     (--json for agents)
    pull launchctl start|stop|unload LABEL
    pull launchctl kickstart [-k] LABEL   start, or kill and restart
    pull launchctl shutdown               stop all jobs and the daemon

tmux-style sessions, for humans and agents:

    pull session new NAME [-d] [-c DIR] [--keep-alive] [CMD...]   default CMD: $SHELL
    pull session attach NAME              detach with ctrl-\
    pull session ls [--json]              running program + its directory per session
    pull session send NAME [-e] TEXT      type into it (-e: press enter)
    pull session capture NAME [-e]        print its screen (-e: keep colours)
    pull session run NAME CMD...          agents: type CMD, wait for output to settle,
                                          print the screen
    pull session kill NAME

StandardErrorPath is accepted, but a terminal merges stderr into stdout, so both go to
StandardOutPath.
