# Ergana for Claude Code

## Install

1. In a Claude Code session:

   ```
   /plugin marketplace add ErganaAI/claude-plugins
   /plugin install ergana@ergana
   ```

2. Run `/mcp`, choose `plugin:ergana:ergana`, then `Authenticate`. Sign in with your company's Google Workspace account.

3. Turn on updates: run `/plugin`, open the **Marketplaces** tab, select `ergana` and turn auto-update on. Claude
   Code does not update a plugin from this marketplace otherwise. With it on, a new version installs during a
   session; `/reload-plugins` applies it at once, or the next session loads it.

## A whole team

Commit this to the repository's `.claude/settings.json`. Everyone who trusts the folder gets the marketplace with
auto-update already on, and still runs `/plugin install ergana@ergana` and step 2 once:

```json
{
  "extraKnownMarketplaces": {
    "ergana": {
      "source": { "source": "github", "repo": "ErganaAI/claude-plugins" },
      "autoUpdate": true
    }
  }
}
```

## Update by hand

```
claude plugin marketplace update ergana && claude plugin update ergana@ergana
```

Then `/reload-plugins` in a running session. If `DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` or
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is set, auto-update stays off unless `FORCE_AUTOUPDATE_PLUGINS=1` is set
too.

## Commands

| Command | What it is for |
| --- | --- |
| `/ergana:plan [the change, in your words]` | Plans a change before any code is written, then runs its tasks one at a time and lands it as a pull request. |
| `/ergana:review` | Runs an independent review of the branch's change, security included, before it lands. |
| `/ergana:add-decision [the decision, in your words]` | Writes one of the team's decisions, tries it on this repository's code and records it in the catalogue. |
| `/ergana:tracking` | Sets where this repository's tickets go, the GitHub board and columns that show them, and their issue types. |
| `/ergana:login [workspace]` | Signs in to Ergana in the browser; the account chosen there decides the workspace, and this repository is linked to it. |
| `/ergana:status` | Shows which workspace this repository is linked to and whether it is signed in on this machine. |
| `/ergana:logout [workspace]` | Signs out of a workspace on this machine, and the repository stays linked to it. |

In the VS Code extension's panel, plugins are managed with `/plugins`.

## While you work

- Your team's rules reach your agent before it changes code, so it follows them from the first edit.
- Before finishing, your agent checks its change against those rules. If something is off, it fixes it first.
- Lines starting with `Ergana ›` tell you what Ergana is doing; nothing to type.

## What a session sends

Besides the tool calls, a session sends Ergana:

- the repository's origin remote, with any user name or token stripped (a remote that is a local path is never sent);
- its git branch, the session's name and the name of the session's folder (none for a home folder);
- the path of each file the agent edits, as Claude Code gives it: Ergana reduces it on arrival to its place in the
  repository and never keeps or logs it;
- hashes of the checkout and of its changes, never the code itself.

From 0.15.0 no other absolute path leaves the machine.
From 0.17.0 the repository's headers (origin, branch, root hash, folder name) go only with a workspace token, or when
the repository has no `.ergana`; with `Authorization: Bearer ergana-not-connected` a session sends only the workspace
slug and the language.

## One sign-in per workspace

`/ergana:login` opens the machine's default browser at once (OAuth with PKCE, the client `ergana-cli`), with no
question: the account chosen there decides the workspace. The token is kept under that workspace and, when the
repository has no `.ergana`, one is written (`workspace = <slug>`) at its root and listed in `.git/info/exclude`. When
the repository's `.ergana`, or the optional argument, names another workspace, the sign-in is refused in one line and
nothing is stored. `/ergana:status`
shows the repository's workspace, where the link comes from and whether it is connected; `/ergana:logout` revokes the
token and removes it (`.ergana` stays). From 0.19.3 the session that ran the login uses the new token from its next tool call, with no `/mcp` step: the server
lets `ergana-not-connected` through the connection and the tool list and refuses only tool calls, on which Claude Code
runs the headers helper again and retries (#31). Only if a call still fails, in `/mcp`, choose `plugin:ergana:ergana`,
then `Reconnect`.

From 0.19.0 the browser tab returns to a page of the sign-in's last step: connected, with the workspace's name, or
nothing connected, with the reason and `/ergana:login` to copy. The page is served by the script on `127.0.0.1`,
loads nothing from the network and runs only its Copy button, under a nonce Content-Security-Policy.

The token is kept per workspace: in the macOS Keychain (service `ergana`, account `<slug>@<host>`), else in
`~/.config/ergana/<host>/<slug>` (mode 0600). `~/.config/ergana/workspaces` lists the connected workspaces, one
`<host> <slug>` line each, with no secret. The origin is `https://app.ergana.ai`, fixed in `scripts/ergana-auth.py`;
a repository can only choose a workspace, never where a token is sent. Each secret is renewed or revoked only when its
stored origin is exactly the origin in use (scheme included), the Keychain is reached at `/usr/bin/security`, and the
script runs as `python3 -I`. A renewal that has started is not interrupted by a signal until the new pair is stored.

A `.ergana` file, in the project folder or in the main checkout of a linked worktree (a file git tracks wins over one
it does not), makes the MCP headers helper (`scripts/workspace-headers.sh`) send `X-Ergana-Workspace`, `Accept-Language`
and `Authorization: Bearer <the workspace's token>`. The token is renewed by the helper itself when it expires within
5 minutes, under a lock so that two sessions renew it once; the whole helper stays under 8 s (Claude Code stops it at
10 s). With no usable token or a `.ergana` that is malformed, the helper sends `Authorization: Bearer
ergana-not-connected` and never falls back to the shared sign-in. A repository with no `.ergana` keeps the shared
sign-in.

A committed `.ergana` applies like a local one, with no confirmation (DR-0051.D1). The session start names the
workspace and where the link comes from, and offers `/ergana:login` for a `.ergana` with no token; in a repository with no `.ergana` it asks « Se connecter à Ergana ? » (or "Sign in to
Ergana?"), whatever the machine holds; « Plus tard » is remembered in `.git/info/ergana-later`.

## Tests

CI (`.github/workflows/ci.yml`) runs every `tests/*.test.py` and `tests/*.test.sh` on Ubuntu and macOS for each pull request and each push to main; its `test` check is required to merge into main.

```
python3 tests/ergana-auth.test.py
sh tests/workspace-headers.test.sh
sh tests/session-context.test.sh
sh tests/fingerprint.test.sh
sh tests/stop.test.sh
sh tests/cleared.test.sh
sh tests/ergana-tools.test.sh
```
