# cpull × pull workspace stacks — handoff (interrupted by reboot)

Nothing committed. Both repos have uncommitted work (see `git status` in ~/jbisfun/cpull and ~/jbisfun/pull).
No scratch e2e setup was created yet. This dir only holds this file. The older probe tools are in ~/.hermes/cache/scratch/haxy-int/ (haxy_probe.py etc.).
Installed ~/.local/bin/{pull,cpull} are UNCHANGED (don't reinstall until tests pass).

## Design decisions
- **stack event** (cpull `src/event/Stack.zig`, kind `stack`, merge_policy `.field_conflicts`):
  `{"id":..,"kind":"stack","data":{"title":..,"description":..,"labels":"a b","members":"core <patchid>\ngroup/app <patchid>","status":{"open":{}}}}`.
  - The status can be `{"closed":{}}` or `{"merged":{"pins":"core <oid>\ngroup/app <oid>"}}`.
  - Members are opaque cross-repo refs: one per repo, 1..64 of them. Repo names are relative with `/` and no `.`/`..`. The patch id must be 32 hex characters.
  - Pins must name members and be full oids.
  - A merged stack is immutable: a new event that changes its members or status is rejected with `StackAlreadyMerged`. On a sync merge, `merged` beats open or closed when the members agree (`resolveMerge`).
  - Allowed for the `.repo` role only, not `.fork`. Server mode validates the event through the same `evt.consume` path.
- **Events repo:** the workspace root's own `.git` if the root is a git repo. Otherwise it's the pullfile `cpull` section `events` key (e.g. `<key>cpull</key><dict><key>events</key><string>dotenv</string></dict>`). ~/jbisfun needs the `cpull.events=dotenv` section added, because ~/jbisfun is not a git repo.
- **Workspace-mode detection** (cpull `src/main.zig` and `workspace.zig detect`):
  - `cpull --workspace DIR`, or the nearest `pullfile.plist` above the cwd, unless a git/xit repo nested inside it is nearer. So running `cpull` inside a member repo still gives plain local mode.
- **Workspace URLs:**
  - `/` is the workspace home.
  - `/home/{issues,patches,stacks}` and `/home/stacks/<id>` are the aggregate pages.
  - Repo pages use the server-style identity `/<wsname>:<key>/...`, where key = pullfile name with `/`→`.` (`group/app` → `group.app`). This is also the documented mapping for `cpull serve` names. The root repo's key is `workspace`.
- **Pin writing:** cpull does NOT write the pullfile. `cpull stack merge` merges the members and records the stack as merged with its pins. **pull** then records the pins via `pull cpull pin STACK`, using pull's normal commit path, so the plist stays byte-identical and the commit is GPG-signed:
  - It saves the pullfile, runs the precommit hook (which copies the pullfile into dotenv), commits the staged repos plus the root repo, then runs the postcommit hook.
  - It refuses if anything was staged beforehand.
  - The commit message is the stack title; if lint rejects that, it falls back to `pin stack <id8>`.
  - cpull's web/TUI merge button calls `pull cpull pin ID` (cwd=root) after merging. Why this split: pull owns the plist writer, the identity and the signing.
- The member merge reuses xit `Merge(.full)` with an explicit target ref:
  - No worktree touch; a fast-forward where possible; a dry run for checks.
  - It records a PatchRev snapshot, and the patch status becomes `merged`, the same as the server.
  - It is all-or-nothing: every member is checked first. It refuses when the target branch is checked out (`checked_out`) or the source has moved past the revision (`out_of_date`).

## Done — cpull (~/jbisfun/cpull), builds; `zig build test` passed (40/40) before the workspace tests; the filtered stack/workspace/pullfile tests pass
- `src/event/Stack.zig` (new) plus its wiring in `src/event.zig` (EventKind `.stack`, parse, consume, record key, allowed kinds) and `src/ui/Repo/Events.zig` (event list).
- `src/test/event/stack.zig` (new):
  - JSON shape.
  - Validation.
  - consume.
  - A sync field conflict (title) → `conflicted_fields`.
  - merged-vs-closed resolution.
  - Merged immutability.
  - Fork role rejected.
- `src/pullfile.zig` (new): parses the plist with the same `xml` package pull uses (dependency added to build.zig/.zon), plus `findRoot`. Has a test.
- `src/workspace.zig` (new): Workspace load, `detect`, `createStack`, `listStacks`, `readStack`, `mergeStack`/`memberMerge`, `buildPage`/`stackDetail`, the WorkspaceHost callbacks (page/source/merge), and `cpull stack new|merge|show|list` (JSON output).
- `src/test/workspace.zig` (new): URL parsing, the stack lifecycle (create→detail→pages→merge→pins→idempotent re-merge), and all-or-nothing when a target is checked out.
- `src/ui/Workspace.zig` (new): the workspace page is markdown rendered on the host (repos grouped by group dir, branch/pin/ahead/open counts, aggregated issues/patches, stacks list, stack page with a member table). It has a "merge stack" SubmitButton form `form:/home/stacks/<id>/merge`.
- `src/ui.zig`:
  - `PageKind.workspace`, `RoutablePage.workspace` + `fromUrlWorkspace`/`fromUrlFor`, and `WorkspaceHost`.
  - `Session.workspace_host`; `Data.workspace` / `workspace_flash`; `HostRequest.workspace_merge`.
  - `Page.init` resolves `session.local` per route in workspace mode.
- `src/web.zig`:
  - `LocalHost` (single repo or workspace), used by requestRepoSource, authorizeWrite and handleSync.
  - POST `.../merge` → `handleWorkspaceMerge` (flash cookie `workspace:`).
- `src/command.zig` and `src/main.zig`: `--workspace`, the `stack` subcommand, and workspace detection in local mode.
- Small edits: `serve.zig` (runLocal takes LocalHost), `serve_ssh.zig`, `ui/widget.zig`, `Repo.zig`, `Header.zig`, `Markdown.zig`.

## Done but UNBUILT/BROKEN — pull (~/jbisfun/pull)
`zig build` currently FAILS (1 step). The error text was cut off, so re-run `cd ~/jbisfun/pull && zig build 2>&1 | grep -B2 -A6 'error:'` first. Likely suspects:
- `sys.envMap` return type vs `map.* =` in `cpullEnv`.
- The `_, const repo = try st.openEvents(...)` destructure.
- `std.json.Stringify.value` over `[]const []const u8` labels.
- `worktree.DIR` / `worktree.path` visibility.
- `sys.out` returning void inside `return sys.out(...)` in pinStack.

What's in place in pull:
- `pkgs/cpull/src/stack.zig` (new): stack replay (`stacks`, `find`, `patchInfo`), `eventsRepo`/`openEvents`, `candidates` (repos on a non-pullfile branch, or with `--branch`, whose tip isn't in the target), `newArgs`, output. It has a test.
- `pkgs/cpull/src/cpull.zig`:
  - New `events()` replay helper; `issues()` is refactored onto it.
  - `str`/`splitLabels` are now pub.
  - `syncAll(..., with_root, ...)` also syncs the root repo as `(root)`.
- `pkgs/mcp/src/cpull.zig`: the syncAll call is updated and `rootHoldsStacks` added. **The stack MCP tools are NOT added yet.**
- `src/cli.zig`:
  - `cpull open [REPO]` (no repo = workspace mode).
  - New commands: `cpull patch [-t -b -l --branch]`, `cpull stacks [--json]`, `cpull stack [--json] ID`, `cpull merge [-m] ID`, `cpull pin [-m] ID`, `cpull checkout ID [NAME]`.
- `src/main.zig`:
  - cpullCmd now takes `*Pullfile`.
  - New helpers: `pinStack`, `stackWithPatches`, `pinCpullIdentity` (sets user.name/email on the root repo and every cloned repo before running cpull), `cpullEnv`, `runCpull`.
  - checkout = `worktree.add(name, name)`, then `git switch -C NAME <source>` in each member's worktree.
- `src/workspace.zig`: `cpull` added to SECTIONS.

## Remaining
1. Fix the pull build. Run `zig build test` in pull and cpull, the full suites. The mcp test counts tools (`7` cpull tools), so update it when adding tools.
2. MCP tools cpull_stacks, cpull_stack, cpull_patch and cpull_merge in `pkgs/mcp/src/cpull.zig` (bump the count in mcp.zig).
3. ycode-pull panel: add a stacks section (list/open/merge) in `cpull.x.lua`. Not started.
4. Server angle (task 4):
   - Confirm a pushed `stack` event is accepted by `cpull serve`. It should be, via the same consume path.
   - Repo names: `.` must be valid in cpull repo names; check `evt.User.validateName`/repo-name validation.
   - A server-side stack page resolving members across the owner's repos is NOT done.
5. Docs: a short `docs/workspace.md` in cpull (events repo, URL scheme, `/`→`.` mapping, stack JSON) and a short section in pull's README.
6. E2E in scratch (~/.hermes/cache/scratch/haxy-stack):
   - Setup:
     - File:// bare remotes.
     - The root as a git repo with a pullfile with no hooks.
     - Repos `core`, `lib`, `group/app`.
     - Feature branches in two of them.
   - Steps:
     - Run `pull cpull patch` with PATH=cpull/zig-out/bin:pull/zig-out/bin.
     - Run `cpull --workspace` in a pty and probe the JSON at `/`, `/home/issues`, `/home/stacks` and `/home/stacks/<id>` (reuse haxy-int/haxy_probe.py).
     - Merge via `pull cpull merge` in one run, and via a web POST to `/home/stacks/<id>/merge` in another.
   - Verify:
     - Pins in the pullfile.
     - `git verify-commit` on the pin commit (needs a scratch local.toml with signing).
     - `git fsck`.
     - A two-workspace concurrent edit → field conflict.
     - `cpull serve` accepts the stack push.
7. Update ycode-dev `references/zig-port.md` cpull notes. Then reinstall ReleaseSafe binaries only after everything passes.

## Known gaps / cautions
- `pull cpull patch` skips repos that are on their pullfile branch with commits ahead of the pin, because cpull rejects source==target. They must be put on a branch first.
- The workspace home runs `evt.consume` + `memberMerge` dry runs per page view. That could be slow on big workspaces.
- cpull's web UI merge flash relies on `pull` being on PATH for the cpull process.
