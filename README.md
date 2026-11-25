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

## Tests

```
sh tests/workspace-headers.test.sh
sh tests/session-context.test.sh
sh tests/fingerprint.test.sh
sh tests/stop.test.sh
sh tests/cleared.test.sh
sh tests/ergana-tools.test.sh
```
