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
import re
import subprocess
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
    """Parse the leading --- block of a markdown doc. Deliberately minimal: the
    fields the board needs are flat scalars, and a YAML dependency is not worth it."""
    fields, title = {}, ""
    try:
        with path.open("r", errors="replace") as handle:
            first = handle.readline()
            if first.strip() == "---":
                for line in handle:
                    if line.strip() == "---":
                        break
                    if ":" in line:
                        key, _, value = line.partition(":")
                        fields[key.strip()] = value.strip()
            for line in handle:
                if line.startswith("# "):
                    title = line[2:].strip()
                    break
    except OSError:
        pass
    fields["title"] = title
    return fields


def running_boxes() -> list:
    try:
        out = subprocess.run(
            [RUNNER, "ps"], capture_output=True, text=True, timeout=20,
            env={**os.environ, "CLAUDE_BOX_QUIET": "1"},
        ).stdout
    except Exception:
        return []
    names = []
    for line in out.splitlines():
        candidate = line.split()[0] if line.split() else ""
        if BOX_NAME.match(candidate):
            names.append(candidate)
    return names


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
        if candidate.exists():
            stat = candidate.stat()
            # Birth time where the filesystem has it (APFS does), first-write otherwise.
            started = getattr(stat, "st_birthtime", stat.st_mtime)
            log = candidate
            break
    return {
        "name": name,
        "role": role or "?",
        "task": task,
        "started": started,
        "elapsed": int(time.time() - started) if started else None,
        "log": str(log) if log.exists() else "",
        "harness": name.startswith(prefix),
    }


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


def tasks() -> list:
    out = []
    projects = INSTANCE / "projects"
    if not projects.is_dir():
        return out
    for path in sorted(projects.rglob("*.md")):
        fields = frontmatter(path)
        status = fields.get("status")
        if not status:
            continue
        out.append({
            "path": str(path.relative_to(INSTANCE)),
            "id": fields.get("id", path.stem),
            "title": fields.get("title") or path.stem,
            "status": status,
            "repo": fields.get("target_repo", ""),
            "assignee": fields.get("assignee", ""),
            "pr": fields.get("pr", ""),
        })
    return out


def pending() -> list:
    out = []
    for path in sorted((INSTANCE / ".harness" / "pending").glob("*.md")):
        fields = frontmatter(path)
        body = read_text(path, 4000)
        body = body.split("---", 2)[-1].strip() if body.startswith("---") else body.strip()
        out.append({
            "file": path.name,
            "tier": fields.get("tier", ""),
            "repo": fields.get("repo", ""),
            "evidence": fields.get("evidence", ""),
            "body": redact(body[:400]),
        })
    return out


def rejected() -> list:
    out = []
    for path in sorted((INSTANCE / ".harness" / "intents" / "rejected").glob("*.json"))[-20:]:
        try:
            data = json.loads(read_text(path))
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
    # `claude-box ps` shells out to the engine, so call it once per request and share
    # the result — the page polls every few seconds.
    names = running_boxes()
    boxes = [box_info(name) for name in names]
    return {
        "instance": str(INSTANCE),
        "slug": SLUG,
        "root": str(ROOT),
        "now": time.time(),
        "lock": lock_state(),
        "autonomy": autonomy(),
        "cap": cap(names),
        "boxes": boxes,
        "ticks": ticks(),
        "tasks": tasks(),
        "pending": pending(),
        "rejected": rejected(),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "claude-box-harness-ui"

    def log_message(self, *args):        # keep the terminal for the harness's own output
        pass

    def _send(self, code, body, content_type):
        payload = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            self._send(200, read_text(HERE / "index.html", 1_000_000), "text/html; charset=utf-8")
        elif parsed.path == "/api/state":
            self._send(200, json.dumps(state()), "application/json")
        elif parsed.path == "/api/log":
            params = parse_qs(parsed.query)
            name = (params.get("box") or [""])[0]
            if not BOX_NAME.match(name):
                self._send(400, "bad box name", "text/plain")
                return
            lines = int((params.get("tail") or ["400"])[0])
            candidates = [STATE / "logs" / f"{name}.log"]
            candidates += list((HARNESS_STATE / "ticks").glob(f"*/logs/{name}.log"))
            for path in candidates:
                if path.exists():
                    tail = read_text(path).splitlines()[-lines:]
                    self._send(200, redact("\n".join(tail)), "text/plain; charset=utf-8")
                    return
            self._send(404, "no log for that box yet", "text/plain")
        else:
            self._send(404, "not found", "text/plain")


if __name__ == "__main__":
    # 127.0.0.1 only: this exposes task titles, repo names and agent logs, none of
    # which should be reachable from the network.
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
