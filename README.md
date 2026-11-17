# pull

A multi-repo git wrapper. `pullfile.plist` lists the repos, their upstreams and pinned
commits. Each repo is cloned to `{pullfile-root}/{repo-name}`. A single `pull commit` writes
one commit, with the same message, identity and signature, to every repo that has changes,
then records the new pins.

## Files

`pullfile.plist` (shared, committed):

    identity: org (selects [orgs.<org>] in local.toml), email = none|local, require_signing
    lint:     no_description, max_subject_length, conventional, no_trailing_period
    hooks:    precommit, postcommit, pull   (arrays of `sh -c` commands, run in the root)
    repos:    [{name, upstream, branch, commit}]

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
    pull status
    pull add PATHS...              each path is staged in the repo that contains it
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

Register it with an agent, e.g. Hermes:

    hermes mcp add pull --command pull --args mcp --root ~/jbisfun

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
