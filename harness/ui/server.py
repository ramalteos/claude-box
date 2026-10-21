#!/usr/bin/env python3
"""Local dashboard for the claude-box harness.

Read-only, bound to 127.0.0.1, standard library only. It reads the same files the
harness writes — the runner's state directory and the ai-bridge instance — so there
is no second source of truth to drift.

Environment (set by `claude-box harness ui`):
  CB_INSTANCE       instance root
  CB_INSTANCE_SLUG  slug used in state paths and box names
  CB_STATE          runner state dir
  CB_ROOT           repos root
  CB_RUNNER         path to the claude-box runner (used for `ps`)
  CB_PORT           port to bind
"""

import json
import os
import traceback
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

HERE = Path(__file__).resolve().parent
INSTANCE = Path(os.environ.get("CB_INSTANCE", "."))
SLUG = os.environ.get("CB_INSTANCE_SLUG", "instance")
STATE = Path(os.environ.get("CB_STATE", "."))
ROOT = Path(os.environ.get("CB_ROOT", "."))
RUNNER = os.environ.get("CB_RUNNER", "claude-box")
PORT = int(os.environ.get("CB_PORT", "7777"))

HARNESS_STATE = STATE / "harness" / SLUG
BOX_NAME = re.compile(r"^claude-box-[A-Za-z0-9._-]+$")

# Anything token-shaped is redacted before it leaves this process. The harness
# forwards real host credentials into every box, so agent logs are a plausible
# place for one to appear, and a browser tab is the wrong place for it to land.
SECRET_PATTERNS = [
    re.compile(r"gh[pousr]_[A-Za-z0-9]{16,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"sk-ant-[A-Za-z0-9\-_]{16,}"),
    re.compile(r"(?i)\b(token|secret|password|api[_-]?key)\b\s*[:=]\s*\S+"),
]


def redact(text: str) -> str:
    for pattern in SECRET_PATTERNS:
        text = pattern.sub("<redacted>", text)
    return text


def read_text(path: Path, limit: int = 200_000) -> str:
    try:
        with path.open("r", errors="replace") as handle:
            return handle.read(limit)
    except OSError:
        return ""


def frontmatter(path: Path) -> dict:
    """Parse the leading --- block of a markdown doc, plus its body.

    Two things learned the hard way: the closing delimiter is a LINE of ---, not any
    occurrence (an answered question contains " --- " by design), and `title` is a
    frontmatter field — taking the body's first heading instead labelled every card
    "Context", which is the conventional first heading.
    """
    fields: dict = {"body": "", "lists": {}}
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return fields
    front, body = "", text
    if text.startswith("---"):
        match = re.search(r"^---[ \t]*$", text[3:], re.M)
        if match:
            front, body = text[3:3 + match.start()], text[3 + match.end():]
    # Scalars, and flow arrays that may span lines.
    depth, key, buf = 0, None, []
    for line in front.splitlines():
        if depth == 0:
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$", line)
            if not m:
                continue
            key, value = m.group(1), m.group(2).strip()
            if value.startswith("["):
                depth = value.count("[") - value.count("]")
                buf = [value]
                if depth == 0:
                    fields["lists"][key] = _flow_items("".join(buf))
                    key = None
            else:
                fields[key] = value
                key = None
        else:
            buf.append(line)
            depth += line.count("[") - line.count("]")
            if depth <= 0:
                fields["lists"][key] = _flow_items(" ".join(buf))
                depth, key, buf = 0, None, []
    fields["body"] = body.strip()
    if not fields.get("title"):
        for line in body.splitlines():
            if line.startswith("# ") and line[2:].strip().lower() not in ("context", "notes", "result"):
                fields["title"] = line[2:].strip()
                break
    return fields


def _flow_items(raw: str) -> list:
    """Items of a YAML flow array, quote-aware."""
    inner = raw[raw.find("[") + 1:raw.rfind("]")] if "[" in raw else raw
    items, cur, quote = [], "", None
    for ch in inner:
        if quote:
            if ch == quote:
                quote = None
            cur += ch
        elif ch in "\"'":
            quote = ch
            cur += ch
        elif ch == ",":
            items.append(cur)
            cur = ""
        else:
            cur += ch
    items.append(cur)
    out = []
    for item in items:
        item = item.strip()
        if item[:1] in "\"'" and item[-1:] == item[:1]:
            item = item[1:-1]
        if item:
            out.append(item)
    return out


_BOX_CACHE: dict = {"at": 0.0, "names": [], "started": {}}


def running_boxes() -> list:
    """Cached for a couple of seconds: the page polls every 3s and this spawns bash plus a
    docker call, which is a lot of process churn to answer the same question twice."""
    now = time.time()
    if now - _BOX_CACHE["at"] < 2.5:
        return _BOX_CACHE["names"]
    try:
        out = subprocess.run(
            [RUNNER, "ps", "--started"], capture_output=True, text=True, timeout=10,
            env={**os.environ, "CLAUDE_BOX_QUIET": "1"},
        ).stdout
    except Exception:
        _BOX_CACHE.update(at=now, names=[], started={})
        return []
    # name<TAB>RFC3339 — the engine's own answer for when each container started, which is the
    # only source that is right for a box whose driver died or that predates start stamping.
    names, started = [], {}
    for line in out.splitlines():
        parts = line.split("\t")
        candidate = parts[0].strip()
        if not BOX_NAME.match(candidate):
            continue
        names.append(candidate)
        stamp = parts[1].strip() if len(parts) > 1 else ""
        if stamp:
            try:
                from datetime import datetime
                # Docker gives nanoseconds, Apple container may give none; both end in Z.
                clean = re.sub(r"\.\d+", "", stamp.strip())
                if clean.endswith("Z"):
                    clean = clean[:-1] + "+00:00"
                elif not re.search(r"[+-]\d\d:\d\d$", clean):
                    clean += "+00:00"
                started[candidate] = datetime.fromisoformat(clean).timestamp()
            except Exception:
                pass
    _BOX_CACHE.update(at=now, names=names, started=started)
    return names
    names = []
    for line in out.splitlines():
        candidate = line.split()[0] if line.split() else ""
        if BOX_NAME.match(candidate):
            names.append(candidate)
    _BOX_CACHE.update(at=now, names=names)
    return names


RENDERER = HERE.parent / "render-log.py"


def render_log(path: Path, tail: int = 0, last: bool = False) -> str:
    """Render a box's stream-json log into human lines via the shared renderer."""
    if not path.exists():
        return ""
    args = ["python3", str(RENDERER), str(path)]
    if last:
        args.append("--last")
    elif tail:
        args += ["--tail", str(tail)]
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=20)
        return done.stdout or done.stderr
    except Exception:
        return read_text(path)


_SUMMARY_CACHE: dict = {}


def log_summary(path: Path) -> dict:
    """Cost/turns/tools for one box, from its stream. Cached on (path, mtime, size) so a
    finished box is parsed once and a running one is re-read as it grows."""
    try:
        stat = path.stat()
    except OSError:
        return {}
    key = (str(path), stat.st_mtime, stat.st_size)
    hit = _SUMMARY_CACHE.get(str(path))
    if hit and hit["key"] == key:
        return hit["value"]
    value = {}
    try:
        done = subprocess.run(["python3", str(RENDERER), str(path), "--summary"],
                              capture_output=True, text=True, timeout=25)
        value = json.loads(done.stdout or "{}")
    except Exception:
        value = {}
    _SUMMARY_CACHE[str(path)] = {"key": key, "value": value}
    return value


def started_from_task(box: str):
    """When the host recorded this box starting, read straight off the task documents.

    Deliberately not via tasks(): that calls back into box_info and would recurse."""
    for path in (INSTANCE / "projects").glob("*/tasks/*.md"):
        text = read_text(path, 4000)
        if ("box: %s" % box) not in text:
            continue
        match = re.search(r"^started_at:\s*(\S+)", text, re.M)
        if not match:
            return None
        try:
            from datetime import datetime, timezone
            stamp = match.group(1).replace("Z", "+00:00")
            return datetime.fromisoformat(stamp).replace(tzinfo=timezone.utc).timestamp()
        except Exception:
            return None
    return None


def box_info(name: str) -> dict:
    """Split a harness box name back into its parts and age it from its log file."""
    role, task = "", ""
    prefix = f"claude-box-h-{SLUG}-"
    if name.startswith(prefix):
        rest = name[len(prefix):]
        if rest == "pm" or rest.startswith("pm-"):
            role, task = "project-manager", "(tick)"
        else:
            # Longest first: "devops-engineer" must win over "devops".
            known_roles = sorted(
                ("lead-dev", "devops", "qa-reviewer", "project-manager", "cataloguer",
                 "software-engineer", "devops-engineer", "auditor", "oncall-guide"),
                key=len, reverse=True,
            )
            for known in known_roles:
                if rest.startswith(known):
                    role = known
                    task = rest[len(known):].lstrip("-")
                    break
            else:
                role = rest
    log = STATE / "logs" / f"{name}.log"
    started = None
    candidates = [log] + sorted((HARNESS_STATE / "ticks").glob(f"*/logs/{name}.log"))
    for candidate in candidates:
        if not candidate.exists():
            continue
        log = candidate
        # The runner writes <log>.started when it launches the box. Prefer it: box names are
        # reused and the log is truncated in place, so the file's own timestamps belong to
        # whichever box held the name first.
        stamp = candidate.with_suffix(candidate.suffix + ".started")
        if stamp.exists():
            try:
                started = float(read_text(stamp).strip() or 0) or None
            except ValueError:
                started = None
        break

    if started is None:
        # The host stamps started_at on the task when it launches a box; match by the task's
        # `box` field. Never fall back to the log's mtime — that is the LAST write, so a
        # streaming box reads as though it started a second ago.
        started = started_from_task(name)
    if started is None:
        # Last resort and most authoritative: ask the engine when the container started.
        started = (_BOX_CACHE.get("started") or {}).get(name)
    return {
        "name": name,
        "role": role or "?",
        "task": task,
        "started": started,
        "elapsed": int(time.time() - started) if started else None,
        "log": str(log) if log.exists() else "",
        "harness": name.startswith(prefix),
        # What it is doing right now — a box with no visible activity is indistinguishable
        # from a hung one, which is exactly how this looked before it streamed.
        "last": redact(render_log(log, last=True).strip())[:160] if log.exists() else "",
        "run": log_summary(log) if log.exists() else {},
    }


_PROGRESS_CACHE: dict = {}


def worktree_ids(task_path: str) -> list:
    """Worktree directory names to try for a task, newest convention first.

    `_wt/<project>-<task-id>` is unique; `_wt/<task-id>` was the earlier convention and
    collides whenever two projects share a task id, so it is only a fallback for worktrees
    created before the change."""
    parts = [p for p in task_path.split("/") if p]
    stem = re.sub(r"\.md$", "", parts[-1]) if parts else ""
    project = parts[1] if len(parts) > 2 and parts[0] == "projects" else ""
    out = []
    if project and stem:
        out.append("%s-%s" % (project, stem))
    if stem:
        out.append(stem)
    return out


def worktree_gitdir(task_id: str, repo: str):
    """The worktree's real gitdir, and the pair of paths git needs to read it.

    The worktree's own `.git` file holds a CONTAINER path, so `git -C <worktree>` fails on
    the host. But `--git-dir <repo>/.git/worktrees/<id> --work-tree <worktree>` bypasses
    that file completely and works — which is how this reads an agent's changes without
    spawning a container, and without guessing from mtimes.
    """
    if not re.match(r"^[A-Za-z0-9._-]{1,64}$", task_id):
        return None
    work = ROOT / "_wt" / task_id
    if not work.is_dir():
        return None
    candidates = []
    if repo and re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", repo.split("/")[-1]):
        candidates.append(ROOT / repo.split("/")[-1])
    candidates += [p.parent for p in ROOT.glob("*/.git/worktrees/%s" % task_id)]
    for repo_path in candidates:
        gitdir = repo_path / ".git" / "worktrees" / task_id
        if gitdir.is_dir():
            return {"work": work, "gitdir": gitdir, "repo": repo_path.name}
    return None


def git_in_worktree(found: dict, args: list, timeout: int = 30, quiet: bool = False) -> str:
    """Empty string on failure when quiet, so a caller can fall back cleanly. Returning
    stderr here put "fatal: no upstream configured" into the commit list."""
    done = subprocess.run(
        ["git", "--git-dir", str(found["gitdir"]), "--work-tree", str(found["work"]), *args],
        capture_output=True, text=True, timeout=timeout)
    if done.returncode == 0:
        return done.stdout
    return "" if quiet else (done.stderr or "")


def worktree_progress_for(key: str) -> dict:
    found, name = resolve_worktree(key)
    return worktree_progress(name, (task_by_key(key).get("repo") or ""))


def worktree_progress(task_id: str, repo: str = "") -> dict:
    """What a box has actually CHANGED, according to git.

    An earlier version walked the filesystem for recent mtimes and reported ~6000 files:
    creating the worktree checks out the whole repo, so every file looks freshly written.
    Git knows the difference between "checked out" and "changed"; nothing else does.
    """
    now = time.time()
    key = "%s:%s" % (task_id, repo)
    hit = _PROGRESS_CACHE.get(key)
    if hit and now - hit["at"] < 10:
        return hit["value"]

    found = worktree_gitdir(task_id, repo)
    value = {"worktree": str(ROOT / "_wt" / task_id), "exists": bool(found), "repo": "",
             "changed": [], "diffstat": "", "commits": [], "newest": None}
    if found:
        value["repo"] = found["repo"]
        status = git_in_worktree(found, ["status", "--porcelain"])
        for line in status.splitlines():
            if len(line) < 4:
                continue
            code, path = line[:2].strip() or "?", line[3:].strip().strip('"')
            full = found["work"] / path
            when = None
            try:
                when = full.stat().st_mtime if full.exists() else None
            except OSError:
                when = None
            if when:
                value["newest"] = max(value["newest"] or 0, when)
            value["changed"].append({"code": code, "path": path, "when": when})
        value["changed"].sort(key=lambda c: c["when"] or 0, reverse=True)
        value["diffstat"] = git_in_worktree(found, ["--no-pager", "diff", "--stat", "HEAD"]).strip()
        # A branch with no upstream has not been pushed yet — that is information, not an
        # error to display.
        log = git_in_worktree(found, ["--no-pager", "log", "--oneline", "-8", "@{upstream}..HEAD"],
                              quiet=True)
        value["pushed"] = bool(log)
        if not log:
            log = git_in_worktree(found, ["--no-pager", "log", "--oneline", "-3"], quiet=True)
        value["commits"] = [l for l in log.splitlines() if l][:8]
    _PROGRESS_CACHE[key] = {"at": now, "value": value}
    return value


def ticks(limit: int = 12) -> list:
    out = []
    tick_dir = HARNESS_STATE / "ticks"
    if not tick_dir.is_dir():
        return out
    for entry in sorted(tick_dir.iterdir(), reverse=True)[:limit]:
        summary = {}
        for line in read_text(entry / "summary.txt").splitlines():
            key, _, value = line.partition(" ")
            if key:
                summary[key] = value
        violations = [
            line.split("\t")[0] for line in read_text(entry / "violations.tsv").splitlines() if line
        ]
        out.append({
            "id": entry.name,
            "when": entry.stat().st_mtime,
            "accepted": summary.get("accepted", "?"),
            "rejected": summary.get("rejected", "?"),
            "pending_memory": summary.get("pending_memory", "?"),
            "violations": violations,
            "done": (entry / "summary.txt").exists(),
        })
    return out


def runs(limit: int = 15) -> list:
    """Ticks and `harness do` runs, with what each actually did."""
    out = []
    tick_dir = HARNESS_STATE / "ticks"
    if not tick_dir.is_dir():
        return out
    for entry in sorted(tick_dir.iterdir(), reverse=True)[:limit]:
        fields = {}
        for line in read_text(entry / "summary.txt").splitlines():
            key, _, value = line.partition(" ")
            if key:
                fields[key] = value
        violations = [l.split("\t")[0] for l in read_text(entry / "violations.tsv").splitlines() if l]
        promoted = [l.split("\t")[0] for l in read_text(entry / "autonomy.tsv").splitlines() if l]
        cost = 0.0
        for log in (entry / "logs").glob("*.log"):
            cost += (log_summary(log).get("cost_usd") or 0.0)
        out.append({
            "id": entry.name,
            "kind": fields.get("kind", "tick"),
            "when": entry.stat().st_mtime,
            "dispatched": fields.get("accepted", fields.get("tasks", "0")),
            "refused": fields.get("rejected", "0"),
            "done": fields.get("done"),
            "blocked": fields.get("blocked"),
            "pending_memory": fields.get("pending_memory", "0"),
            "promoted": promoted,
            "violations": violations,
            "cost_usd": round(cost, 4) if cost else None,
            "finished": "finished" in fields,
        })
    return out


def timeline(limit: int = 60) -> list:
    """One chronological feed of what happened. The same facts exist across three tables;
    reconstructing an order from them by eye is work the page should do."""
    events = []
    tick_dir = HARNESS_STATE / "ticks"
    if tick_dir.is_dir():
        for entry in tick_dir.iterdir():
            when = entry.stat().st_mtime
            fields = {}
            for line in read_text(entry / "summary.txt").splitlines():
                key, _, value = line.partition(" ")
                if key:
                    fields[key] = value
            kind = fields.get("kind", "tick")
            events.append({"when": when, "what": "run", "detail": "%s %s" % (kind, entry.name)})
            for line in read_text(entry / "autonomy.tsv").splitlines():
                if not line:
                    continue
                path, _, note = line.partition("\t")
                events.append({"when": when, "what": "merged" if note.startswith("merged") else "promoted",
                               "detail": "%s — %s" % (path, note)})
            for line in read_text(entry / "violations.tsv").splitlines():
                if line:
                    events.append({"when": when, "what": "reverted", "detail": line.replace("\t", " — ")})
    for path in list((STATE / "logs").glob("claude-box-*.log")):
        try:
            stat = path.stat()
        except OSError:
            continue
        info = log_summary(path)
        if info.get("status") and info["status"] != "running":
            events.append({"when": stat.st_mtime, "what": "box finished",
                           "detail": "%s — %s%s" % (path.stem, info["status"],
                                                    (", $%.4f" % info["cost_usd"]) if info.get("cost_usd") else "")})
    for task in tasks():
        if task["status"] in ("cancelled", "done", "blocked"):
            doc = INSTANCE / task["path"]
            try:
                events.append({"when": doc.stat().st_mtime, "what": task["status"],
                               "detail": "%s — %s" % (task["path"], task["title"][:80])})
            except OSError:
                pass
    events.sort(key=lambda e: e["when"], reverse=True)
    return events[:limit]


def role_stats() -> list:
    """Where the money and the time go, per role — and which role fails."""
    buckets: dict = {}
    for path in list((STATE / "logs").glob("claude-box-*.log")) + \
                list((HARNESS_STATE / "ticks").glob("*/logs/*.log")):
        info = log_summary(path)
        if not info or info.get("status") in (None, "running"):
            continue
        role = box_info(path.stem).get("role") or "?"
        b = buckets.setdefault(role, {"role": role, "runs": 0, "cost": 0.0, "seconds": 0.0,
                                      "tools": 0, "failures": 0})
        b["runs"] += 1
        b["cost"] += info.get("cost_usd") or 0.0
        b["seconds"] += info.get("duration_s") or 0.0
        b["tools"] += info.get("tools") or 0
        if info.get("status") not in ("success", "done"):
            b["failures"] += 1
    out = []
    for b in buckets.values():
        runs = max(1, b["runs"])
        out.append({**b, "cost": round(b["cost"], 4),
                    "avg_cost": round(b["cost"] / runs, 4),
                    "avg_seconds": round(b["seconds"] / runs, 1)})
    out.sort(key=lambda x: x["cost"], reverse=True)
    return out


def attention(task_list: list, box_list: list) -> list:
    """Everything that needs a human, with the REASON attached.

    The first version said things like "blocked — see # Result" and "2 tool error(s)", which
    is a notification, not information: you still had to go and find out what happened.
    """
    items = []
    for task in task_list:
        for question in task["unanswered"]:
            items.append({"kind": "question", "task": task["path"], "id": task["id"],
                          "title": task["title"],
                          "detail": question, "action": "claude-box harness answer",
                          "open": "task"})
        if task["status"] == "blocked":
            detail = task.get("blocked_reason") or task.get("why") or "no reason recorded in the task"
            if task.get("qa") and task["qa"] not in ("approved", "changes-requested"):
                detail = "qa: %s — %s" % (task["qa"].replace("-", " "), detail)
            items.append({"kind": "blocked", "task": task["path"], "id": task["id"],
                          "title": task["title"],
                          "detail": detail, "open": "task",
                          "action": "claude-box harness do --retry"})
        elif task.get("stalled"):
            items.append({"kind": "stalled", "task": task["path"], "id": task["id"],
                          "title": task["title"],
                          "detail": task.get("next_action") or "nothing is working this task",
                          "open": "task", "action": task.get("next_command", "")})
    # Deliberately NO pr rows here: pull requests have their own section. "Needs you" is for
    # things that need a decision from you and are not visible elsewhere.
    for box in box_list:
        run = box.get("run") or {}
        if run.get("status") not in (None, "running", "success", "done"):
            items.append({"kind": "box", "task": box.get("task", ""), "title": box["name"],
                          "detail": "box ended %s%s" % (run["status"], box_error_hint(box)),
                          "open": "log", "action": "claude-box logs " + box["name"]})
        # NOT a row per tool error. That count is cumulative over the whole stream, so a
        # single denied command early on kept a row in "needs you" for the rest of a
        # 45-minute run — while the agent had long since recovered and needed nothing. The
        # box's own card carries the error count; this list is for things that are stuck.
    return items


def box_error_hint(box: dict) -> str:
    """The actual failing line from a box's stream, so a row explains itself."""
    log = Path(box.get("log") or "")
    if not log or not log.exists():
        return ""
    rendered = render_log(log, tail=400)
    lines = [l for l in rendered.splitlines() if l.strip().startswith("!")]
    if not lines:
        return ""
    return " — " + " ".join(lines[-1].split())[:220]


def jira_config() -> dict:
    """Where a Jira key should link to, so the page can turn `DPT-1234` into something
    clickable rather than a string you have to paste somewhere."""
    try:
        config = json.loads(read_text(INSTANCE / "instance.config.json"))
    except Exception:
        return {"enabled": False}
    block = config.get("jira") or {}
    site = (block.get("site") or "").rstrip("/")
    if site and not site.startswith("http"):
        site = "https://%s" % site
    return {"enabled": bool(block.get("enabled")), "site": site,
            "project": block.get("project") or ""}


def roles() -> list:
    """The roles this panel can dispatch: what each one is for, what it runs on, and what it
    has cost. Knowing a `qa-reviewer` exists is useless without knowing it runs on opus at
    xhigh and costs 5x the implementer."""
    try:
        config = json.loads(read_text(INSTANCE / "instance.config.json"))
    except Exception:
        config = {}
    names = config.get("roles") or []
    tiers, efforts = config.get("roleTiers") or {}, config.get("roleEffort") or {}
    models = config.get("models") or {}
    stats = {row["role"]: row for row in role_stats()}
    busy = {}
    for name in running_boxes():
        info = box_info(name)
        busy.setdefault(info.get("role") or "?", []).append(info.get("task") or name)

    out = []
    for name in names:
        definition = INSTANCE / ".claude" / "agents" / ("%s.md" % name)
        fields = frontmatter(definition) if definition.exists() else {}
        tier = tiers.get(name, "standard")
        row = {
            "role": name,
            "installed": definition.exists(),
            "description": fields.get("description", ""),
            "tier": tier,
            "model": models.get(tier, tier),
            "effort": efforts.get(name, ""),
            "busy": busy.get(name, []),
        }
        row.update({k: stats.get(name, {}).get(k, 0)
                    for k in ("runs", "failures", "cost", "avg_cost", "avg_seconds", "tools")})
        out.append(row)
    # A role that has run but is no longer configured still spent money; show it.
    for name, row in stats.items():
        if name not in names:
            out.append({"role": name, "installed": False, "description": "(not in this panel's roles)",
                        "tier": "", "model": "", "effort": "", "busy": [], **row})
    return out


def pull_requests(task_list: list) -> list:
    """Every PR the panel knows about, always visible.

    "Needs you" is filtered to things that need YOU — a PR under active work does not, so it is
    correctly absent there. That is not a reason to be unable to see it."""
    out = []
    for task in task_list:
        for pr in task.get("pr_status") or []:
            out.append({
                "task": task["path"], "id": task["id"], "title": task["title"],
                "project": task["project"], "repo": task.get("repo", ""),
                "number": pr.get("number"), "url": pr.get("url"),
                "state": pr.get("state", ""), "draft": bool(pr.get("isDraft")),
                "ci": pr.get("ci", ""), "ci_detail": pr.get("ci_detail", ""),
                "caused_here": pr.get("caused_here") or [],
                "pre_existing": pr.get("pre_existing") or [],
                "merge_state": pr.get("mergeStateStatus", ""),
                "qa": task.get("qa", ""), "arch": task.get("arch", ""),
                "status": task["status"], "working": bool(task.get("working")),
                "mergeable": (task.get("qa") == "approved" and not pr.get("isDraft")
                              and pr.get("ci") == "passing" and pr.get("state") == "OPEN"),
                "files": pr.get("changedFiles"), "additions": pr.get("additions"),
                "deletions": pr.get("deletions"),
            })
    out.sort(key=lambda r: (r["state"] != "OPEN", r["number"] or 0))
    return out


def memory() -> dict:
    """What is actually IN memory, per tier — the page could show what agents proposed but
    not what had been accepted, which is the half that changes their behaviour."""
    out = {"global": [], "repo": [], "kb": {"index": "", "docs": []}}
    for path in sorted((HARNESS_STATE.parent / "memory").glob("*.md")):
        text = redact(read_text(path, 20000)).strip()
        out["global"].append({"file": path.name, "tier": "global", "path": path.name,
                              "preview": text[:300] + ("…" if len(text) > 300 else ""),
                              "body": text})
    # Repo-scoped memory is the panel's (memory/repos/<repo>/), so accepting a learning never
    # writes into someone's checkout. A repo that ships its own .harness/memory is still read
    # and shown — that is a team publishing learnings alongside its code.
    seen = set()
    for path in sorted((INSTANCE / "memory" / "repos").glob("*/*.md")):
        text = redact(read_text(path, 20000)).strip()
        seen.add((path.parent.name, path.name))
        out["repo"].append({"file": path.name, "repo": path.parent.name, "tier": "repo",
                            "path": str(path.relative_to(INSTANCE)),
                            "preview": text[:300] + ("…" if len(text) > 300 else ""),
                            "body": text})
    for path in sorted(ROOT.glob("*/.harness/memory/**/*.md")):
        rel = path.relative_to(ROOT)
        if (rel.parts[0], path.name) in seen:
            continue
        text = redact(read_text(path, 20000)).strip()
        out["repo"].append({"file": path.name, "repo": rel.parts[0], "tier": "repo",
                            "shipped": True, "path": str(rel),
                            "preview": text[:300] + ("…" if len(text) > 300 else ""),
                            "body": text})
    index = INSTANCE / "knowledge" / "index.md"
    if index.exists():
        out["kb"]["index"] = redact(read_text(index, 20000)).strip()
    out["kb"]["docs"] = [str(p.relative_to(INSTANCE)) for p in sorted((INSTANCE / "knowledge").rglob("*.md"))
                         if p.name != "index.md"][:60]
    return out


def objectives() -> list:
    """The why behind each project. Nothing wrote these for months and nothing showed them,
    which is how an empty directory stays empty: no page ever asked the question."""
    out = []
    for path in sorted((INSTANCE / "objectives").glob("*.md")):
        fields = frontmatter(path)
        text = redact(read_text(path, 20000))
        body = "\n".join(l for l in text.splitlines() if not l.startswith("---"))
        title = ""
        for line in body.splitlines():
            if line.startswith("# "):
                title = line[2:].strip()
                break
        out.append({
            "file": path.name,
            "path": str(path.relative_to(INSTANCE)),
            "title": title or fields.get("title") or path.stem,
            "status": fields.get("status", ""),
            "projects": fields["lists"].get("projects", []),
            "body": body.strip(),
        })
    return out


def knowledge() -> dict:
    """What the cataloguer has actually written, by kind. An index alone cannot tell you
    whether anything is behind it."""
    root = INSTANCE / "knowledge"

    def entry(path):
        text = redact(read_text(path, 20000))
        body = "\n".join(l for l in text.splitlines() if not l.startswith("---")).strip()
        title = next((l[2:].strip() for l in body.splitlines() if l.startswith("# ")), path.stem)
        return {"file": path.name, "path": str(path.relative_to(INSTANCE)), "title": title,
                "preview": body[:300] + ("…" if len(body) > 300 else ""), "body": body}

    kinds = {}
    for kind in ("findings", "runbooks", "services", "teams"):
        kinds[kind] = [entry(p) for p in sorted((root / kind).glob("**/*.md"))]
    loose = [entry(p) for p in sorted(root.glob("*.md")) if p.name != "index.md"]
    index = root / "index.md"
    return {"kinds": kinds, "loose": loose,
            "index": redact(read_text(index, 20000)).strip() if index.exists() else "",
            "total": sum(len(v) for v in kinds.values()) + len(loose)}


def spend() -> dict:
    """What this panel has cost, from the boxes' own result events. Today, and all time."""
    today, total, boxes = 0.0, 0.0, 0
    # Local midnight, not UTC's: "today" on this page means the reader's day.
    midnight = time.mktime(time.localtime()[:3] + (0, 0, 0, 0, 0, -1))
    seen = set()
    candidates = list((STATE / "logs").glob("claude-box-*.log"))
    candidates += list((HARNESS_STATE / "ticks").glob("*/logs/*.log"))
    for path in candidates:
        if path.name in seen:
            continue
        seen.add(path.name)
        info = log_summary(path)
        cost = info.get("cost_usd") or 0.0
        if not cost:
            continue
        boxes += 1
        total += cost
        try:
            if path.stat().st_mtime >= midnight:
                today += cost
        except OSError:
            pass
    return {"today": round(today, 4), "total": round(total, 4), "boxes": boxes}


_PR_CACHE: dict = {}
GH = os.environ.get("CB_GH", "gh")


_BASE_FAIL_CACHE: dict = {}


def failing_on_base(pr_url: str, base: str, names: list) -> list:
    """Which of these checks are already failing on the base branch.

    A red check that is also red on the base is not this PR's doing. Without that distinction
    "CI failing" sends an agent to fix code it did not break."""
    if not base or not names:
        return []
    match = re.match(r"https?://[^/]+/([^/]+)/([^/]+)/pull/", pr_url or "")
    if not match:
        return []
    owner, repo = match.group(1), match.group(2)
    key = "%s/%s@%s" % (owner, repo, base)
    now = time.time()
    hit = _BASE_FAIL_CACHE.get(key)
    if not hit or now - hit["at"] > 300:
        failing = None
        try:
            done = subprocess.run(
                [GH, "api", "repos/%s/%s/commits/%s/check-runs" % (owner, repo, base),
                 "--jq", '.check_runs[] | select(.conclusion=="failure" or .conclusion=="timed_out") | .name'],
                capture_output=True, text=True, timeout=25)
            if done.returncode == 0:
                failing = {line.strip() for line in done.stdout.splitlines() if line.strip()}
        except Exception:
            failing = None
        if failing is None:
            # Unknown is not "nothing": caching an empty set here labelled every base-broken
            # check as this PR's for the next five minutes.
            return []
        _BASE_FAIL_CACHE[key] = {"at": now, "failing": failing}
        hit = _BASE_FAIL_CACHE[key]
    return [n for n in names if n in hit["failing"]]


def pr_status(url: str) -> dict:
    """Live state of one pull request, cached for a minute.

    This is what makes the page a place to DECIDE rather than watch: without CI and review
    state you have to leave for GitHub to answer "can this merge".
    """
    now = time.time()
    hit = _PR_CACHE.get(url)
    if hit and now - hit["at"] < 60:
        return hit["value"]
    value = {"url": url, "error": None}
    # The url comes from agent-written frontmatter and goes straight to gh's argv.
    if not re.match(r"^https://[^/\s]+/[^/\s]+/[^/\s]+/pull/\d+$", url or ""):
        value["error"] = "not a pull request url"
        return value
    try:
        view = subprocess.run(
            [GH, "pr", "view", url, "--json",
             "number,state,isDraft,mergeable,mergeStateStatus,reviewDecision,title,"
             "additions,deletions,changedFiles,baseRefName,headRefName,url"],
            capture_output=True, text=True, timeout=25)
        if view.returncode == 0 and view.stdout.strip():
            value.update(json.loads(view.stdout))
        else:
            value["error"] = (view.stderr or "gh pr view failed").strip()[:200]
        checks = subprocess.run([GH, "pr", "checks", url, "--json", "name,state,link"],
                                capture_output=True, text=True, timeout=25)
        if checks.returncode in (0, 8) and checks.stdout.strip():
            rows = json.loads(checks.stdout)
            value["checks"] = rows[:20]
            # SKIPPED is not SUCCESS. Counting "no failures" as green reported CI as passing on
            # a PR where eleven of twelve checks had been skipped and nothing meaningful ran.
            tally: dict = {}
            for row in rows:
                tally[row.get("state") or "?"] = tally.get(row.get("state") or "?", 0) + 1
            value["check_counts"] = tally
            failed_rows = [r for r in rows if r.get("state") in
                           ("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED")]
            pending = sum(tally.get(k, 0) for k in ("PENDING", "IN_PROGRESS", "QUEUED"))
            passed = tally.get("SUCCESS", 0)

            # SKIPPED is normal in a monorepo: jobs are path-filtered, so most of them skip on
            # any given PR. Skipping is not a finding; a FAILING check is, and so is a PR that
            # the repository's own rules say is blocked.
            if failed_rows:
                value["ci"] = "failing"
            elif pending:
                value["ci"] = "running"
            elif passed:
                value["ci"] = "passing"
            elif rows:
                value["ci"] = "none-ran"      # informational, not a problem by itself
            else:
                value["ci"] = "none"
            value["ci_detail"] = ", ".join(
                "%d %s" % (n, k.lower()) for k, n in sorted(tally.items(), key=lambda kv: -kv[1]))
            value["failing_checks"] = [r.get("name") for r in failed_rows if r.get("name")]
            value["passing_checks"] = [r.get("name") for r in rows if r.get("state") == "SUCCESS"]
            # Is this the PR's fault? The same job failing on the base branch is somebody
            # else's problem, and telling an agent to "fix CI" in that case sends it to change
            # code that is not broken.
            if value["failing_checks"]:
                value["pre_existing"] = failing_on_base(url, value.get("baseRefName") or "",
                                                        value["failing_checks"])
                value["caused_here"] = [n for n in value["failing_checks"]
                                        if n not in value["pre_existing"]]
        else:
            value["ci"] = "none"
    except Exception as exc:
        value["error"] = "%s: %s" % (type(exc).__name__, exc)
    _PR_CACHE[url] = {"at": now, "value": value}
    return value


def tasks() -> list:
    """Task documents only. A project.md also carries a `status`, and counting those as
    tasks is what put a stray "active" column on the board."""
    out = []
    projects = INSTANCE / "projects"
    if not projects.is_dir():
        return out
    for path in sorted(projects.glob("*/tasks/*.md")):
        fields = frontmatter(path)
        status = fields.get("status")
        if not status:
            continue
        questions = [redact(q) for q in fields["lists"].get("open_questions", [])]
        out.append({
            "path": str(path.relative_to(INSTANCE)),
            "abs": str(path),
            "project": path.parent.parent.name,
            "id": fields.get("id", path.stem),
            "title": redact(fields.get("title") or path.stem),
            "description": redact(fields.get("description", "")),
            "status": status,
            "repo": fields.get("target_repo", ""),
            "assignee": fields.get("assignee", ""),
            "prs": fields["lists"].get("pr", []),
            "qa": fields.get("qa", ""),
            "criteria": [redact(c) for c in fields["lists"].get("acceptance_criteria", [])],
            "questions": questions,
            "unanswered": [q for q in questions if " --- " not in q],
            "depends_on": fields["lists"].get("depends_on", []),
            "body": redact(fields.get("body", ""))[:4000],
            "blocked_reason": redact(fields.get("blocked_reason", "")),
            "jira": fields.get("jira", ""),
            "box": fields.get("box", ""),
            "started_at": fields.get("started_at", ""),
            # The paragraph that explains a block, so the page can show WHY rather than
            # telling you to go and read the document yourself.
            "why": why_blocked(fields.get("body", "")),
            # A card cannot carry a paragraph; it can carry the first sentence, which is what
            # makes "blocked" next to "CI passing" stop reading as a contradiction.
            "why_short": short_why(why_blocked(fields.get("body", ""))),
        })
    for task in out:
        task["pr_status"] = [pr_status(u) for u in task["prs"][:3]]
    annotate_next_action(out)
    return out


def annotate_next_action(task_list: list) -> None:
    """What has to happen next, and whether anything is actually happening.

    `in-progress` with a box running and `in-progress` with nothing running look identical on
    a board, and the second one is the state that quietly wastes a day: a review round ended
    with changes requested, the run moved on, and the task sits there. Say which it is.
    """
    working = set()
    for name in running_boxes():
        info = box_info(name)
        if info.get("task"):
            working.add(info["task"])

    for task in task_list:
        task["working"] = task["id"] in working or Path(task["path"]).stem in working
        task["stalled"] = False
        task["next_action"] = ""
        task["next_command"] = ""
        if task["working"] or task["status"] in ("done", "cancelled"):
            continue
        pr = (task.get("pr_status") or [{}])[0] if task.get("pr_status") else {}
        one_task = "claude-box harness do --task /%s" % task["path"]
        if task["unanswered"]:
            task["next_action"] = "waiting on your answer"
            task["next_command"] = "claude-box harness answer"
        elif task.get("arch") == "changes-requested":
            task["stalled"] = True
            task["next_action"] = "the architect rejected the design — it needs reworking, not rebuilding"
            task["next_command"] = "claude-box harness tick"
        elif task.get("qa") == "changes-requested":
            task["stalled"] = True
            task["next_action"] = "qa requested changes and no box is working it — needs another round"
            task["next_command"] = one_task
        elif task.get("qa") and task["qa"] not in ("approved", "changes-requested"):
            # There are two verdicts. Anything else is a review that tried to hand
            # verification to a person, and the host turns it back into another round.
            task["stalled"] = True
            task["next_action"] = "qa says %s — CI is the source of truth, so this is another round" % (
                task["qa"].replace("-", " "))
            task["next_command"] = one_task
        elif task["status"] == "in-review" and pr:
            if pr.get("isDraft"):
                task["next_action"] = "draft PR — the block in its body has to clear first"
            elif task.get("qa") == "approved" and pr.get("ci") == "passing":
                task["next_action"] = "qa approved and CI green (%s) — yours to merge" % (
                    pr.get("ci_detail") or "")
            elif pr.get("ci") == "failing":
                mine = pr.get("caused_here") or []
                task["stalled"] = bool(mine)
                task["next_action"] = (
                    "CI failing on %s — this change caused it" % ", ".join(mine[:3]) if mine
                    else "CI failing, but the same checks already fail on %s — not this PR"
                         % (pr.get("baseRefName") or "the base"))

            elif not task.get("qa"):
                task["stalled"] = True
                task["next_action"] = "PR is open but nobody has reviewed it"
                task["next_command"] = one_task
        elif task["status"] == "in-progress":
            task["stalled"] = True
            task["next_action"] = "marked in-progress but no box is working it"
            task["next_command"] = one_task
        elif task["status"] == "blocked":
            task["stalled"] = True
            task["next_action"] = task.get("blocked_reason") or "blocked"
            task["next_command"] = "claude-box harness do --retry"


def short_why(why: str) -> str:
    """One line of a block explanation, for a card. The full text lives in the drawer."""
    if not why:
        return ""
    text = " ".join(why.split())
    text = re.sub(r"^#+\s*Blocked on[`:.\s]*", "", text)
    cut = text.find(". ")
    return (text[:cut + 1] if 40 < cut < 160 else text[:150].rstrip() + "…")


def why_blocked(body: str) -> str:
    """The sentences that explain a block, pulled out of # Result or # Notes.

    "blocked — see # Result" is a row that makes you go and look; the point of the panel is
    that you should not have to."""
    if not body:
        return ""
    text = redact(body)
    for marker in ("## Blocked on", "**Not verified", "Blocked on", "**The block", "blocked because"):
        idx = text.find(marker)
        if idx > -1:
            # The first couple of sentences, not 900 characters cut mid-word: the whole
            # document is one click away in the drawer.
            chunk = " ".join(text[idx:idx + 700].split())
            cut = chunk.find(". ", 180)
            return chunk[:cut + 1] if cut > -1 else chunk[:320] + "…"
    # Otherwise the start of # Result, which is where a role explains itself.
    for heading in ("# Result", "# Notes"):
        idx = text.find(heading)
        if idx > -1:
            chunk = text[idx + len(heading):idx + len(heading) + 600]
            return " ".join(chunk.split())
    return ""


def projects() -> list:
    """One row per project, with its task counts — "what is being worked on"."""
    out = []
    root = INSTANCE / "projects"
    if not root.is_dir():
        return out
    all_tasks = tasks()
    for path in sorted(root.glob("*/project.md")):
        fields = frontmatter(path)
        slug = path.parent.name
        mine = [t for t in all_tasks if t["project"] == slug]
        epic = fields.get("jira_epic", "")
        counts: dict = {}
        for t in mine:
            counts[t["status"]] = counts.get(t["status"], 0) + 1
        out.append({
            "slug": slug,
            # The page needs something to address this document with; the tasks carry a path
            # for the same reason.
            "path": str(path.relative_to(INSTANCE)),
            "title": fields.get("title") or slug,
            "description": fields.get("description", ""),
            "status": fields.get("status", ""),
            "repo": fields.get("target_repo", ""),
            "jira_epic": epic,
            "tasks": len(mine),
            "counts": counts,
            "waiting": sum(1 for t in mine if t["unanswered"]),
            "prs": [pr for t in mine for pr in t["prs"]],
        })
    return out


def logs() -> list:
    """Recent box logs, whether or not the box is still running — the page had no way to
    read a finished box's output, which is when you most want it."""
    out, seen = [], set()
    candidates = list((STATE / "logs").glob("claude-box-*.log"))
    candidates += list((HARNESS_STATE / "ticks").glob("*/logs/*.log"))
    for path in sorted(candidates, key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)[:40]:
        if path.name in seen:
            continue
        seen.add(path.name)
        try:
            stat = path.stat()
        except OSError:
            continue
        out.append({
            "box": path.stem,
            "when": stat.st_mtime,
            "size": stat.st_size,
        })
    return out


def pending() -> list:
    out = []
    for path in sorted((INSTANCE / ".harness" / "pending").glob("*.md")):
        fields = frontmatter(path)
        body = read_text(path, 4000)
        body = body.split("---", 2)[-1].strip() if body.startswith("---") else body.strip()
        full = redact(body)
        out.append({
            "file": path.name,
            "path": str(path.relative_to(INSTANCE)),
            "tier": fields.get("tier", ""),
            "repo": fields.get("repo", ""),
            "evidence": fields.get("evidence", ""),
            "preview": full[:400] + ("…" if len(full) > 400 else ""),
            "body": full[:20000],          # the whole proposal, for the reading view
        })
    return out


def rejected() -> list:
    out = []
    for path in sorted((INSTANCE / ".harness" / "intents" / "rejected").glob("*.json"))[-20:]:
        try:
            data = json.loads(read_text(path))
            if not isinstance(data, dict):
                raise ValueError("not an object")
        except Exception:
            data = {"raw": read_text(path, 500)}
        out.append({
            "file": path.name,
            "role": data.get("role", ""),
            "task": data.get("task", ""),
            "reason": data.get("rejected_reason", ""),
        })
    return out


def autonomy() -> str:
    """The mode the host is acting under. Shown prominently because it decides what
    happens to your repos while nobody is watching the page."""
    path = HARNESS_STATE / "autonomy"
    mode = read_text(path).strip() if path.exists() else ""
    return mode if mode in ("promote", "full") else "gated"


def lock_state() -> dict:
    owner = HARNESS_STATE / "lock" / "owner"
    if not owner.exists():
        return {"held": False}
    parts = read_text(owner).split()
    pid = int(parts[0]) if parts and parts[0].isdigit() else 0
    since = float(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
    alive = False
    if pid:
        try:
            os.kill(pid, 0)
            alive = True
        except OSError:
            alive = False
    return {"held": True, "pid": pid, "since": since, "alive": alive}


def cap(names: list) -> dict:
    declared = 5
    try:
        config = json.loads(read_text(INSTANCE / "instance.config.json"))
        declared = int(config.get("maxAgentsInFlight", 5))
    except Exception:
        pass
    inflight = 0
    inflight_dir = HARNESS_STATE / "inflight"
    if inflight_dir.is_dir():
        for marker in inflight_dir.iterdir():
            if marker.is_file() and read_text(marker).strip() in names:
                inflight += 1
    return {"declared": declared, "inflight": inflight}


def state() -> dict:
    """Assembled section by section. A failure in one section used to raise, return a 500,
    and leave the page saying "runner unreachable" with no clue which part broke — so each
    section is isolated and its error is reported in the payload instead."""
    # `claude-box ps` shells out to the engine, so call it once per request and share it.
    names = running_boxes()
    out: dict = {
        "api": API_VERSION,
        "actions": {"enabled": ACTIONS_ENABLED, "supported": SUPPORTED_ACTIONS},
        "instance": str(INSTANCE),
        "slug": SLUG,
        "root": str(ROOT),
        "now": time.time(),
        "errors": [],
    }
    task_list = None
    box_list = None
    sections = {
        "lock": lock_state,
        "autonomy": autonomy,
        "cap": lambda: cap(names),
        "boxes": lambda: [box_info(name) for name in names],
        "objectives": objectives,
        "knowledge": knowledge,
        "ticks": ticks,
        "runs": runs,
        "spend": spend,
        "tasks": tasks,
        "projects": projects,
        "logs": logs,
        "pending": pending,
        "rejected": rejected,
        "timeline": timeline,
        "role_stats": role_stats,
        "roles": roles,
        "memory": memory,
        "jira": jira_config,
    }
    defaults = {"lock": {"held": False}, "autonomy": "gated", "cap": {"declared": 0, "inflight": 0},
                "spend": {"today": 0, "total": 0, "boxes": 0},
                "memory": {"global": [], "repo": [], "kb": {"index": "", "docs": []}},
                "objectives": [], "knowledge": {"kinds": {}, "loose": [], "total": 0}}
    for key, fn in sections.items():
        try:
            out[key] = fn()
        except Exception as exc:
            out[key] = defaults.get(key, [])
            out["errors"].append("%s: %s: %s" % (key, type(exc).__name__, exc))
            traceback.print_exc()
    try:
        out["prs"] = pull_requests(out.get("tasks") or [])
    except Exception as exc:
        out["prs"] = []
        out["errors"].append("prs: %s: %s" % (type(exc).__name__, exc))
    try:
        out["attention"] = attention(out.get("tasks") or [], out.get("boxes") or [])
    except Exception as exc:
        out["attention"] = []
        out["errors"].append("attention: %s: %s" % (type(exc).__name__, exc))
    return out


# A page that can ACT needs more than "it is only on localhost": any website you visit can
# POST to 127.0.0.1 without a CORS preflight. So every write carries a token minted at
# startup and handed to the page in its HTML — a third-party page cannot read it.
API_VERSION = 18          # bump when the payload the page depends on changes
ACTION_TOKEN = os.urandom(16).hex()
ACTIONS_ENABLED = os.environ.get("CB_UI_ACTIONS", "0") == "1"
# The page is read from disk on every request, but this module is not: a server started
# before an action existed will happily serve a page offering that button and then answer
# "unknown action". So the server advertises what it actually supports, and the page only
# renders buttons it can honour.
SUPPORTED_ACTIONS = ["stop", "tick", "promote", "done", "memory-accept", "memory-drop",
                     "delete-task", "delete-project", "delete-objective", "purge-history"]


def run_diff(task_id: str, repo: str = "") -> str:
    """The real diff, read on the host. This used to run git inside a box because the
    worktree's `.git` file is unusable here — pointing --git-dir at the repo's
    worktrees/<id> directory works instead, so a diff is now instant and free."""
    found = worktree_gitdir(task_id, repo)
    if not found:
        return "no worktree for %s under %s/_wt" % (task_id, ROOT)
    parts = [
        "# repo: %s   worktree: %s" % (found["repo"], found["work"]),
        "",
        "# git status",
        git_in_worktree(found, ["status", "--short"]).rstrip() or "(clean)",
        "",
        "# commits not yet pushed",
        (git_in_worktree(found, ["--no-pager", "log", "--oneline", "@{upstream}..HEAD"], quiet=True).rstrip()
         or "(branch not pushed yet)"),
        "",
        "# diff --stat vs HEAD",
        git_in_worktree(found, ["--no-pager", "diff", "--stat", "HEAD"]).rstrip() or "(no unstaged changes)",
        "",
        "# diff",
        git_in_worktree(found, ["--no-pager", "diff", "HEAD"], timeout=60)[:200000].rstrip() or "(none)",
    ]
    return redact("\n".join(parts))


def _rel_ok(arg: str) -> bool:
    """No empty, `.` or `..` segment: the action regexes allow those characters, so this is
    what keeps `projects/../x` and a bare `..` inside the panel."""
    return all(seg not in ("", ".", "..") for seg in arg.split("/"))


def do_action(name: str, arg: str) -> dict:
    """The actions worth having from a page. Each is a normal harness command — the page is
    a launcher, not a second implementation."""
    if not ACTIONS_ENABLED:
        return {"ok": False, "output": "actions are off — start with: claude-box harness ui --actions"}
    cmd = None
    if name == "stop" and re.match(r"^claude-box-[A-Za-z0-9._-]{1,80}$", arg):
        cmd = [RUNNER, "stop", arg]
    elif name == "tick":
        cmd = [RUNNER, "harness", "tick", str(INSTANCE)]
    elif name in ("memory-accept", "memory-drop") and re.match(r"^[A-Za-z0-9._-]{1,120}\.md$", arg) and _rel_ok(arg):
        # File NAME only: the runner refuses anything with a path separator, and so does this.
        cmd = [RUNNER, "harness", "memory", str(INSTANCE),
               "--accept" if name == "memory-accept" else "--drop", arg]
    elif name == "delete-task" and re.match(r"^projects/[A-Za-z0-9._-]{1,80}/tasks/[A-Za-z0-9._-]{1,80}\.md$", arg) and _rel_ok(arg):
        # -y because there is no tty here; the page does the confirming. The runner still
        # refuses while any box is running, and still moves the document to trash.
        cmd = [RUNNER, "harness", "delete", str(INSTANCE), "--task", arg, "-y"]
    elif name == "delete-project" and re.match(r"^[A-Za-z0-9._-]{1,80}$", arg) and _rel_ok(arg):
        cmd = [RUNNER, "harness", "delete", str(INSTANCE), "--project", arg, "-y"]
    elif name == "delete-objective" and re.match(r"^[A-Za-z0-9._-]{1,120}\.md$", arg) and _rel_ok(arg):
        cmd = [RUNNER, "harness", "delete", str(INSTANCE), "--objective", arg, "-y"]
    elif name == "purge-history":
        # Activity, runs and logs are all the same thing on disk: diagnostics under the
        # state directory. One command clears them; the panel's documents are not touched.
        cmd = [RUNNER, "harness", "purge", str(INSTANCE), "--all", "-y"]
    elif name == "done" and re.match(r"^[A-Za-z0-9._/-]{1,200}\.md$", arg):
        # Shelled out rather than written here like `promote` below: marking a task done
        # means checking every PR on it against gh first, and that gate belongs in one
        # place. The runner refuses a path outside the panel itself, and so does the regex.
        cmd = [RUNNER, "harness", "done", arg, str(INSTANCE)]
    elif name == "promote" and re.match(r"^[A-Za-z0-9._/-]{1,200}\.md$", arg):
        target = (INSTANCE / arg).resolve()
        # A prefix test let /x/panel-old/... pass for a panel at /x/panel.
        if not target.is_relative_to(INSTANCE.resolve()) or not target.is_file():
            return {"ok": False, "output": "not a task in this panel"}
        text = target.read_text()
        if "status: draft" not in text:
            return {"ok": False, "output": "not a draft"}
        target.write_text(text.replace("status: draft", "status: ready", 1))
        return {"ok": True, "output": "promoted %s" % arg}
    if not cmd:
        if name not in SUPPORTED_ACTIONS:
            return {"ok": False, "output":
                    "this server does not support the action %r — it supports %s. If the page "
                    "offered it, the server is older than the page: restart it with "
                    "`claude-box harness ui --actions`." % (name, ", ".join(SUPPORTED_ACTIONS))}
        return {"ok": False, "output": "the argument %r is not valid for %r" % (arg, name)}
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        return {"ok": done.returncode == 0, "output": redact((done.stdout + done.stderr)[-4000:])}
    except Exception as exc:
        return {"ok": False, "output": "%s: %s" % (type(exc).__name__, exc)}


def task_by_key(key: str) -> dict:
    """Look a task up by its PATH (unique) or, for older links, its id (not unique — first
    match wins, which is exactly the ambiguity the path avoids)."""
    for task in tasks():
        if task["path"] == key.lstrip("/"):
            return task
    for task in tasks():
        if task["id"] == key or Path(task["path"]).stem == key:
            return task
    return {}


def resolve_worktree(key: str):
    """The worktree for a task, trying the unique name before the legacy one."""
    task = task_by_key(key)
    repo = task.get("repo") or ""
    for candidate in (worktree_ids(task.get("path", "")) or [key]):
        found = worktree_gitdir(candidate, repo)
        if found:
            return found, candidate
    return None, (worktree_ids(task.get("path", "")) or [key])[0]


class Handler(BaseHTTPRequestHandler):
    server_version = "claude-box-harness-ui"

    def log_message(self, *args):        # keep the terminal for the harness's own output
        pass

    def log_error(self, fmt, *args):     # errors DO belong on the terminal
        sys.stderr.write("claude-box ui: " + (fmt % args) + "\n")

    def _send(self, code, body, content_type):
        payload = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    # Bound to 127.0.0.1, but a browser sends requests here from a page on any origin whose
    # DNS was rebound to 127.0.0.1 — and that page is then same-origin, reads the action token
    # out of GET / and POSTs with it. The Host header is the one thing it cannot forge.
    def _host_ok(self) -> bool:
        host = (self.headers.get("Host") or "").strip().lower()
        return host in ("127.0.0.1:%d" % PORT, "localhost:%d" % PORT, "[::1]:%d" % PORT)

    def do_GET(self):
        if not self._host_ok():
            self._send(403, "bad host", "text/plain")
            return
        try:
            self._get()
        except Exception as exc:
            # A dropped connection tells the page nothing; a 500 tells it what broke.
            traceback.print_exc()
            self._send(500, json.dumps({"errors": ["%s: %s" % (type(exc).__name__, exc)]}),
                       "application/json")

    def _get(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            page = read_text(HERE / "index.html", 1_000_000)
            page = page.replace("__ACTION_TOKEN__", ACTION_TOKEN if ACTIONS_ENABLED else "")
            self._send(200, page, "text/html; charset=utf-8")
        elif parsed.path == "/api/state":
            try:
                self._send(200, json.dumps(state()), "application/json")
            except Exception as exc:
                traceback.print_exc()
                self._send(500, json.dumps({"errors": ["state: %s: %s" % (type(exc).__name__, exc)]}),
                           "application/json")
        elif parsed.path == "/api/diff":
            params = parse_qs(parsed.query)
            task = (params.get("task") or [""])[0]
            found, name = resolve_worktree(task)
            self._send(200, run_diff(name, (task_by_key(task).get("repo") or "")),
                       "text/plain; charset=utf-8")
        elif parsed.path == "/api/progress":
            params = parse_qs(parsed.query)
            task = (params.get("task") or [""])[0]
            if not re.match(r"^[A-Za-z0-9._/-]{1,200}$", task):
                self._send(400, json.dumps({"error": "bad task id"}), "application/json")
                return
            self._send(200, json.dumps(worktree_progress_for(task)), "application/json")
        elif parsed.path == "/api/log":
            params = parse_qs(parsed.query)
            name = (params.get("box") or [""])[0]
            if not BOX_NAME.match(name):
                self._send(400, "bad box name", "text/plain")
                return
            try:
                lines = max(1, min(int((params.get("tail") or ["400"])[0]), 20000))
            except ValueError:
                lines = 400
            candidates = [STATE / "logs" / f"{name}.log"]
            candidates += list((HARNESS_STATE / "ticks").glob(f"*/logs/{name}.log"))
            raw = "raw" in params
            for path in candidates:
                if path.exists():
                    if raw:
                        body = "\n".join(read_text(path).splitlines()[-lines:])
                    else:
                        body = render_log(path, tail=lines)
                    self._send(200, redact(body), "text/plain; charset=utf-8")
                    return
            self._send(404, "no log for that box yet", "text/plain")
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self):
        if not self._host_ok():
            self._send(403, json.dumps({"ok": False, "output": "bad host"}), "application/json")
            return
        parsed = urlparse(self.path)
        if parsed.path != "/api/action":
            self._send(404, "not found", "text/plain")
            return
        if not ACTIONS_ENABLED:
            self._send(403, json.dumps({"ok": False, "output": "actions are off"}), "application/json")
            return
        if self.headers.get("X-CB-Token") != ACTION_TOKEN:
            # A third-party page can POST here but cannot read the token out of our HTML.
            self._send(403, json.dumps({"ok": False, "output": "bad token"}), "application/json")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or "{}")
            if not isinstance(body, dict):
                raise ValueError("not an object")
        except Exception:
            self._send(400, json.dumps({"ok": False, "output": "bad body"}), "application/json")
            return
        result = do_action(str(body.get("action", "")), str(body.get("arg", "")))
        self._send(200, json.dumps(result), "application/json")


if __name__ == "__main__":
    # 127.0.0.1 only: this exposes task titles, repo names and agent logs, none of
    # which should be reachable from the network.
    if ACTIONS_ENABLED:
        sys.stderr.write("claude-box ui: ACTIONS ENABLED — this page can stop boxes, promote "
                         "tasks and run a tick. Token minted per start.\n")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
