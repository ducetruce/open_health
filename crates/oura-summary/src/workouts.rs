//! Model-free workouts: numbers for a workout the wearer started, stopped or logged
//! themselves, and a rule-based detector for sustained movement.
//!
//! Oura's own workout detection is the AAD TorchScript model, which is proprietary and
//! not shipped in this repo. Without it the activity screen had nothing to show, so
//! this module gives the clients two model-free building blocks:
//!
//! * [`window_stats`] — what the ring recorded between two instants: per-minute MET
//!   (from `activity_information`), the active calories and estimated steps that
//!   `build_summary` derives from the same MET minutes, and the quality-gated heart
//!   rate (the same `green_ibi_quality_event` / `hrv_event` streams `hourly_hr` uses).
//! * [`detect_workouts`] — runs of minutes at or above [`ACTIVE_MET`], bridging short
//!   pauses. This is a threshold rule, not a classifier: it can say *how hard* you
//!   moved, not *what* you were doing, and the labels say exactly that.
//!
//! Calories and steps use `build_summary`'s formulas (MET above rest × weight, and the
//! MET-band step rate) so a workout's numbers add up to the day's totals.
//!
//! Daytime heart rate on the ring is sparse unless the ring is in a workout mode, so a
//! window can legitimately have MET minutes but no heart rate. `hr` is then `null`,
//! never a guess.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::ring_time::{ClockSource, RingClock};
use crate::{civil, offset_seconds, read_profile};
use oura_store::storage::Store;

/// Moderate intensity starts at 3 MET (the usual physical-activity guideline cut).
pub const ACTIVE_MET: f64 = 3.0;
/// Shortest run of activity reported as a workout.
pub const MIN_WORKOUT_MIN: i64 = 10;
/// Pauses up to this long (a traffic light, a water break) do not split a workout.
pub const MAX_PAUSE_MIN: i64 = 3;

const MIN_BPM: f64 = 30.0;
const MAX_BPM: f64 = 240.0;

/// MET per UTC minute (`unix / 60`), plus quality-gated heart-rate samples.
struct RingMinutes {
    met: BTreeMap<i64, f64>,
    hr: Vec<(f64, f64)>,
}

fn read_minutes(db: &Path) -> Result<RingMinutes> {
    let store = Store::open_read_only(db).context("opening DB")?;
    let events = store.decoded_events().context("reading events")?;
    let clock = RingClock::from_events(&events);
    let mut met: BTreeMap<i64, f64> = BTreeMap::new();
    let mut hr: Vec<(f64, f64)> = Vec::new();
    for (ds, tag, jstr, cu) in &events {
        let name = oura_protocol::events::event_name(*tag);
        let wanted = matches!(
            name,
            "activity_information" | "green_ibi_quality_event" | "hrv_event"
        );
        if !wanted {
            continue;
        }
        // An undated event has no wall-clock time, so it cannot fall in any window.
        if clock.resolve(*ds, *cu).source == ClockSource::Undated {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(jstr) else {
            continue;
        };
        if name == "activity_information" {
            let Some(mets) = v["met"].as_array() else {
                continue;
            };
            let t0 = clock.unix_s(*ds, *cu);
            for (i, m) in mets.iter().enumerate() {
                let Some(mv) = m.as_f64() else { continue };
                let minute = ((t0 + i as f64 * 60.0) / 60.0).floor() as i64;
                // Overlapping pages repeat minutes; keep one value per minute.
                let slot = met.entry(minute).or_insert(mv);
                if mv > *slot {
                    *slot = mv;
                }
            }
            continue;
        }
        let Some(bpms) = v["hr_bpm"].as_array() else {
            continue;
        };
        let step_ds = if name == "hrv_event" {
            crate::hrv_step_ds(&v)
        } else {
            0
        };
        for (sample_ds, bpm) in crate::packed_series(*ds, bpms, step_ds) {
            if (MIN_BPM..=MAX_BPM).contains(&bpm) {
                hr.push((clock.unix_s(sample_ds, *cu), bpm));
            }
        }
    }
    hr.sort_by(|a, b| a.0.total_cmp(&b.0));
    Ok(RingMinutes { met, hr })
}

/// `build_summary`'s step-rate bands (steps per minute for a MET value).
fn step_rate(met: f64) -> f64 {
    if met >= 7.0 {
        150.0
    } else if met >= 2.5 {
        105.0
    } else {
        0.0
    }
}

fn active_kcal(met: f64, weight_kg: f64) -> f64 {
    (met - 1.0).max(0.0) * weight_kg / 60.0
}

fn local_strings(unix: i64, tz: f64) -> (String, String) {
    let local = unix + offset_seconds(tz);
    let day = local.div_euclid(86_400);
    let secs = local.rem_euclid(86_400);
    let (y, m, d) = civil(day);
    (
        format!("{y:04}-{m:02}-{d:02}"),
        format!("{:02}:{:02}", secs / 3600, (secs % 3600) / 60),
    )
}

fn stats_from(minutes: &RingMinutes, start_unix: i64, end_unix: i64, weight_kg: f64) -> Value {
    let (m0, m1) = (start_unix.div_euclid(60), (end_unix - 1).div_euclid(60));
    let mets: Vec<f64> = if m1 >= m0 {
        minutes.met.range(m0..=m1).map(|(_, v)| *v).collect()
    } else {
        Vec::new()
    };
    let kcal: f64 = mets.iter().map(|m| active_kcal(*m, weight_kg)).sum();
    let steps: f64 = mets.iter().map(|m| step_rate(*m)).sum();
    let met_avg = (!mets.is_empty()).then(|| mets.iter().sum::<f64>() / mets.len() as f64);
    let met_peak = mets.iter().copied().fold(None, |a: Option<f64>, m| {
        Some(a.map_or(m, |a| a.max(m)))
    });
    let active_min = mets.iter().filter(|m| **m >= ACTIVE_MET).count();

    let (lo, hi) = (start_unix as f64, end_unix as f64);
    let beats: Vec<(f64, f64)> = minutes
        .hr
        .iter()
        .copied()
        .filter(|(t, _)| *t >= lo && *t < hi)
        .collect();
    let hr = if beats.is_empty() {
        Value::Null
    } else {
        let avg = beats.iter().map(|(_, b)| b).sum::<f64>() / beats.len() as f64;
        let max = beats.iter().map(|(_, b)| *b).fold(f64::MIN, f64::max);
        let min = beats.iter().map(|(_, b)| *b).fold(f64::MAX, f64::min);
        // Thin the series to at most ~120 points for a chart.
        let stride = (beats.len() / 120).max(1);
        let series: Vec<Value> = beats
            .iter()
            .step_by(stride)
            .map(|(t, b)| json!([t.round() as i64, b.round()]))
            .collect();
        json!({
            "avg": avg.round(),
            "max": max.round(),
            "min": min.round(),
            "samples": beats.len(),
            "series": series,
        })
    };
    let steps_r = (steps / 10.0).round() * 10.0;
    json!({
        "start_unix": start_unix,
        "end_unix": end_unix,
        "duration_min": ((end_unix - start_unix) as f64 / 60.0).round(),
        "covered_min": mets.len(),
        "active_min": active_min,
        "met_avg": met_avg.map(|m| (m * 10.0).round() / 10.0),
        "met_peak": met_peak.map(|m| (m * 10.0).round() / 10.0),
        "active_kcal": kcal.round(),
        "steps": steps_r,
        "distance_m": oura_analysis::ported::metabolic::steps_to_meters(steps_r as u32),
        "hr": hr,
    })
}

/// What the ring recorded between `start_unix` and `end_unix` (UTC seconds).
///
/// `covered_min` says how many of the window's minutes the ring has synced MET for;
/// fewer than the duration means the ring has not sent that stretch yet (sync again)
/// or was off the finger.
pub fn window_stats(db: &Path, start_unix: i64, end_unix: i64) -> Result<Value> {
    anyhow::ensure!(end_unix > start_unix, "workout must end after it starts");
    let demo = read_profile(db);
    let minutes = read_minutes(db)?;
    Ok(stats_from(&minutes, start_unix, end_unix, demo.weight_kg))
}

fn intensity_label(met_avg: f64) -> (&'static str, &'static str) {
    if met_avg >= 6.0 {
        ("vigorous activity", "vigorous")
    } else if met_avg >= 4.5 {
        ("moderate activity", "moderate")
    } else {
        ("walking", "light")
    }
}

/// Sustained activity in the last `days` days of data, newest first.
///
/// A workout is a run of minutes at or above [`ACTIVE_MET`], bridging pauses of up to
/// [`MAX_PAUSE_MIN`] minutes, with at least [`MIN_WORKOUT_MIN`] active minutes.
pub fn detect_workouts(db: &Path, tz: impl Into<crate::OffsetHours>, days: u32) -> Result<Value> {
    let tz = tz.into().0;
    anyhow::ensure!(tz.is_finite() && (-24.0..=24.0).contains(&tz), "invalid UTC offset");
    let demo = read_profile(db);
    let minutes = read_minutes(db)?;
    let Some(newest) = minutes.met.keys().next_back().copied() else {
        return Ok(json!({ "sessions": [] }));
    };
    let cut = newest - days as i64 * 1440;

    let mut runs: Vec<(i64, i64, i64)> = Vec::new(); // (first, last, active minutes)
    for (&minute, &met) in minutes.met.range(cut..) {
        if met < ACTIVE_MET {
            continue;
        }
        match runs.last_mut() {
            Some((_, last, active)) if minute - *last <= MAX_PAUSE_MIN + 1 => {
                *last = minute;
                *active += 1;
            }
            _ => runs.push((minute, minute, 1)),
        }
    }

    let mut sessions: Vec<Value> = runs
        .into_iter()
        .filter(|(_, _, active)| *active >= MIN_WORKOUT_MIN)
        .map(|(first, last, _)| {
            let (start_unix, end_unix) = (first * 60, (last + 1) * 60);
            let stats = stats_from(&minutes, start_unix, end_unix, demo.weight_kg);
            let met_avg = stats["met_avg"].as_f64().unwrap_or(ACTIVE_MET);
            let (label, intensity) = intensity_label(met_avg);
            let (ymd, start_hm) = local_strings(start_unix, tz);
            let (_, end_hm) = local_strings(end_unix, tz);
            json!({
                "start": format!("{ymd} {start_hm}"),
                "end": end_hm,
                "duration_min": last - first + 1,
                "label": label,
                "intensity": intensity,
                "source": "rule",
                "stats": stats,
            })
        })
        .collect();
    sessions.reverse();
    Ok(json!({
        "sessions": sessions,
        "rule": {
            "active_met": ACTIVE_MET,
            "min_minutes": MIN_WORKOUT_MIN,
            "max_pause_minutes": MAX_PAUSE_MIN,
        },
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minutes(points: &[(i64, f64)]) -> RingMinutes {
        RingMinutes {
            met: points.iter().copied().collect(),
            hr: vec![(600.0 * 60.0 + 30.0, 120.0), (605.0 * 60.0, 140.0)],
        }
    }

    #[test]
    fn stats_sum_met_minutes_like_the_summary() {
        let m = minutes(&[(600, 5.0), (601, 5.0), (602, 1.0)]);
        let s = stats_from(&m, 600 * 60, 603 * 60, 60.0);
        // (5-1)*60/60 = 4 kcal per active minute, rest minute adds nothing
        assert_eq!(s["active_kcal"], json!(8.0));
        assert_eq!(s["covered_min"], json!(3));
        assert_eq!(s["active_min"], json!(2));
        assert_eq!(s["steps"], json!(210.0));
        assert_eq!(s["hr"]["avg"], json!(120.0));
        assert_eq!(s["hr"]["samples"], json!(1));
    }

    #[test]
    fn window_without_heart_rate_reports_null() {
        let m = minutes(&[(10, 4.0)]);
        let s = stats_from(&m, 10 * 60, 11 * 60, 70.0);
        assert!(s["hr"].is_null());
    }

    #[test]
    fn labels_follow_intensity() {
        assert_eq!(intensity_label(3.2).0, "walking");
        assert_eq!(intensity_label(5.0).0, "moderate activity");
        assert_eq!(intensity_label(8.0).0, "vigorous activity");
    }

    #[test]
    fn local_strings_apply_offset() {
        // 1970-01-01 00:30 UTC at UTC-8 is 1969-12-31 16:30
        assert_eq!(
            local_strings(1800, -8.0),
            ("1969-12-31".to_string(), "16:30".to_string())
        );
    }
}
