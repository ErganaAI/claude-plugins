"""The trial of /ergana:add-decision: a draft decision judged on the repository's current code.

A generic runner. The judge (model, system prompt, JSON schema and a message with ``{{DIFF}}``
and ``{{DIFF_SHA256}}`` placeholders) comes from the Ergana server's ``trial_judge`` tool, with a
``digest`` that proves it was copied exactly. Each item becomes the added lines of a diff, and one
``claude -p`` call per item judges it.

Standard library only: it runs on the developer's machine, from the repository's root.

    python3 trial.py < spec.json

The spec: ``{"run": 1, "judge": {...}, "items": [{"path": "src/a.py", "start": 1, "end": 400},
{"path": "src/b.py", "text": "an injected example"}]}``. On stdout: one JSON line per item.
No item: no call.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# The budget: 8 items of at most 400 lines a run, 3 runs a decision (24 calls), 4 at a time.
MAX_ITEMS = 8
MAX_LINES = 400
MAX_RUNS = 3
PARALLEL = 4
TIMEOUT_S = 120
JUDGE_FIELDS = ("digest", "message", "model", "rule", "schema", "system")


class TrialError(Exception):
    """A spec or environment problem, said plainly to the person."""


def checked(judge: object) -> dict[str, object]:
    """The judge, once its digest matches its fields: a judge altered in the copy is refused."""
    if not isinstance(judge, dict) or sorted(judge) != sorted(JUDGE_FIELDS):
        raise TrialError("the spec has no judge: call trial_judge and pass its judge unchanged")
    fields = {k: v for k, v in judge.items() if k != "digest"}
    canonical = json.dumps(fields, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    if hashlib.sha256(canonical.encode()).hexdigest() != judge["digest"]:
        raise TrialError("the judge was not copied exactly: call trial_judge again")
    return judge


def added_lines(path: str, lines: list[str], start: int = 1) -> str:
    """``lines`` (from line ``start`` of ``path``) as a diff that adds them, at their numbers."""
    body = "".join("+" + line if line.endswith("\n") else "+" + line + "\n" for line in lines)
    return (
        f"diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n"
        f"@@ -0,0 +{start},{len(lines)} @@\n{body}"
    )


def message(judge: dict[str, object], diff: str) -> str:
    """The judge's message for one item's diff."""
    sha = hashlib.sha256(diff.encode()).hexdigest()
    return str(judge["message"]).replace("{{DIFF_SHA256}}", sha).replace("{{DIFF}}", diff)


def item_diff(item: dict[str, object]) -> tuple[str, int, int]:
    """The item's added-lines diff and the line range it covers."""
    path = str(item["path"])
    if "text" in item:
        lines = str(item["text"]).splitlines(keepends=True)
        start = 1
    else:
        try:
            whole = Path(path).read_text(encoding="utf-8").splitlines(keepends=True)
        except (OSError, UnicodeDecodeError) as error:
            raise TrialError(f"{path}: cannot read it as text ({error})") from error
        start = int(item.get("start", 1))  # type: ignore[arg-type]
        end = int(item.get("end", start + MAX_LINES - 1))  # type: ignore[arg-type]
        lines = whole[start - 1 : end]
    if not lines:
        raise TrialError(f"{path}: no line in the range given")
    if len(lines) > MAX_LINES:
        raise TrialError(f"{path}: {len(lines)} lines; give a range of at most {MAX_LINES}")
    return added_lines(path, lines, start), start, start + len(lines) - 1


def ask(judge: dict[str, object], prompt: str) -> dict[str, object]:
    """One call to the judge; its verdict on the draft, or a plain error."""
    try:
        done = subprocess.run(
            [
                "claude",
                "-p",
                prompt,
                "--model",
                str(judge["model"]),
                "--system-prompt",
                str(judge["system"]),
                "--tools",
                "",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--output-format",
                "json",
                "--json-schema",
                json.dumps(judge["schema"]),
            ],
            capture_output=True,
            text=True,
            check=False,
            cwd=tempfile.gettempdir(),
            timeout=TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return {"error": f"the judge did not answer within {TIMEOUT_S} s"}
    if done.returncode != 0:
        tail = (done.stderr or done.stdout).strip()[-300:]
        return {"error": f"claude -p failed (exit {done.returncode}): {tail}"}
    try:
        session = json.loads(done.stdout)
        answer = session.get("structured_output") or json.loads(session["result"])
        found = next(v for v in answer["verdicts"] if v["rule"].split("@")[0] == judge["rule"])
    except (ValueError, KeyError, StopIteration, TypeError):
        return {"error": "the judge's answer had no verdict on the draft"}
    return {k: found.get(k) for k in ("verdict", "line", "reason")}


def run(spec: dict[str, object]) -> list[dict[str, object]]:
    if int(spec.get("run", 1)) > MAX_RUNS:  # type: ignore[arg-type]
        raise TrialError(f"at most {MAX_RUNS} runs a decision: record it as is or stop")
    items = list(spec.get("items") or [])  # type: ignore[call-overload]
    if len(items) > MAX_ITEMS:
        raise TrialError(f"give at most {MAX_ITEMS} items")
    if not items:
        return []
    if shutil.which("claude") is None:
        raise TrialError(
            "the trial needs the `claude` command on PATH, the one that runs Claude Code;"
            " it was not found, so nothing was judged"
        )
    judge = checked(spec.get("judge"))
    diffs = [item_diff(item) for item in items]
    with ThreadPoolExecutor(PARALLEL) as pool:
        verdicts = list(pool.map(lambda d: ask(judge, message(judge, d[0])), diffs))
    return [
        {"path": item["path"], "lines": f"{start}-{end}", **file_line(verdict, start, end)}
        for item, (_, start, end), verdict in zip(items, diffs, verdicts)
    ]


def file_line(verdict: dict[str, object], start: int, end: int) -> dict[str, object]:
    """The verdict with its line in the file's numbering.

    The judge sometimes counts a range's lines from 1, ignoring the hunk header. A line in the
    file's numbering lies inside the range, so one outside it is read as counted from 1.
    """
    line = verdict.get("line")
    if isinstance(line, int) and not start <= line <= end and 1 <= line <= end - start + 1:
        return {**verdict, "line": line + start - 1}
    return verdict


def main() -> int:
    try:
        spec = json.load(sys.stdin)
        results = run(spec)
        for result in results:
            print(json.dumps(result, ensure_ascii=False))
    except TrialError as error:
        print(f"Trial not run: {error}.", file=sys.stderr)
        return 2
    except (ValueError, KeyError, TypeError) as error:
        print(f"Trial not run: the spec is not valid ({error}).", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
