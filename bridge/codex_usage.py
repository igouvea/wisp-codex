"""
Reads Codex token usage and rate-limit snapshots from local session logs.

Codex records both pieces in ~/.codex/sessions/**/*.jsonl (and moves finished
sessions to ~/.codex/archived_sessions).  A ``token_count`` event carries the
tokens spent by the last model request plus the account's current rate-limit
windows.  Reading that event means Wisp needs neither an OpenAI credential nor
an outbound request.

The percentages are server-provided values.  We do not derive a subscription
percentage from token counts: the denominator and model weights are not public.
"""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path


SESSION_DIRS = (
    Path.home() / ".codex" / "sessions",
    Path.home() / ".codex" / "archived_sessions",
)

# The last valid rate-limit event survives an idle refresh.  Without this, a
# transient partial final line while Codex is appending could make the bars
# disappear for a minute.
_last_limits = [None]  # [(observed_at, raw)]


def _blank() -> dict:
    return {
        "input": 0, "output": 0, "cache_read": 0, "cache_write": 0,
        "cost": 0.0, "requests": 0,
    }


def _when(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _fmt_reset(reset: datetime | None, now: datetime) -> str:
    if reset is None:
        return ""
    secs = (reset - now).total_seconds()
    if secs <= 0:
        return "now"
    if secs < 3600:
        return f"{secs / 60:.0f}min"
    if secs < 86400:
        return f"{secs / 3600:.0f}h"
    return f"{secs / 86400:.0f}d"


def _window_label(minutes: int) -> str:
    if minutes == 5 * 60:
        return "Session 5h"
    if minutes == 7 * 24 * 60:
        return "Weekly"
    if minutes and minutes % (24 * 60) == 0:
        return f"{minutes // (24 * 60)} days"
    if minutes and minutes % 60 == 0:
        return f"{minutes // 60} hours"
    return f"{minutes} min" if minutes else "Usage"


def _severity(pct: int) -> str:
    if pct >= 90:
        return "critical"
    if pct >= 70:
        return "warning"
    return "normal"


def normalize(raw, observed_at: datetime, now: datetime | None = None) -> dict:
    """Turns a Codex ``rate_limits`` object into Wisp limit bars."""
    now = now or datetime.now(timezone.utc)
    if not isinstance(raw, dict):
        return {"ok": False, "reason": "no Codex rate-limit snapshot"}

    parsed = []
    for slot in ("primary", "secondary"):
        item = raw.get(slot)
        if not isinstance(item, dict) or item.get("used_percent") is None:
            continue
        try:
            pct = max(0, min(100, int(round(float(item["used_percent"])))))
            minutes = max(0, int(item.get("window_minutes") or 0))
        except (TypeError, ValueError):
            continue

        try:
            reset = datetime.fromtimestamp(float(item["resets_at"]), timezone.utc)
        except (KeyError, TypeError, ValueError, OSError):
            reset = None

        expired = reset is not None and reset <= now
        elapsed = None
        window_s = minutes * 60
        if reset is not None and window_s > 0 and not expired:
            remaining = (reset - observed_at).total_seconds()
            if 0 < remaining <= window_s:
                elapsed = int(round((window_s - remaining) / window_s * 100))

        parsed.append({
            "kind": f"codex_{slot}",
            "label": _window_label(minutes),
            "board_label": "Codex " + (
                "5h" if minutes == 5 * 60 else
                "week" if minutes == 7 * 24 * 60 else
                _window_label(minutes).lower()
            ),
            "pct": pct,
            "resets_in": _fmt_reset(reset, now),
            "elapsed_pct": elapsed,
            "expired": expired,
            "severity": _severity(pct),
            # Every returned Codex window constrains the account.  Unlike
            # Anthropic's payload there is no is_active discriminator.
            "active": True,
            "provider": "codex",
            "source": "local",
        })

    if not parsed:
        return {"ok": False, "reason": "no Codex windows in the snapshot"}

    age_s = int(max(0, (now - observed_at).total_seconds()))
    for bar in parsed:
        bar["age_s"] = age_s
    peak = max(parsed, key=lambda bar: bar["pct"])
    return {
        "ok": True,
        "age_s": age_s,
        "source": "local",
        "bars": parsed,
        "peak": peak["pct"],
        "peak_severity": peak["severity"],
    }


def _paths(cutoff: datetime) -> tuple:
    recent = []
    all_paths = []
    seen = set()
    for root in SESSION_DIRS:
        if not root.is_dir():
            continue
        for path in root.rglob("*.jsonl"):
            # A session should be in one directory or the other, never both,
            # but resolving here prevents an accidental symlink from charging
            # every request twice.
            try:
                identity = path.resolve()
                mtime = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
            except OSError:
                continue
            if identity in seen:
                continue
            seen.add(identity)
            all_paths.append(path)
            if mtime >= cutoff:
                recent.append(path)
    return recent, all_paths


def _latest_from(paths: list) -> tuple | None:
    """Finds the newest rate snapshot in paths, reading valid JSON lines only."""
    latest = None
    for path in paths:
        try:
            with path.open(errors="replace") as fh:
                for line in fh:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    payload = event.get("payload") or {}
                    raw = payload.get("rate_limits")
                    when = _when(event.get("timestamp"))
                    if (event.get("type") == "event_msg"
                            and payload.get("type") == "token_count"
                            and isinstance(raw, dict) and when is not None
                            and (latest is None or when > latest[0])):
                        latest = (when, raw)
        except OSError:
            continue
    return latest


def collect(since_days: int = 1) -> dict:
    """Aggregates Codex request deltas and returns the freshest limit snapshot."""
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=since_days)
    paths, all_paths = _paths(cutoff)
    if not all_paths:
        return {"error": "could not find Codex session transcripts"}

    by_model = defaultdict(_blank)
    by_day = defaultdict(_blank)
    by_project = defaultdict(_blank)
    newest = None

    for path in paths:
        model = "unknown"
        project = "unknown"
        try:
            with path.open(errors="replace") as fh:
                for line in fh:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        # Codex may be halfway through appending the final line.
                        continue

                    payload = event.get("payload") or {}
                    if event.get("type") == "session_meta":
                        cwd = payload.get("cwd")
                        if isinstance(cwd, str) and cwd:
                            project = Path(cwd).name or cwd
                        continue
                    if event.get("type") == "turn_context":
                        if isinstance(payload.get("model"), str):
                            model = payload["model"]
                        continue
                    if (event.get("type") != "event_msg"
                            or payload.get("type") != "token_count"):
                        continue

                    when = _when(event.get("timestamp"))
                    raw_limits = payload.get("rate_limits")
                    if (isinstance(raw_limits, dict) and when is not None
                            and (newest is None or when > newest[0])):
                        newest = (when, raw_limits)

                    usage = (payload.get("info") or {}).get("last_token_usage")
                    if when is None or when < cutoff or not isinstance(usage, dict):
                        continue

                    values = {
                        "input": int(usage.get("input_tokens") or 0),
                        "output": int(usage.get("output_tokens") or 0),
                        "cache_read": int(usage.get("cached_input_tokens") or 0),
                        "cache_write": int(usage.get("cache_write_input_tokens") or 0),
                        "requests": 1,
                    }
                    day = when.date().isoformat()
                    for bucket in (by_model[model], by_day[day], by_project[project]):
                        for key, value in values.items():
                            bucket[key] += value
        except OSError:
            continue

    if newest is not None:
        _last_limits[0] = newest
    elif _last_limits[0] is not None:
        newest = _last_limits[0]
    else:
        # Fresh bridge after a long Codex-idle period: inspect newest files until
        # one yields a snapshot.  This path is deliberately exceptional; the
        # normal one scans only files touched in the requested usage period.
        ordered = sorted(all_paths, key=lambda p: p.stat().st_mtime, reverse=True)
        for path in ordered:
            newest = _latest_from([path])
            if newest is not None:
                _last_limits[0] = newest
                break

    total = _blank()
    for bucket in by_model.values():
        for key in total:
            total[key] += bucket[key]

    result = {
        "total": total,
        "by_model": dict(by_model),
        "by_day": dict(by_day),
        "by_project": dict(by_project),
        "files_read": len(paths),
        "unique_requests": total["requests"],
    }
    if newest is not None:
        result["limits"] = normalize(newest[1], newest[0], now=now)
    return result


if __name__ == "__main__":
    result = collect()
    if "error" in result:
        raise SystemExit(result["error"])
    total = result["total"]
    print(f"Codex today: {total['requests']:,} requests, "
          f"{total['output']:,} output tokens, "
          f"{total['cache_read']:,} cached input tokens")
    limits = result.get("limits") or {}
    for bar in limits.get("bars", []):
        print(f"  {bar['label']}: {bar['pct']}% (resets in {bar['resets_in']})")
