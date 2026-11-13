#!/usr/bin/env python3
"""Download your daily Oura data from the Oura API v2 into a trends-style CSV.

The output has the same columns as the Oura web "trends" export that
tools/calibrate_scores.py and the iOS app's importer (Profile → Oura history,
crates/oura-summary/src/oura_export.rs) read: Oura's daily scores, every sleep and
readiness contributor sub-score, and the raw metrics behind them. Importing it fits
the scores to Oura's scale and adds your history from before the app.

Authentication: Oura retired personal access tokens in December 2025. Get a token
with the OAuth2 client-side flow (an access token valid for 30 days):

  1. Create an application at https://cloud.ouraring.com/oauth/applications with a
     redirect URI you control, for example https://example.com/oura (it never has to
     load: you only read the token out of the address bar).
  2. Open, with your client id filled in:
     https://cloud.ouraring.com/oauth/authorize?response_type=token&client_id=CLIENT_ID&scope=daily
  3. Approve. The browser is sent to the redirect URI with #access_token=... in the
     address; that value is the token.

Then:  OURA_TOKEN=... python3 tools/oura_api_export.py --out oura_trends.csv
(Inside a session whose network proxy injects the token, any OURA_TOKEN value works.)
--sandbox reads Oura's public sandbox data instead, for testing.

Your health data only goes to the file you name. Never commit it.
"""
import argparse
import csv
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.ouraring.com/v2"
USER_AGENT = "open-health-export/1.0"

SLEEP_CONTRIBUTORS = {
    "total_sleep": "Total Sleep Score",
    "restfulness": "Restfulness Score",
    "efficiency": "Sleep Efficiency Score",
    "rem_sleep": "REM Sleep Score",
    "deep_sleep": "Deep Sleep Score",
    "latency": "Sleep Latency Score",
    "timing": "Sleep Timin Score",  # (sic) the trends export's own spelling
}
READINESS_CONTRIBUTORS = {
    "resting_heart_rate": "Resting Heart Rate Score",
    "previous_night": "Previous Night Score",
    "hrv_balance": "HRV Balance Score",
    "body_temperature": "Temperature Score",
    "sleep_balance": "Sleep Balance Score",
    "previous_day_activity": "Previous Day Activity Score",
    "recovery_index": "Recovery Index Score",
    "activity_balance": "Activity Balance Score",
}
ACTIVITY_CONTRIBUTORS = {
    "move_every_hour": "Move Every Hour Score",
    "meet_daily_targets": "Meet Daily Targets Score",
    "stay_active": "Stay Active Score",
    "training_volume": "Training Volume Score",
    "training_frequency": "Training Frequency Score",
    "recovery_time": "Recovery Time Score",
}
COLUMNS = (
    ["date", "Sleep Score", "Readiness Score", "Activity Score",
     "Total Sleep Duration", "Total Bedtime", "Awake Time", "REM Sleep Duration",
     "Light Sleep Duration", "Deep Sleep Duration", "Sleep Efficiency", "Sleep Latency",
     "Restless Periods", "Bedtime Start", "Bedtime End", "Lowest Resting Heart Rate",
     "Average Resting Heart Rate", "Average HRV", "Respiratory Rate",
     "Temperature Deviation (°C)", "Temperature Trend Deviation", "Steps", "Activity Burn",
     "Total Burn", "Average MET", "Inactive Time", "Low Activity Time",
     "Medium Activity Time", "High Activity Time", "Non-wear Time"]
    + list(SLEEP_CONTRIBUTORS.values())
    + list(READINESS_CONTRIBUTORS.values())
    + list(ACTIVITY_CONTRIBUTORS.values())
)


def fetch(collection, start, end, token, sandbox):
    """Every document of a collection between two dates, following next_token."""
    base = f"{API}/{'sandbox/' if sandbox else ''}usercollection/{collection}"
    params = {"start_date": start.isoformat(), "end_date": end.isoformat()}
    out = []
    while True:
        url = base + "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}", "User-Agent": USER_AGENT})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    body = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < 4:
                    time.sleep(int(e.headers.get("Retry-After", "10")))
                    continue
                detail = e.read().decode("utf-8", "replace")[:300]
                sys.exit(f"{collection}: HTTP {e.code} {detail}")
        out.extend(body.get("data", []))
        if not body.get("next_token"):
            return out
        params["next_token"] = body["next_token"]


def fetch_range(collection, start, end, token, sandbox, step_days=180):
    """Fetch in windows so a long history never hits a per-request range limit."""
    out, cursor = [], start
    while cursor <= end:
        stop = min(end, cursor + dt.timedelta(days=step_days - 1))
        out.extend(fetch(collection, cursor, stop, token, sandbox))
        cursor = stop + dt.timedelta(days=1)
    return out


def by_day(docs):
    return {d["day"]: d for d in docs if d.get("day")}


def main_sleep(sessions):
    """The night each day's scores describe: the longest long_sleep, else the longest."""
    days = {}
    for s in sessions:
        day = s.get("day")
        if not day:
            continue
        key = (s.get("type") == "long_sleep", s.get("time_in_bed") or 0)
        if day not in days or key > days[day][0]:
            days[day] = (key, s)
    return {day: s for day, (_, s) in days.items()}


def average_met(activity):
    items = [m for m in ((activity.get("met") or {}).get("items") or []) if m]
    return round(sum(items) / len(items), 3) if items else None


def build_rows(sleep_daily, readiness, activity, sessions):
    rows = []
    for day in sorted(set(sleep_daily) | set(readiness) | set(activity) | set(sessions)):
        ds, dr, da, s = sleep_daily.get(day, {}), readiness.get(day, {}), activity.get(day, {}), sessions.get(day, {})
        row = {
            "date": day,
            "Sleep Score": ds.get("score"),
            "Readiness Score": dr.get("score"),
            "Activity Score": da.get("score"),
            "Total Sleep Duration": s.get("total_sleep_duration"),
            "Total Bedtime": s.get("time_in_bed"),
            "Awake Time": s.get("awake_time"),
            "REM Sleep Duration": s.get("rem_sleep_duration"),
            "Light Sleep Duration": s.get("light_sleep_duration"),
            "Deep Sleep Duration": s.get("deep_sleep_duration"),
            "Sleep Efficiency": s.get("efficiency"),
            "Sleep Latency": s.get("latency"),
            "Restless Periods": s.get("restless_periods"),
            "Bedtime Start": s.get("bedtime_start"),
            "Bedtime End": s.get("bedtime_end"),
            "Lowest Resting Heart Rate": s.get("lowest_heart_rate"),
            "Average Resting Heart Rate": s.get("average_heart_rate"),
            "Average HRV": s.get("average_hrv"),
            "Respiratory Rate": s.get("average_breath"),
            "Temperature Deviation (°C)": dr.get("temperature_deviation"),
            "Temperature Trend Deviation": dr.get("temperature_trend_deviation"),
            "Steps": da.get("steps"),
            "Activity Burn": da.get("active_calories"),
            "Total Burn": da.get("total_calories"),
            "Average MET": average_met(da),
            "Inactive Time": da.get("sedentary_time"),
            "Low Activity Time": da.get("low_activity_time"),
            "Medium Activity Time": da.get("medium_activity_time"),
            "High Activity Time": da.get("high_activity_time"),
            "Non-wear Time": da.get("non_wear_time"),
        }
        for source, mapping in ((ds, SLEEP_CONTRIBUTORS), (dr, READINESS_CONTRIBUTORS),
                                (da, ACTIVITY_CONTRIBUTORS)):
            contributors = source.get("contributors") or {}
            for key, column in mapping.items():
                row[column] = contributors.get(key)
        rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="CSV file to write")
    ap.add_argument("--start", default="2015-01-01", help="first day (YYYY-MM-DD)")
    ap.add_argument("--end", default=dt.date.today().isoformat(), help="last day (YYYY-MM-DD)")
    ap.add_argument("--sandbox", action="store_true", help="use Oura's public sandbox data")
    args = ap.parse_args()

    token = os.environ.get("OURA_TOKEN") or ("sandbox" if args.sandbox else None)
    if not token:
        sys.exit("set OURA_TOKEN (see the instructions at the top of this file)")
    start = dt.date.fromisoformat(args.start)
    # Oura's end_date is exclusive: ask for one day more so the last day is included.
    end = dt.date.fromisoformat(args.end) + dt.timedelta(days=1)

    data = {}
    for collection in ("daily_sleep", "daily_readiness", "daily_activity", "sleep"):
        data[collection] = fetch_range(collection, start, end, token, args.sandbox)
        print(f"{collection}: {len(data[collection])} records", file=sys.stderr)
    rows = build_rows(by_day(data["daily_sleep"]), by_day(data["daily_readiness"]),
                      by_day(data["daily_activity"]), main_sleep(data["sleep"]))
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        for row in rows:
            w.writerow({k: ("" if v is None else v) for k, v in row.items()})
    days = [r["date"] for r in rows]
    print(f"wrote {len(rows)} days ({days[0] if days else '–'} – {days[-1] if days else '–'}) to {args.out}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
