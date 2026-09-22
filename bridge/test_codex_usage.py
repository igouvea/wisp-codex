"""Dependency-free regression tests for the local Codex usage reader."""

from __future__ import annotations

import json
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import codex_usage
import server


FAILURES = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(("  ok    " if ok else "  FAIL  ") + name
          + (f"  — {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


def event(when: datetime, payload: dict, kind: str = "event_msg") -> str:
    return json.dumps({"timestamp": when.isoformat(), "type": kind, "payload": payload})


now = datetime.now(timezone.utc)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    sessions = root / "sessions"
    archived = root / "archived_sessions"
    sessions.mkdir()
    archived.mkdir()
    codex_usage.SESSION_DIRS = (sessions, archived)
    codex_usage._last_limits[0] = None

    primary_reset = int((now + timedelta(hours=3)).timestamp())
    weekly_reset = int((now + timedelta(days=4)).timestamp())
    rate_limits = {
        "limit_id": "codex",
        "primary": {"used_percent": 21.0, "window_minutes": 300,
                    "resets_at": primary_reset},
        "secondary": {"used_percent": 64.0, "window_minutes": 10080,
                      "resets_at": weekly_reset},
    }
    current = [
        event(now - timedelta(minutes=4),
              {"id": "one", "cwd": "/work/alpha"}, "session_meta"),
        event(now - timedelta(minutes=4), {"model": "gpt-test"}, "turn_context"),
        event(now - timedelta(minutes=3), {
            "type": "token_count",
            "info": {"last_token_usage": {
                "input_tokens": 100, "cached_input_tokens": 60,
                "cache_write_input_tokens": 0, "output_tokens": 20,
            }},
            "rate_limits": rate_limits,
        }),
        # An incomplete line is normal while Codex is writing and must not make
        # the entire file unreadable.
        "{unfinished",
        event(now - timedelta(minutes=1), {
            "type": "token_count",
            "info": {"last_token_usage": {
                "input_tokens": 200, "cached_input_tokens": 90,
                "cache_write_input_tokens": 10, "output_tokens": 30,
            }},
            "rate_limits": rate_limits,
        }),
    ]
    (sessions / "current.jsonl").write_text("\n".join(current) + "\n")

    archived_events = [
        event(now - timedelta(hours=2),
              {"id": "two", "cwd": "/work/beta"}, "session_meta"),
        event(now - timedelta(hours=2), {"model": "gpt-archived"}, "turn_context"),
        event(now - timedelta(hours=1), {
            "type": "token_count",
            "info": {"last_token_usage": {
                "input_tokens": 50, "cached_input_tokens": 20,
                "cache_write_input_tokens": 0, "output_tokens": 7,
            }},
        }),
    ]
    (archived / "done.jsonl").write_text("\n".join(archived_events) + "\n")

    result = codex_usage.collect(since_days=1)
    total = result["total"]
    check("sums per-request deltas from active and archived sessions",
          total["requests"] == 3 and total["input"] == 350
          and total["output"] == 57 and total["cache_read"] == 170
          and total["cache_write"] == 10,
          f"got {total}")
    check("keeps model attribution across turn_context records",
          result["by_model"]["gpt-test"]["requests"] == 2
          and result["by_model"]["gpt-archived"]["requests"] == 1,
          f"got {result['by_model']}")

    bars = result["limits"]["bars"]
    check("normalizes both Codex rate-limit windows",
          [bar["label"] for bar in bars] == ["Session 5h", "Weekly"]
          and [bar["pct"] for bar in bars] == [21, 64],
          f"got {bars}")
    check("marks Codex limits as local and provider-specific",
          all(bar["provider"] == "codex" and bar["source"] == "local"
              for bar in bars))
    check("computes reset text and a truthful pace marker",
          bars[0]["resets_in"] == "3h"
          and bars[0]["elapsed_pct"] is not None,
          f"got reset={bars[0]['resets_in']} pace={bars[0]['elapsed_pct']}")

    five = [
        {"provider": "claude", "kind": "session", "label": "c5"},
        {"provider": "claude", "kind": "weekly_all", "label": "cw"},
        {"provider": "claude", "kind": "weekly_scoped", "label": "cm"},
        {"provider": "codex", "kind": "codex_primary", "label": "o5"},
        {"provider": "codex", "kind": "codex_secondary", "label": "ow"},
    ]
    board = server.State._board_limits(five)
    check("four board cards retain both providers' account windows",
          len(board) == 4
          and {bar["label"] for bar in board} == {"c5", "cw", "o5", "ow"},
          f"got {[bar['label'] for bar in board]}")

print()
if FAILURES:
    print(f"FAILED: {len(FAILURES)} — {', '.join(FAILURES)}")
    raise SystemExit(1)
print("all passed")
