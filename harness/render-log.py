#!/usr/bin/env python3
"""Turn a box's stream-json log into something a human reads.

Headless boxes run with --output-format stream-json --verbose, because the default text
output prints NOTHING until the run finishes — a seven-minute box looked hung and its log
held one line. The stream is the source of truth on disk; this renders it.

Usage: render-log.py <file> [--tail N] [--last]
  --last     one line describing the newest activity (for the dashboard card)
  --summary  JSON facts about the run: status, cost, turns, duration, tool calls
"""

import json
import sys


def summarise_input(name, data):
    """A tool call's most identifying argument, short."""
    if not isinstance(data, dict):
        return ""
    for key in ("command", "file_path", "path", "pattern", "url", "description", "prompt"):
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            one = " ".join(value.split())
            return one[:110] + ("…" if len(one) > 110 else "")
    return ""


def render(lines):
    out, tokens = [], None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if not line.startswith("{"):
            out.append(("raw", line[:200]))
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "system":
            if "estimated_tokens" in event:
                tokens = event["estimated_tokens"]          # progress ticks, not log lines
            elif event.get("subtype") == "init" or "agents" in event:
                out.append(("start", "session started"))
        elif kind == "assistant":
            for block in event.get("message", {}).get("content", []):
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "tool_use":
                    out.append(("tool", "%s  %s" % (block.get("name", "tool"),
                                                    summarise_input(block.get("name"), block.get("input")))))
                elif btype == "text":
                    text = " ".join((block.get("text") or "").split())
                    if text:
                        out.append(("say", text[:400]))
                elif btype == "thinking":
                    out.append(("think", "thinking…"))
        elif kind == "user":
            for block in event.get("message", {}).get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    body = block.get("content")
                    if isinstance(body, list):
                        body = " ".join(b.get("text", "") for b in body if isinstance(b, dict))
                    body = " ".join(str(body or "").split())
                    bad = block.get("is_error")
                    out.append(("err" if bad else "ok", body[:200] or ("error" if bad else "ok")))
        elif kind == "result":
            out.append(("done", "finished: %s in %.1fs, %s turn(s)%s" % (
                event.get("subtype", "?"),
                (event.get("duration_ms") or 0) / 1000.0,
                event.get("num_turns", "?"),
                (", $%.4f" % event["total_cost_usd"]) if event.get("total_cost_usd") else "")))
        elif kind == "rate_limit_event":
            info = event.get("rate_limit_info") or {}
            if info.get("status") not in (None, "allowed", "ok"):
                out.append(("err", "rate limit: %s" % info.get("status")))
    return out, tokens


MARK = {"start": "·", "tool": "→", "ok": "  ", "err": "  !", "say": "»", "think": " ",
        "done": "✓", "raw": " "}


def summary(lines):
    """Machine-readable facts about a box's run, from its final `result` event: what it
    cost, how long it took, how many turns. This is where the dashboard's spend figures
    come from — there is no other honest source."""
    out = {"status": "running", "cost_usd": None, "turns": None, "duration_s": None,
           "tokens": None, "tools": 0, "errors": 0}
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "system" and "estimated_tokens" in event:
            out["tokens"] = event["estimated_tokens"]
        elif kind == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    out["tools"] += 1
        elif kind == "user":
            for block in event.get("message", {}).get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("is_error"):
                    out["errors"] += 1
        elif kind == "result":
            out["status"] = event.get("subtype") or "done"
            out["cost_usd"] = event.get("total_cost_usd")
            out["turns"] = event.get("num_turns")
            out["duration_s"] = (event.get("duration_ms") or 0) / 1000.0
            usage = event.get("usage") or {}
            if usage:
                out["input_tokens"] = usage.get("input_tokens")
                out["output_tokens"] = usage.get("output_tokens")
    return out


def main():
    args = sys.argv[1:]
    if not args:
        print("usage: render-log.py <file> [--tail N] [--last]", file=sys.stderr)
        return 2
    path, tail, last_only, as_summary = args[0], 0, False, False
    for i, a in enumerate(args[1:]):
        if a == "--summary":
            as_summary = True
        elif a == "--last":
            last_only = True
        elif a == "--tail" and i + 2 < len(args) + 1:
            try:
                tail = int(args[i + 2])
            except (IndexError, ValueError):
                pass
    try:
        with open(path, errors="replace") as handle:
            lines = handle.readlines()
    except OSError as exc:
        print("cannot read %s: %s" % (path, exc), file=sys.stderr)
        return 1

    if as_summary:
        print(json.dumps(summary(lines)))
        return 0

    events, tokens = render(lines)
    if last_only:
        # The newest thing worth reporting, skipping bookkeeping.
        for kind, text in reversed(events):
            if kind in ("tool", "say", "done", "err"):
                print("%s %s%s" % (MARK[kind], text[:120],
                                   ("  ~%s tok" % tokens) if tokens else ""))
                return 0
        print("starting…%s" % (("  ~%s tok" % tokens) if tokens else ""))
        return 0

    if tail:
        events = events[-tail:]
    for kind, text in events:
        print("%-3s %s" % (MARK[kind], text))
    if tokens:
        print("\n(~%s tokens of context used)" % tokens)
    return 0


if __name__ == "__main__":
    sys.exit(main())
