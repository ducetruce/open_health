//! Daytime stress and resilience, model-free, on Oura's scale.
//!
//! **Daytime stress.** Oura judges stress from heart rate and HRV while you are awake
//! and still. The ring's daytime-HR feature records short bursts of quality-gated
//! beat-to-beat intervals (`green_ibi_quality_event`) every few minutes while the hand
//! is still. Each local 15-minute window that is outside every night and not moving
//! (mean ≤ 1.8 MET, Oura's own cut-off) and holds enough clean intervals gets a heart
//! rate and an RMSSD. Against the wearer's own baseline (the windows of the past 30
//! days), higher heart rate with lower HRV reads as stress and the reverse as recovery:
//! `raw = z(HR) − z(ln RMSSD)`, robust z-scores (median/MAD).
//!
//! The raw score is put on Oura's signed 0–100 scale (stress positive, recovery
//! negative) by **distribution matching**: a window's rank among the baseline's raw
//! scores picks the same rank in the wearer's own history of Oura 15-minute averages
//! (from an imported export's `daytimestress.csv`, else a default table). A window is
//! *stressed* at ≥ 49 and *restored* at ≤ −66 — the cut-offs that reproduce the
//! export's daily `stress_high` / `recovery_high` minutes without bias — *engaged* or
//! *relaxed* in between. A day (4 am to 4 am, as Oura groups it) is *stressful* with
//! ≥ 3 h stressed, *restored* with ≥ 3 h restored and ≤ 1 h stressed, else *normal*
//! (92% agreement with the export's `day_summary`).
//!
//! **Resilience** follows the export's `dailyresilience.csv`: its *stress* contributor
//! is a line in the mean √(stressed minutes) of the 14 days before, *daytime recovery*
//! a line in the mean √(restored minutes) of the last 14 days, and the level is set by
//! *sleep recovery* alone (cut-offs fitted per export; 91% agreement). Sleep recovery
//! is fitted at import from the 14-day means of nightly HRV, lowest heart rate and
//! sleep score. Days before the ring's data come from the imported export, so the
//! level is available from the first ring day.

use std::collections::{BTreeMap, HashMap};

use serde_json::{json, Map, Value};

/// Window length, seconds.
pub const WINDOW_S: i64 = 900;
/// Oura groups the day from 4 am.
const DAY_START_S: i64 = 4 * 3600;
/// Mean MET above which a window counts as moving (Oura's validator, code 3).
const MOVING_MET: f64 = 1.8;
/// Clean successive differences a window needs for an RMSSD.
const MIN_DIFFS: usize = 6;
/// Successive intervals further apart than this are artefacts, not HRV.
const MAX_DIFF_MS: f64 = 250.0;
/// Days of windows forming the baseline, and the fewest windows it needs.
const BASELINE_DAYS: i64 = 30;
const MIN_BASELINE_WINDOWS: usize = 40;
/// Least measured time for a day's verdict, minutes.
const MIN_VERDICT_MIN: f64 = 120.0;
/// Margin around a night that still counts as asleep, seconds.
const NIGHT_MARGIN_S: f64 = 900.0;
/// Windows kept in the JSON (the newest days); totals are kept for every day.
const TIMELINE_DAYS: usize = 35;

pub const STRESSED_AT: f64 = 49.0;
pub const RESTORED_AT: f64 = 66.0;
pub const STRESSFUL_MIN: f64 = 180.0;
pub const RESTORED_MIN: f64 = 180.0;
pub const RESTORED_MAX_STRESS_MIN: f64 = 60.0;

/// 15-minute averages of Oura's signed daytime stress (stress +, recovery −) at
/// every 2.5th percentile: one wearer's 33,430 windows, the default until an import.
pub const DEFAULT_QUANTILES: [f64; 41] = [
    -100.0, -86.7, -75.5, -68.0, -62.0, -57.0, -53.0, -49.0, -44.7, -41.0, -37.0, -33.3,
    -29.7, -27.0, -23.5, -20.2, -17.0, -13.7, -10.0, -7.0, -4.0, -1.0, 2.3, 6.0, 9.3,
    13.0, 16.7, 20.3, 24.0, 28.0, 32.0, 36.3, 41.0, 45.5, 50.0, 54.3, 59.0, 64.0, 70.0,
    79.0, 100.0,
];

pub const LEVELS: [&str; 5] = ["limited", "adequate", "solid", "strong", "exceptional"];
pub const DEFAULT_LEVEL_CUTS: [f64; 4] = [33.4, 45.8, 60.9, 75.5];
/// `contributor = a + b · mean(√minutes)` over 14 days.
pub const DEFAULT_STRESS_FIT: [f64; 2] = [9.28, 4.1921];
pub const DEFAULT_RECOVERY_FIT: [f64; 2] = [7.96, 4.5352];

/// The beats of one `green_ibi_quality_event`: its time and clean intervals in order
/// (`None` where a beat failed the ring's quality gate, which breaks a succession).
pub struct Burst {
    pub unix: f64,
    pub ibi_ms: Vec<Option<f64>>,
}

impl Burst {
    /// From a decoded `green_ibi_quality_event`.
    pub fn from_event(unix: f64, v: &Value) -> Option<Burst> {
        let ibi = v["ibi_ms"].as_array()?;
        let q = v["quality"].as_array()?;
        let ibi_ms = ibi
            .iter()
            .zip(q.iter())
            .map(|(i, q)| {
                let i = i.as_f64()?;
                (q.as_u64() == Some(1) && (300.0..=2000.0).contains(&i)).then_some(i)
            })
            .collect();
        Some(Burst { unix, ibi_ms })
    }
}

/// One night's bounds and the numbers sleep recovery is fitted on.
pub struct Night {
    pub start_unix: f64,
    pub end_unix: f64,
    pub wake_day: String,
    pub hours: f64,
    pub hrv_ms: Option<f64>,
    pub rhr: Option<f64>,
    pub sleep_score: Option<f64>,
}

#[derive(Default, Clone, Copy)]
struct Acc {
    sq: f64,
    n: usize,
}

struct Window {
    start: i64,
    hr: f64,
    ln_rmssd: f64,
}

fn median(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

/// Median and MAD-based spread (×1.4826, floored so a flat history cannot divide by 0).
fn robust(values: &[f64], floor: f64) -> (f64, f64) {
    let mut v = values.to_vec();
    let m = median(&mut v);
    let mut dev: Vec<f64> = values.iter().map(|x| (x - m).abs()).collect();
    (m, (median(&mut dev) * 1.4826).max(floor))
}

fn interp(table: &[f64], p: f64) -> f64 {
    let n = table.len();
    if n == 0 {
        return 0.0;
    }
    let x = p.clamp(0.0, 1.0) * (n - 1) as f64;
    let i = x.floor() as usize;
    if i + 1 >= n {
        return table[n - 1];
    }
    table[i] + (table[i + 1] - table[i]) * (x - i as f64)
}

fn ymd(day_index: i64) -> String {
    let (y, m, d) = crate::civil(day_index);
    format!("{y:04}-{m:02}-{d:02}")
}

fn day_index(ymd: &str) -> Option<i64> {
    let mut p = ymd.split('-');
    let y: i64 = p.next()?.parse().ok()?;
    let m: u32 = p.next()?.parse().ok()?;
    let d: u32 = p.next()?.parse().ok()?;
    Some(crate::days_from_civil(y, m, d))
}

/// The state of a window from its signed value.
pub fn state(value: f64, params: &Params) -> &'static str {
    if value >= params.stressed_at {
        "stressed"
    } else if value <= -params.restored_at {
        "restored"
    } else if value > 0.0 {
        "engaged"
    } else {
        "relaxed"
    }
}

/// A day's verdict from its stressed and restored minutes.
pub fn verdict(stressed_min: f64, restored_min: f64) -> &'static str {
    if stressed_min >= STRESSFUL_MIN {
        "stressful"
    } else if restored_min >= RESTORED_MIN && stressed_min <= RESTORED_MAX_STRESS_MIN {
        "restored"
    } else {
        "normal"
    }
}

/// What an imported export calibrated (see `oura_export::fit_stress`), with defaults.
pub struct Params {
    pub quantiles: Vec<f64>,
    pub stressed_at: f64,
    pub restored_at: f64,
    pub stress_fit: [f64; 2],
    pub recovery_fit: [f64; 2],
    /// `[intercept, hrv, rhr, sleep score]` over 14-day means, when fitted.
    pub sleep_recovery_fit: Option<[f64; 4]>,
    pub level_cuts: [f64; 4],
    pub calibrated: bool,
}

impl Params {
    pub fn from(p: Option<&Value>) -> Params {
        let s = p.map(|p| &p["stress"]).filter(|s| s.is_object());
        let arr = |v: &Value| -> Vec<f64> {
            v.as_array().map(|a| a.iter().filter_map(Value::as_f64).collect()).unwrap_or_default()
        };
        let pair = |v: Option<&Value>, d: [f64; 2]| -> [f64; 2] {
            let a = v.map(arr).unwrap_or_default();
            if a.len() == 2 { [a[0], a[1]] } else { d }
        };
        let quantiles = s.map(|s| arr(&s["quantiles"])).filter(|q| q.len() >= 11)
            .unwrap_or_else(|| DEFAULT_QUANTILES.to_vec());
        let cuts = s.map(|s| arr(&s["level_cuts"])).filter(|c| c.len() == 4);
        let sleep = s.map(|s| arr(&s["sleep_recovery_fit"])).filter(|c| c.len() == 4);
        Params {
            quantiles,
            stressed_at: s.and_then(|s| s["stressed_at"].as_f64()).unwrap_or(STRESSED_AT),
            restored_at: s.and_then(|s| s["restored_at"].as_f64()).unwrap_or(RESTORED_AT),
            stress_fit: pair(s.map(|s| &s["stress_fit"]), DEFAULT_STRESS_FIT),
            recovery_fit: pair(s.map(|s| &s["recovery_fit"]), DEFAULT_RECOVERY_FIT),
            sleep_recovery_fit: sleep.map(|c| [c[0], c[1], c[2], c[3]]),
            level_cuts: cuts.map(|c| [c[0], c[1], c[2], c[3]]).unwrap_or(DEFAULT_LEVEL_CUTS),
            calibrated: s.is_some(),
        }
    }
}

/// The `stress` block of the summary.
///
/// `minute_met` is each minute's MET keyed by unix minute; `history` is the imported
/// export's daily history (`stress_min`, `restored_min`, `stress_summary`,
/// `resilience_level`, `hrv_ms`, `rhr`, `sleep_score`).
pub fn build(
    bursts: &[Burst],
    nights: &[Night],
    minute_met: &HashMap<i64, f64>,
    tz_s: i64,
    params: &Params,
    history: Option<&Value>,
) -> Value {
    // ── windows ──
    let asleep = |t0: f64, t1: f64| {
        nights.iter().any(|n| t0 < n.end_unix + NIGHT_MARGIN_S && n.start_unix - NIGHT_MARGIN_S < t1)
    };
    let local_window = |unix: f64| -> i64 {
        let local = unix as i64 + tz_s;
        local.div_euclid(WINDOW_S) * WINDOW_S - tz_s
    };
    let mut acc: BTreeMap<i64, (Acc, Vec<f64>)> = BTreeMap::new();
    for b in bursts {
        let start = local_window(b.unix);
        let entry = acc.entry(start).or_insert((Acc::default(), Vec::new()));
        for pair in b.ibi_ms.windows(2) {
            if let (Some(a), Some(c)) = (pair[0], pair[1]) {
                let d = c - a;
                if d.abs() <= MAX_DIFF_MS {
                    entry.0.sq += d * d;
                    entry.0.n += 1;
                }
            }
        }
        entry.1.extend(b.ibi_ms.iter().flatten().copied());
    }
    let mut windows: Vec<Window> = Vec::new();
    for (start, (a, mut ibis)) in acc {
        if a.n < MIN_DIFFS || ibis.is_empty() {
            continue;
        }
        let (t0, t1) = (start as f64, (start + WINDOW_S) as f64);
        if asleep(t0, t1) {
            continue;
        }
        let mets: Vec<f64> = (0..WINDOW_S / 60).filter_map(|m| minute_met.get(&(start / 60 + m)).copied()).collect();
        if !mets.is_empty() && mets.iter().sum::<f64>() / mets.len() as f64 > MOVING_MET {
            continue;
        }
        let rmssd = (a.sq / a.n as f64).sqrt();
        if rmssd <= 0.0 {
            continue;
        }
        windows.push(Window { start, hr: 60_000.0 / median(&mut ibis), ln_rmssd: rmssd.ln() });
    }

    // ── values per day, each day against the 30 days up to it ──
    let day_of = |start: i64| (start + tz_s - DAY_START_S).div_euclid(86_400);
    let mut by_day: BTreeMap<i64, Vec<usize>> = BTreeMap::new();
    for (i, w) in windows.iter().enumerate() {
        by_day.entry(day_of(w.start)).or_default().push(i);
    }
    let mut days_out: BTreeMap<String, Value> = BTreeMap::new();
    let mut ring_days: BTreeMap<i64, (f64, f64)> = BTreeMap::new();
    for (&day, idx) in &by_day {
        let base: Vec<&Window> = windows
            .iter()
            .filter(|w| { let d = day_of(w.start); d <= day && d > day - BASELINE_DAYS })
            .collect();
        if base.len() < MIN_BASELINE_WINDOWS {
            continue;
        }
        let (hr_m, hr_s) = robust(&base.iter().map(|w| w.hr).collect::<Vec<_>>(), 1.0);
        let (hv_m, hv_s) = robust(&base.iter().map(|w| w.ln_rmssd).collect::<Vec<_>>(), 0.05);
        let raw = |w: &Window| (w.hr - hr_m) / hr_s - (w.ln_rmssd - hv_m) / hv_s;
        let mut base_raw: Vec<f64> = base.iter().map(|w| raw(w)).collect();
        base_raw.sort_by(|a, b| a.total_cmp(b));
        let rank = |r: f64| -> f64 {
            let below = base_raw.partition_point(|x| *x < r);
            let upto = base_raw.partition_point(|x| *x <= r);
            ((below + upto) as f64 / 2.0) / base_raw.len() as f64
        };
        let mut minutes: HashMap<&str, f64> = HashMap::new();
        let mut timeline = Vec::new();
        for &i in idx {
            let w = &windows[i];
            let value = interp(&params.quantiles, rank(raw(w))).round();
            let st = state(value, params);
            *minutes.entry(st).or_default() += WINDOW_S as f64 / 60.0;
            timeline.push(json!({ "start": w.start, "value": value, "state": st }));
        }
        let m = |k: &str| minutes.get(k).copied().unwrap_or(0.0);
        let measured = idx.len() as f64 * WINDOW_S as f64 / 60.0;
        let (stressed, restored) = (m("stressed"), m("restored"));
        let has_verdict = measured >= MIN_VERDICT_MIN;
        if has_verdict {
            ring_days.insert(day, (stressed, restored));
        }
        days_out.insert(ymd(day), json!({
            "stressed_min": stressed,
            "restored_min": restored,
            "engaged_min": m("engaged"),
            "relaxed_min": m("relaxed"),
            "measured_min": measured,
            "verdict": has_verdict.then(|| verdict(stressed, restored)),
            "windows": timeline,
        }));
    }
    // Only the newest days keep their windows.
    let n = days_out.len();
    for (i, v) in days_out.values_mut().enumerate() {
        if i + TIMELINE_DAYS < n {
            if let Some(o) = v.as_object_mut() {
                o.remove("windows");
            }
        }
    }

    json!({
        "days": days_out,
        "resilience": resilience(&ring_days, nights, params, history),
        "calibrated": params.calibrated,
        "stressed_at": params.stressed_at,
        "restored_at": params.restored_at,
    })
}

/// Daily stressed/restored minutes: the ring's days, else the imported export's.
fn daily_minutes(ring: &BTreeMap<i64, (f64, f64)>, history: Option<&Value>) -> BTreeMap<i64, (f64, f64)> {
    let mut out = BTreeMap::new();
    if let Some(h) = history.and_then(Value::as_object) {
        for (day, e) in h {
            let has_summary = e["stress_summary"].as_str().is_some_and(|s| !s.is_empty());
            if let (true, Some(d), Some(s), Some(r)) =
                (has_summary, day_index(day), e["stress_min"].as_f64(), e["restored_min"].as_f64())
            {
                out.insert(d, (s, r));
            }
        }
    }
    out.extend(ring.iter().map(|(k, v)| (*k, *v)));
    out
}

/// Nightly HRV, lowest heart rate and sleep score by wake day: ring nights (the
/// longest per day), else the imported export's.
fn nightly(nights: &[Night], history: Option<&Value>) -> BTreeMap<i64, [Option<f64>; 3]> {
    let mut out: BTreeMap<i64, [Option<f64>; 3]> = BTreeMap::new();
    if let Some(h) = history.and_then(Value::as_object) {
        for (day, e) in h {
            if let Some(d) = day_index(day) {
                let f = [e["hrv_ms"].as_f64(), e["rhr"].as_f64(), e["sleep_score"].as_f64()];
                if f.iter().any(Option::is_some) {
                    out.insert(d, f);
                }
            }
        }
    }
    let mut longest: HashMap<i64, f64> = HashMap::new();
    for n in nights {
        let Some(d) = day_index(&n.wake_day) else { continue };
        if longest.get(&d).is_some_and(|h| *h >= n.hours) {
            continue;
        }
        longest.insert(d, n.hours);
        let prev = out.get(&d).copied().unwrap_or([None; 3]);
        out.insert(d, [n.hrv_ms.or(prev[0]), n.rhr.or(prev[1]), n.sleep_score.or(prev[2])]);
    }
    out
}

fn mean_over(map: &BTreeMap<i64, f64>, from: i64, to: i64, min: usize) -> Option<f64> {
    let v: Vec<f64> = map.range(from..=to).map(|(_, x)| *x).collect();
    (v.len() >= min).then(|| v.iter().sum::<f64>() / v.len() as f64)
}

/// Sleep recovery for a day from the 14-day means, by the fitted line or, without an
/// import, a plain mapping of the mean sleep score.
pub fn sleep_recovery(fit: Option<[f64; 4]>, hrv: Option<f64>, rhr: Option<f64>, score: Option<f64>) -> Option<f64> {
    let v = match fit {
        Some(c) => c[0] + c[1] * hrv? + c[2] * rhr? + c[3] * score?,
        None => score? - 15.0,
    };
    Some(v.clamp(0.0, 100.0))
}

pub fn level(sleep_recovery: f64, cuts: &[f64; 4]) -> &'static str {
    LEVELS[cuts.iter().filter(|c| sleep_recovery >= **c).count()]
}

fn resilience(
    ring: &BTreeMap<i64, (f64, f64)>,
    nights: &[Night],
    params: &Params,
    history: Option<&Value>,
) -> Value {
    let minutes = daily_minutes(ring, history);
    let sqrt_stress: BTreeMap<i64, f64> = minutes.iter().map(|(d, (s, _))| (*d, s.max(0.0).sqrt())).collect();
    let sqrt_restored: BTreeMap<i64, f64> = minutes.iter().map(|(d, (_, r))| (*d, r.max(0.0).sqrt())).collect();
    let night = nightly(nights, history);
    let pick = |i: usize| -> BTreeMap<i64, f64> {
        night.iter().filter_map(|(d, f)| f[i].map(|v| (*d, v))).collect()
    };
    let (hrv, rhr, score) = (pick(0), pick(1), pick(2));
    let imported_level = |d: i64| -> Option<String> {
        history?.get(ymd(d))?["resilience_level"].as_str().map(str::to_string)
    };

    let Some(&last) = ring.keys().next_back().or(minutes.keys().next_back()) else {
        return json!({ "level": Value::Null, "days_of_stress": 0, "history": [] });
    };
    let first = last - 59;
    let mut out_history = Vec::new();
    let mut latest = Value::Null;
    for d in first..=last {
        let stress_c = mean_over(&sqrt_stress, d - 14, d - 1, 5)
            .map(|m| (params.stress_fit[0] + params.stress_fit[1] * m).clamp(0.0, 100.0));
        let recovery_c = mean_over(&sqrt_restored, d - 13, d, 5)
            .map(|m| (params.recovery_fit[0] + params.recovery_fit[1] * m).clamp(0.0, 100.0));
        let sleep_c = sleep_recovery(
            params.sleep_recovery_fit,
            mean_over(&hrv, d - 13, d, 5),
            mean_over(&rhr, d - 13, d, 5),
            mean_over(&score, d - 13, d, 5),
        );
        let computed = match (stress_c, recovery_c, sleep_c) {
            (Some(_), Some(_), Some(s)) => Some(level(s, &params.level_cuts).to_string()),
            _ => None,
        };
        // Oura's own level for days the export covers; ours after.
        let lvl = if ring.range(..=d).next().is_none() { imported_level(d).or(computed) } else { computed };
        if let Some(l) = &lvl {
            out_history.push(json!({ "date": ymd(d), "level": l }));
        }
        if d == last {
            let round = |v: Option<f64>| v.map(|x| (x * 10.0).round() / 10.0);
            latest = json!({
                "level": lvl,
                "contributors": {
                    "sleep_recovery": round(sleep_c),
                    "daytime_recovery": round(recovery_c),
                    "stress": round(stress_c),
                },
            });
        }
    }
    let days_of_stress = minutes.range(last - 13..=last).count();
    let week_ago = out_history.iter().rev().find(|h| {
        h["date"].as_str().and_then(day_index).is_some_and(|d| d <= last - 7)
    }).and_then(|h| h["level"].as_str().map(str::to_string));
    let mut o = latest.as_object().cloned().unwrap_or_else(Map::new);
    o.insert("date".into(), json!(ymd(last)));
    o.insert("days_of_stress".into(), json!(days_of_stress));
    o.insert("week_ago".into(), json!(week_ago));
    o.insert("history".into(), json!(out_history));
    Value::Object(o)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verdict_rules() {
        assert_eq!(verdict(180.0, 0.0), "stressful");
        assert_eq!(verdict(60.0, 180.0), "restored");
        assert_eq!(verdict(75.0, 240.0), "normal");
        assert_eq!(verdict(30.0, 30.0), "normal");
    }

    #[test]
    fn levels_follow_the_cuts() {
        assert_eq!(level(20.0, &DEFAULT_LEVEL_CUTS), "limited");
        assert_eq!(level(50.0, &DEFAULT_LEVEL_CUTS), "solid");
        assert_eq!(level(80.0, &DEFAULT_LEVEL_CUTS), "exceptional");
    }

    /// Thirty quiet days of still daytime windows, then an afternoon with a faster
    /// heart and lower HRV: that afternoon reads as stressed, a calm one as not.
    #[test]
    fn a_tense_afternoon_reads_as_stress() {
        let day0 = crate::days_from_civil(2026, 10, 1) * 86_400;
        let mut bursts = Vec::new();
        let mut push = |unix: f64, base: f64, swing: f64| {
            let ibi: Vec<Option<f64>> =
                (0..20).map(|k| Some(base + if k % 2 == 0 { swing } else { -swing })).collect();
            bursts.push(Burst { unix, ibi_ms: ibi });
        };
        for d in 0..31 {
            for w in 0..40 {
                // 10:00–20:00 local (UTC here), one burst per window, mild variety
                let t = day0 + d * 86_400 + 10 * 3600 + w * 900 + 60;
                let jitter = ((d * 7 + w * 3) % 11) as f64;
                let tense = d == 30 && w >= 20;
                let (base, swing) = if tense { (650.0, 8.0) } else { (900.0 + jitter * 4.0, 25.0 + jitter) };
                push(t as f64, base, swing);
            }
        }
        let out = build(&bursts, &[], &HashMap::new(), 0, &Params::from(None), None);
        let last = &out["days"]["2026-10-31"];
        assert!(last["stressed_min"].as_f64().unwrap() >= 20.0 * 15.0 * 0.8, "{last}");
        let calm = &out["days"]["2026-10-30"];
        assert!(calm["stressed_min"].as_f64().unwrap() < 200.0, "{calm}");
        assert_eq!(last["verdict"], "stressful");
    }

    #[test]
    fn windows_while_asleep_or_moving_are_skipped() {
        let mut bursts = Vec::new();
        for w in 0..80 {
            bursts.push(Burst { unix: (w * 900 + 30) as f64, ibi_ms: (0..20).map(|k| Some(900.0 + (k % 3) as f64 * 10.0)).collect() });
        }
        let nights = vec![Night { start_unix: 0.0, end_unix: 20.0 * 900.0, wake_day: "1970-01-01".into(), hours: 5.0, hrv_ms: None, rhr: None, sleep_score: None }];
        let mut met = HashMap::new();
        for m in 0..15 { met.insert(40 * 15 + m, 3.0); } // window 40 moving
        let out = build(&bursts, &nights, &met, 0, &Params::from(None), None);
        let measured: f64 = out["days"].as_object().unwrap().values().map(|d| d["measured_min"].as_f64().unwrap()).sum();
        // 80 windows − 21 asleep (incl. margin) − 1 moving
        assert_eq!(measured, (80.0 - 22.0) * 15.0);
    }
}
