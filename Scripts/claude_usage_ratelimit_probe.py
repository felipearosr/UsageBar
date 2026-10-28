#!/usr/bin/env python3
"""Find out what Anthropic keys the /api/oauth/usage rate limit on.

Run `watch` on every machine signed in to the same Claude account, then feed
the logs to `report`. Stdlib only, so it runs on any machine with python3.

  watch   Log UsageBar's shared-cache transitions (free: no requests), and
          with --probe-every N also send one usage request every N seconds.
  probe   Send one usage request now and log the result.
  report  Merge logs from several machines into one timeline and a verdict.

Logs go to ~/.cache/usagebar/ratelimit-probe/<host>.jsonl. Tokens are never
logged: a token is identified by the first 8 hex chars of
sha256("Bearer <token>"), the same key UsageBar's cache files use, and 200
bodies are never stored.
"""

import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc).timestamp()
CACHE = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
SHARED_DIR = os.path.join(CACHE, "usagebar", "claude-oauth")
LOG_DIR = os.path.join(CACHE, "usagebar", "ratelimit-probe")
HOST = socket.gethostname().split(".")[0]
KEPT_HEADERS = ("retry", "ratelimit", "rate-limit", "request-id", "cf-ray", "x-should-retry", "date")


def now_iso():
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def log(event):
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    event = {"ts": now_iso(), "host": HOST, **event}
    with open(os.path.join(LOG_DIR, HOST + ".jsonl"), "a") as fh:
        fh.write(json.dumps(event) + "\n")
    print(json.dumps(event), flush=True)


def public_ip():
    try:
        out = subprocess.run(["tailscale", "netcheck"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in out.splitlines():
        if "IPv4: yes," in line:
            return line.split("yes,")[1].strip().rsplit(":", 1)[0]
    return None


def read_token():
    path = os.path.expanduser("~/.claude/.credentials.json")
    oauth = json.load(open(path))["claudeAiOauth"]
    return oauth["accessToken"], oauth.get("expiresAt")


def token_key(token):
    return hashlib.sha256(("Bearer " + token).encode()).hexdigest()[:8]


def claude_version():
    try:
        out = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=10).stdout
        return out.split()[0]
    except (OSError, subprocess.TimeoutExpired, IndexError):
        return "2.1.0"


def probe(ip):
    token, expires_at = read_token()
    request = urllib.request.Request(USAGE_URL, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-cli/%s (external, cli)" % claude_version(),
    })
    started = time.monotonic()
    body = b""
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status, headers = response.status, response.headers
    except urllib.error.HTTPError as error:
        status, headers, body = error.code, error.headers, error.read()[:300]
    except OSError as error:
        log({"kind": "probe", "token": token_key(token), "ip": ip, "error": str(error)})
        return
    event = {
        "kind": "probe",
        "token": token_key(token),
        "token_expires": dt.datetime.fromtimestamp(expires_at / 1000).isoformat(timespec="minutes")
        if expires_at else None,
        "ip": ip,
        "status": status,
        "ms": int((time.monotonic() - started) * 1000),
        "headers": {k.lower(): v for k, v in headers.items() if any(s in k.lower() for s in KEPT_HEADERS)},
    }
    if status != 200:
        event["body"] = body.decode("utf-8", "replace")
    log(event)


def apple_time(value):
    if value is None:
        return None
    return dt.datetime.fromtimestamp(value + APPLE_EPOCH).astimezone().isoformat(timespec="seconds")


def snapshot_shared_cache():
    state = {}
    for path in glob.glob(os.path.join(SHARED_DIR, "*.json")):
        try:
            data = json.load(open(path))
        except (OSError, ValueError):
            continue
        state[os.path.basename(path)[:8]] = {
            "savedAt": apple_time(data.get("savedAt")),
            "blockedUntil": apple_time(data.get("blockedUntil")),
            "failures": data.get("failures", 0),
        }
    return state


def watch(args):
    ip = public_ip()
    log({"kind": "start", "ip": ip, "probe_every": args.probe_every,
         "shared_cache": os.path.isdir(SHARED_DIR)})
    previous = snapshot_shared_cache()
    next_probe = time.monotonic()
    while True:
        current = snapshot_shared_cache()
        for key, entry in current.items():
            before = previous.get(key)
            if entry == before:
                continue
            if before is None or entry["savedAt"] != before["savedAt"]:
                kind = "usagebar_ok"
            elif entry["failures"] > before["failures"]:
                kind = "usagebar_429"
            else:
                kind = "usagebar_change"
            log({"kind": kind, "token": key, "ip": ip, **entry})
        previous = current
        if args.probe_every and time.monotonic() >= next_probe:
            probe(ip)
            next_probe = time.monotonic() + args.probe_every
        time.sleep(args.poll)


def outcome(event):
    if event["kind"] == "probe":
        return "429" if event.get("status") == 429 else ("ok" if event.get("status") == 200 else None)
    return {"usagebar_ok": "ok", "usagebar_429": "429"}.get(event["kind"])


def report(args):
    events = []
    for path in args.logs:
        events += [json.loads(line) for line in open(path) if line.strip()]
    events.sort(key=lambda e: e["ts"])
    for e in events:
        result = outcome(e)
        if result is None and e["kind"] != "start":
            continue
        extra = e.get("headers", {}).get("retry-after") or e.get("blockedUntil") or ""
        print("%s  %-10s %-15s %-8s %-4s %s" % (
            e["ts"][5:19], e["host"], e.get("ip") or "", e.get("token", ""), result or e["kind"], extra))

    # Contrast pairs: a 429 and an ok within the window, differing in token/ip/host.
    window = dt.timedelta(seconds=args.window)
    graded = [(dt.datetime.fromisoformat(e["ts"]), e, outcome(e)) for e in events if outcome(e)]
    evidence = {"same_token_other_ip": [], "other_token_same_ip": [], "other_token_other_ip": []}
    for t429, e429, r in graded:
        if r != "429":
            continue
        for tok, eok, r2 in graded:
            if r2 != "ok" or abs(tok - t429) > window:
                continue
            same_token = eok.get("token") == e429.get("token")
            same_ip = eok.get("ip") == e429.get("ip")
            if same_token and not same_ip:
                evidence["same_token_other_ip"].append((e429, eok))
            elif not same_token and same_ip:
                evidence["other_token_same_ip"].append((e429, eok))
            elif not same_token and not same_ip:
                evidence["other_token_other_ip"].append((e429, eok))
    print("\nContrast pairs (a 429 and a 200 within %ds):" % args.window)
    for name, pairs in evidence.items():
        print("  %-22s %d" % (name, len(pairs)))
    print("\nReading it:")
    print("  other_token_other_ip > 0  -> NOT per account (another machine was fine while one was limited)")
    print("  other_token_same_ip  > 0  -> NOT per IP (a fresh token worked from the limited IP)")
    print("  all zero while 429s overlap across hosts -> per account; collect more data before concluding")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("watch")
    w.add_argument("--poll", type=float, default=15, help="seconds between shared-cache checks")
    w.add_argument("--probe-every", type=float, default=0, help="also probe every N seconds (0 = passive only)")
    sub.add_parser("probe")
    r = sub.add_parser("report")
    r.add_argument("logs", nargs="+")
    r.add_argument("--window", type=float, default=180)
    args = parser.parse_args()
    if args.cmd == "watch":
        watch(args)
    elif args.cmd == "probe":
        probe(public_ip())
    else:
        report(args)


if __name__ == "__main__":
    sys.exit(main())
