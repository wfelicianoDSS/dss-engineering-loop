#!/usr/bin/env python3
"""super-board-report.py — why is the board idle, and how much is landing?

Reads the per-day run manifests (`docs/super-board/runs/*-fieldops.md`) and the
watchdog log, and prints a per-day tally of activity and of the reasons the board
sat still. Read-only: it never touches the board or GitHub.

Usage:
  super-board-report.py [--repo <path>] [--days N]

Columns:
  disp        lane dispatches (build/qa/review workers started)
  groom       groom dispatches
  zomb        zombie workers killed
  claudeOut   times the runner switched Claude -> Codex (Claude plan exhausted)
  paused      ticks logged while a provider was paused (quota)
  halt        runaway/halt lines
  clean       clean end-of-work exits

Watchdog columns:
  rDown       "runner is DOWN" checks
  restart     self-heal restarts
  quotaWait   checks that waited quietly on quota
  gateHold    github-halt checks preserved (not auto-resolved)
  autoResume  read halts auto-resumed by --resume
  dedupe      duplicate runner/guard terminations
"""
import argparse, collections, datetime, glob, os, re, sys

RUN_COLS = [("dispatch lane=", "disp"), ("dispatch lane=groom", "groom"),
            ("zombie", "zomb"), ("backend switched to codex", "claudeOut"),
            ("lane paused:", "paused"), ("halt —", "halt"), ("exiting cleanly", "clean")]
WD_COLS = [("runner is DOWN", "rDown"), ("restart:", "restart"),
           ("waiting quietly", "quotaWait"), ("waiting for quota", "quotaWait"),
           ("github-halt present", "gateHold"), ("cleared by --resume", "autoResume"),
           ("self-heal: duplicate", "dedupe")]


def tally(paths, cols, day_from_name):
    agg = collections.defaultdict(collections.Counter)
    for path in paths:
        day = day_from_name(path)
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        for line in lines:
            for needle, key in cols:
                if needle in line and (needle != "dispatch lane=groom" or "groom" in line):
                    # a groom dispatch also contains "dispatch lane=": count once
                    if key == "disp" and "lane=groom" in line:
                        continue
                    agg[day][key] += 1
                    break
    return agg


def print_table(title, agg, keys, days):
    print(f"\n=== {title} ===")
    header = " ".join(f"{k[:9]:>9}" for k in keys)
    print(f"{'day':12} {header}")
    for day in days:
        print(f"{day:12} " + " ".join(f"{agg[day][k]:>9}" for k in keys))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.path.expanduser("~/fieldops"))
    ap.add_argument("--days", type=int, default=7)
    args = ap.parse_args()
    os.chdir(args.repo)

    run_paths = glob.glob("docs/super-board/runs/*-fieldops.md")
    wd_path = "docs/super-board/watchdog.log"
    run_agg = tally(run_paths, RUN_COLS, lambda p: os.path.basename(p)[:10])
    # watchdog lines carry their own UTC date in the bracket
    wd_day = collections.defaultdict(collections.Counter)
    if os.path.exists(wd_path):
        for line in open(wd_path, errors="replace"):
            m = re.match(r"\[(\d{4}-\d{2}-\d{2})", line)
            if not m:
                continue
            for needle, key in WD_COLS:
                if needle in line:
                    wd_day[m.group(1)][key] += 1
                    break

    today = datetime.date.today()
    days = [(today - datetime.timedelta(days=i)).isoformat() for i in range(args.days)][::-1]
    run_keys = ["disp", "groom", "zomb", "claudeOut", "paused", "halt", "clean"]
    wd_keys = ["rDown", "restart", "quotaWait", "gateHold", "autoResume", "dedupe"]
    print_table("run manifests (dispatches + stalls)", run_agg, run_keys, days)
    print_table("watchdog (self-heals + waits)", wd_day, wd_keys, days)

    total = collections.Counter()
    for d in days:
        total += run_agg[d]
    print("\n=== last %d days: dominant stall ===" % args.days)
    pause = total["paused"] + total["claudeOut"]
    print(f"dispatches={total['disp']}  claudeOut={total['claudeOut']}  pausedTicks={total['paused']}")
    if pause > total["disp"] * 0.5:
        print("→ provider quota (Claude) dominates idle time — more Claude/fallback capacity pays off.")
    elif total["disp"] < 5:
        print("→ almost no activity — check host uptime / halts, not capacity.")
    else:
        print("→ activity looks steady; look at review/merge queue and human-gate waits next.")


if __name__ == "__main__":
    sys.exit(main())
