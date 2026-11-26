# Ergana for Claude Code

## Install

1. In a Claude Code session:

   ```
   /plugin marketplace add ErganaAI/claude-plugins
   /plugin install ergana@ergana
   ```

2. Run `/mcp`, select `ergana` and choose Authenticate. Sign in with your company's Google Workspace account.

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

## What a session sends

Besides the tool calls, each connection to Ergana carries the session folder's origin remote (any user name or token
stripped; a local path is never sent) and its git branch at connection time, so the Sessions page names them, and a
hash of the checkout's root folder (its sha256, never the folder itself). Before each edit, the hook sends the edited
file's path: with the root's hash, Ergana finds which part of the repository the file is in and serves that part's
rules. Ergana stores nothing of either path.

When Ergana refuses a stop, the agent's own `check_done` call carries the repository's fingerprint: a sha256 of the
checkout's top-level path, its base commit, its diff from that base and its untracked files that git does not ignore
(`scripts/fingerprint.sh`). The rules check's diff hash is the same fingerprint, so a stop after a turn that changed
nothing in the repository (a write to a scratch folder, a cache, `/tmp`) goes through without a new check. The
fingerprint at the session's start is kept in the plugin's data folder (`${CLAUDE_PLUGIN_DATA}/start/<session id>`,
removed after 30 days), so a session that never changed the repository finishes without a check. Only the hashes leave
the machine.

A Stop hook (`scripts/stop.sh`) compares the fingerprint of the git checkout holding the session's folder with the
session's start and with the last one a passing check cleared (`${CLAUDE_PLUGIN_DATA}/cleared/<session id>`, written by
`scripts/cleared.sh` when `check_done` or `record_check` answers `through: true`). When it differs, the stop is refused
once per fingerprint and the agent's `check_done` decides. A folder that is no git checkout, or has no commit, is not
gated. Shell commands are no longer sent to Ergana's `before_edit`: the fingerprint sees what they changed.

## One sign-in per workspace

`/ergana:login` signs in to one workspace in the machine's default browser (OAuth with PKCE, the client `ergana-cli`),
writes `.ergana` (`workspace = <slug>`) at the repository's root and lists it in `.git/info/exclude`. `/ergana:status`
shows the repository's workspace, where the link comes from and whether it is connected; `/ergana:logout` revokes the
token and removes it (`.ergana` stays). After a login, reconnect ergana in `/mcp` or open a new session.

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
10 s). With no usable token, a `.ergana` that is malformed, or a committed `.ergana` not yet confirmed (below), the
helper sends `Authorization: Bearer ergana-not-connected` and never falls back to the shared sign-in. A repository with
no `.ergana` keeps the shared sign-in.

On a machine with two or more connected workspaces, a `.ergana` committed to git is sent only after the person
confirmed it once for this repository, machine and file content: the session start asks « Envoyer ce dépôt à l'espace
<slug> ? » (or "Send this repository to the <slug> workspace?") with `AskUserQuestion`, and a PostToolUse hook
(`scripts/trust-answer.sh`) records a line in `~/.config/ergana/trusted` (mode 0600, folder 0700), outside the repository:
the sha256 of the absolute git common dir path, a space, and the sha256 of the file content, when the answer is the
agreeing option. A `.ergana` counts as committed when it is in the index or still in `HEAD`. That file only guards
against a silent pick: an agent with an unrestricted shell on the machine could still write it, and the question does not
protect against a compromised local shell. The session start also names the workspace and where the link comes from, and offers `/ergana:login` for a
`.ergana` with no token, or for no `.ergana` when a workspace is connected; « Plus tard » is remembered in
`.git/info/ergana-later`.

## Tests

```
python3 tests/ergana-auth.test.py
sh tests/trust-answer.test.sh
sh tests/workspace-headers.test.sh
sh tests/session-context.test.sh
sh tests/fingerprint.test.sh
sh tests/stop.test.sh
sh tests/cleared.test.sh
sh tests/ergana-tools.test.sh
```
