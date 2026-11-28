#!/bin/sh
# impeccable on this machine (impeccable.py): `install <latest|x.y.z>` for the review's design pass, which finds this
# script as $ERGANA_IMPECCABLE (session-context.sh writes it to CLAUDE_ENV_FILE); `refresh` at session start.
exec python3 -I "$(cd "$(dirname "$0")" && pwd)/impeccable.py" "$@"
