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
