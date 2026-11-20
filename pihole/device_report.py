#!/usr/bin/env python3
"""
device_report.py — list which domains a device queried through Pi-hole.

Two data sources:
  * FTL database (default) — read-only, safe while Pi-hole is running.
    NOTE: in WSL2 mirrored mode every query appears to come from the host IP,
    so per-device reports need the relay CSV instead.
  * --relay-csv — the Windows dns-relay.ps1 log (timestamp,clientIP,domain).
    This is the source of truth for per-device tracking in mirrored mode.

Examples:
  # Top 30 domains a device hit in the last 7 days (FTL db)
  ./device_report.py --client <DEVICE_IP>

  # Per-device report from the relay CSV (mirrored mode)
  ./device_report.py --relay-csv /path/to/dns-relay.csv \\
      --client <DEVICE_IP> --hours 24

  # Which devices are talking to the Pi-hole at all? (relay CSV only)
  ./device_report.py --relay-csv /path/to/dns-relay.csv --all-devices

  # Only what got blocked for it
  ./device_report.py --client <DEVICE_IP> --blocked-only
"""
import argparse
import csv
import os
import sqlite3
import sys
import time
from datetime import datetime, timedelta

# Pi-hole v6 long-term query database (files.database default)
DB = os.environ.get("PIHOLE_DB", "/etc/pihole/pihole-FTL.db")
# v6 status codes that mean "blocked" (docs.pi-hole.net/database/query-database)
BLOCKED = "1, 4, 5, 6, 7, 8, 9, 10, 11, 15, 16, 18"


def load_relay_csv(path: str, client: str | None, cutoff: datetime):
    """Yield (timestamp, client_ip, domain) rows from the relay CSV."""
    rows = []
    try:
        with open(path, newline="", encoding="utf-8-sig") as f:
            for rec in csv.reader(f):
                if len(rec) < 3:
                    continue
                ts_s, ip, domain = rec[0].strip(), rec[1].strip(), rec[2].strip()
                try:
                    ts = datetime.strptime(ts_s, "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    continue
                if ts < cutoff:
                    continue
                if client and ip != client:
                    continue
                rows.append((ts, ip, domain))
    except OSError as e:
        sys.exit(f"cannot open {path}: {e}")
    return rows


def blocked_domains_from_db() -> set[str]:
    """Domains currently in the blocklist (gravity table) — heuristic for
    --blocked-only when using the relay CSV."""
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        out = {r[0].lower() for r in con.execute(
            "SELECT domain FROM gravity")}
        con.close()
        return out
    except sqlite3.Error:
        return set()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Report domains queried by one client via Pi-hole")
    ap.add_argument("--client",
                    help="Client IP address (omit with --all-devices)")
    ap.add_argument("--relay-csv",
                    help="Path to dns-relay.csv (per-device source of truth "
                         "in WSL2 mirrored mode)")
    ap.add_argument("--all-devices", action="store_true",
                    help="Summarize every client in the relay CSV")
    ap.add_argument("--hours", type=float, default=24 * 7,
                    help="Look-back window in hours (default: 168 = 7 days)")
    ap.add_argument("--top", type=int, default=30,
                    help="Show top N domains (default 30)")
    ap.add_argument("--all", action="store_true",
                    help="List every domain, not just the top N")
    ap.add_argument("--blocked-only", action="store_true",
                    help="Only show blocked queries")
    args = ap.parse_args()

    if not args.relay_csv:
        return report_from_db(args)

    # ---- relay CSV mode (per-device tracking in mirrored mode) ----
    cutoff = datetime.now() - timedelta(hours=args.hours)
    rows = load_relay_csv(args.relay_csv, None, cutoff)
    if not rows:
        print(f"No queries in {args.relay_csv} for the last "
              f"{args.hours:g} h. Is the relay running?")
        return 1

    if args.all_devices:
        per_client: dict[str, list[tuple[datetime, str]]] = {}
        for ts, ip, domain in rows:
            per_client.setdefault(ip, []).append((ts, domain))
        print(f"Relay CSV : {args.relay_csv}")
        print(f"Window    : last {args.hours:g} h")
        print()
        hdr = f"{'client':<18} {'queries':>8}  top domains (last seen)"
        print(hdr)
        print("-" * len(hdr))
        for ip, items in sorted(per_client.items(),
                                key=lambda kv: -len(kv[1])):
            counts: dict[str, int] = {}
            for _, d in items:
                counts[d] = counts.get(d, 0) + 1
            top = ", ".join(f"{d} ({n})" for d, n in sorted(
                counts.items(), key=lambda kv: -kv[1])[:3])
            last = max(ts for ts, _ in items).strftime("%H:%M:%S")
            print(f"{ip:<18} {len(items):>8}  {top}   [last {last}]")
        return 0

    if not args.client:
        sys.exit("--client is required (or use --all-devices)")

    blocked_set = (blocked_domains_from_db()
                   if args.blocked_only else None)
    rows = [(ts, ip, d) for ts, ip, d in rows
            if ip == args.client
            and (not blocked_set or d.lower() in blocked_set)]
    if not rows:
        print(f"No queries from {args.client} in the last {args.hours:g} h.")
        return 1

    counts: dict[str, int] = {}
    for _, _, d in rows:
        counts[d] = counts.get(d, 0) + 1
    first = min(ts for ts, _, _ in rows).strftime("%Y-%m-%d %H:%M")
    last = max(ts for ts, _, _ in rows).strftime("%Y-%m-%d %H:%M")

    print(f"Client   : {args.client}  (source: relay CSV)")
    print(f"Window   : last {args.hours:g} h  "
          f"(activity {first} .. {last})")
    if blocked_set is not None:
        print("Filter   : domains in Pi-hole blocklist only (heuristic)")
    print(f"Queries  : {len(rows)}")
    print()

    ordered = sorted(counts.items(), key=lambda kv: -kv[1])
    if not args.all:
        ordered = ordered[:args.top]
    w = max(len(d) for d, _ in ordered)
    for domain, n in ordered:
        print(f"{domain:<{w}}  {n:>6}")
    return 0


def report_from_db(args) -> int:

    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    except sqlite3.Error as e:
        sys.exit(f"cannot open {DB}: {e}")

    cutoff = int(time.time()) - int(args.hours * 3600)
    where = "client = ? AND timestamp >= ?"
    params = [args.client, cutoff]

    total, = con.execute(
        f"SELECT COUNT(*) FROM queries WHERE {where}", params).fetchone()
    blocked, = con.execute(
        f"SELECT COUNT(*) FROM queries WHERE {where} AND status IN ({BLOCKED})",
        params).fetchone()

    print(f"Client   : {args.client}")
    print(f"Window   : last {args.hours:g} h")
    pct = (100 * blocked // total) if total else 0
    print(f"Queries  : {total} total, {blocked} blocked ({pct}%)")
    print()

    limit = "" if args.all else f"LIMIT {args.top}"
    rows = con.execute(
        f"""SELECT domain, COUNT(*) AS n, SUM(status IN ({BLOCKED})) AS b
            FROM queries WHERE {where}
            GROUP BY domain ORDER BY n DESC {limit}""", params).fetchall()

    if not rows:
        print("No queries found. Is the device actually using this Pi-hole as DNS?")
        return 1

    w = max(len(d) for d, _, _ in rows)
    for domain, n, b in rows:
        flag = f"  [{b} blocked]" if b else ""
        print(f"{domain:<{w}}  {n:>6}{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
