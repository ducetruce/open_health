#!/usr/bin/env python3
"""Synthetic demo data for simulator screenshots of the iOS app.

Writes, into the given Application Support directory:
  summary-cache.json  — a CachedSummary (Core.swift SummaryCache) the app shows at launch
  workouts.json       — WorkoutStore state (Workouts.swift)

Every value is invented. Usage: demo_summary.py <dir> [--active]
"""
import json
import math
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

out_dir = sys.argv[1]
active = "--active" in sys.argv
rng = random.Random(7)
now = datetime.now().astimezone()
today = now.date()
REF = datetime(2001, 1, 1, tzinfo=timezone.utc)  # Foundation's reference date


def ymd(d):
    return d.strftime("%Y-%m-%d")


def hypnogram(n):
    """Cycling deep → light → REM with brief wakes, 30 s epochs."""
    out, i = [], 0
    while len(out) < n:
        cycle = i // 180
        pos = i % 180
        if pos < 25 and cycle < 3:
            st = 1
        elif pos < 120:
            st = 2
        elif pos < 170:
            st = 3
        else:
            st = 4 if rng.random() < 0.6 else 2
        out.append(st)
        i += 1
    return out[:n]


nights, days = [], []
for k in range(12, -1, -1):
    wake = today - timedelta(days=k)
    bed = wake - timedelta(days=1)
    start_h, start_m = 23, rng.randint(0, 50)
    in_bed = round(7.2 + rng.uniform(-0.8, 0.9), 2)
    start_dt = datetime(bed.year, bed.month, bed.day, start_h, start_m).astimezone()
    end_dt = start_dt + timedelta(hours=in_bed)
    epochs = int(in_bed * 120)
    score = rng.randint(72, 91)
    nights.append({
        "date": ymd(bed), "ymd": ymd(bed), "wake_ymd": ymd(wake),
        "start": start_dt.strftime("%H:%M"), "end": end_dt.strftime("%H:%M"),
        "start_unix": int(start_dt.timestamp()), "end_unix": int(end_dt.timestamp()),
        "start_ds": 1000 + k, "end_ds": 2000 + k,
        "in_bed_h": in_bed, "hrv_ms": rng.randint(38, 62), "rhr": rng.randint(50, 58),
        "skin_temp": round(34.4 + rng.uniform(-0.3, 0.3), 2), "spo2_mean": rng.randint(95, 98),
        "deep_pct": 17, "light_pct": 52, "rem_pct": 23, "wake_pct": 8,
        "efficiency": rng.randint(86, 94),
        "stages_full": hypnogram(epochs), "staging_source": "ring", "staging_complete": True,
        "breath_rate": round(14.5 + rng.uniform(-0.6, 0.6), 1),
        "sleep_score": {
            "score": score, "basis": "published norms",
            "components": [
                {"key": "duration", "score": score + 4, "weight": 0.3},
                {"key": "efficiency", "score": score + 2, "weight": 0.2},
                {"key": "architecture", "score": score - 6, "weight": 0.2},
                {"key": "physiology", "score": score - 2, "weight": 0.3},
            ],
        },
    })
nights.reverse()  # newest first, like the summary

profile, daily = {}, {}
for k in range(13):
    d = today - timedelta(days=k)
    days.append(ymd(d))
    hours_done = now.hour + now.minute / 60 if k == 0 else 24
    prof = []
    for b in range(96):
        h = b / 4
        if h < 7 or h > 23 or h > hours_done:
            prof.append(0.0)
            continue
        base = 0.4 + 0.5 * math.sin(h / 24 * math.pi)
        if 17.5 <= h < 18.5 and k % 2 == 0:
            base += 5.5  # an evening run every other day
        if 12 <= h < 12.5:
            base += 2.0  # lunchtime walk
        prof.append(round(max(0, base + rng.uniform(-0.2, 0.4)), 2))
    profile[ymd(d)] = prof
    act = round(sum(prof) * 70 / 4 / 1.2)
    steps = round((5200 + rng.randint(0, 6000)) * (hours_done / 24), -2)
    daily[ymd(d)] = {"active_kcal": act, "total_kcal": act + 1650, "steps": steps,
                     "distance_m": round(steps * 0.762)}

hrv = [n["hrv_ms"] for n in reversed(nights)]
rhr = [n["rhr"] for n in reversed(nights)]
summary = {
    "digest": "You slept well and your HRV is above your baseline. A good day for a harder workout.",
    "device": {"serial": "DEMO0000", "firmware": "3.4.3", "battery_pct": 68,
               "battery_recorded": now.strftime("%H:%M"), "days_of_data": 13.0,
               "observed_days": 13, "nights": len(nights), "raw_events": 482113,
               "decoded_events": 481902, "synced": ymd(today), "synced_hm": now.strftime("%H:%M")},
    "nights": nights,
    "vitals": {
        "hrv": {"series": hrv, "latest": hrv[-1], "baseline": 48, "delta_pct": round((hrv[-1] - 48) / 48 * 100, 1)},
        "rhr": {"series": rhr, "latest": rhr[-1], "baseline": 54, "delta_pct": -2.0},
        "hr": {"latest": 64, "date": ymd(today), "hm": now.strftime("%H:%M")},
    },
    "activity_profile": profile,
    "activity_daily": daily,
    "profile": {"sex": "F", "age": 34, "height_m": 1.68, "weight_kg": 62},
    "fitness": {"vo2max": 41.3},
    "sleep_debt": {"debt_min": 95, "recent_shortfall_min": 40, "valid": True, "need_h": 8,
                   "valid_days": 12, "window_days": 14, "state": "low", "days": []},
    "symptoms": {"available": True, "status": "NO_SIGNS", "trafficLight": "NO_SIGNS", "score": 0.08,
                 "decision": 0, "date": ymd(today), "daysWithData": 12,
                 "biomarkers": [
                     {"type": "AverageBreath", "value": 14.6, "lower": 13.4, "upper": 16.1, "indicatesSymptoms": False},
                     {"type": "LowestHeartRate", "value": 51, "lower": 47, "upper": 56, "indicatesSymptoms": False},
                     {"type": "AverageHrv", "value": 52, "lower": 38, "upper": 64, "indicatesSymptoms": False},
                     {"type": "TemperatureDeviation", "value": 0.1, "lower": -0.4, "upper": 0.5, "indicatesSymptoms": False},
                 ]},
}

# one rule detection (lunchtime walk) today
walk_start = datetime(today.year, today.month, today.day, 12, 2).astimezone()
walk_end = walk_start + timedelta(minutes=27)
detected = [{
    "start": walk_start.strftime("%Y-%m-%d %H:%M"), "end": walk_end.strftime("%H:%M"),
    "duration_min": 27, "label": "walking", "intensity": "light",
    "stats": {"start_unix": int(walk_start.timestamp()), "end_unix": int(walk_end.timestamp()),
              "duration_min": 27, "covered_min": 27, "active_min": 25, "met_avg": 3.6, "met_peak": 4.4,
              "active_kcal": 83, "steps": 2830, "distance_m": 2156,
              "hr": {"avg": 104, "max": 121, "min": 88, "samples": 31,
                     "series": [[int(walk_start.timestamp()) + i * 52, 92 + 20 * math.sin(i / 6)] for i in range(31)]}},
}]

cache = {"summary": summary, "workouts": [], "illness": None, "detected": detected}
with open(f"{out_dir}/summary-cache.json", "w") as f:
    json.dump(cache, f)


def ref(dt):
    return (dt - REF).total_seconds()


yesterday_run = datetime(today.year, today.month, today.day, 17, 40).astimezone() - timedelta(days=1)
store = {
    "workouts": [{
        "id": str(uuid.UUID(int=1)), "kind": "running", "origin": "live",
        "start": ref(yesterday_run), "end": ref(yesterday_run + timedelta(minutes=42)),
    }, {
        "id": str(uuid.UUID(int=2)), "kind": "strength training", "origin": "logged",
        "start": ref(datetime(today.year, today.month, today.day, 7, 30).astimezone()),
        "end": ref(datetime(today.year, today.month, today.day, 8, 15).astimezone()),
        "note": "Upper body",
    }],
    "active": {"kind": "cycling", "start": ref(now - timedelta(minutes=23, seconds=17))} if active else None,
    "dismissed": [],
}
with open(f"{out_dir}/workouts.json", "w") as f:
    json.dump(store, f)
print("demo data written to", out_dir)
