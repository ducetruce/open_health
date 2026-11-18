//! Import of an Oura account export, done entirely on the device. Two layouts are
//! read: the older single "trends" CSV (one row per day, comma-separated), and the
//! newer per-type export (dailysleep.csv, dailyreadiness.csv, sleepmodel.csv,
//! dailyactivity.csv, dailyspo2.csv …; semicolon-separated, contributor scores as
//! JSON). The newer files are merged into the same one-row-per-day table first.
//!
//! The export does two jobs:
//!
//! 1. **Calibration.** It pairs Oura's own contributor sub-scores with the raw metrics
//!    behind them, so each contributor's curve can be fitted for this user. This is a
//!    port of `tools/calibrate_scores.py` (fitting) and
//!    `tools/fit_sleep_score.py::score_from_params` (evaluation): same drivers, same
//!    curve kinds (isotonic, binned empirical, linear, constant), same clamp to 1-100
//!    and the same combiner `round(Σ wᵢ·subᵢ / 100)` with the recovered weights. The
//!    Python tools measured Sleep end-to-end at R² ≈ 0.96 and Readiness ≈ 0.49 with
//!    Oura's own staging; with ring staging here, expect somewhat less.
//! 2. **History.** Every day in the export (Oura's own scores, sleep, heart rate,
//!    HRV, temperature, steps, calories) is kept, so trends reach back before this
//!    app's first sync.
//!
//! Everything is written to `oura_export.json` next to the ring database, never
//! anywhere else.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Map, Value};

pub const SLEEP: &str = "Sleep Score";
pub const READINESS: &str = "Readiness Score";

/// Recovered combiner weights (`tools/fit_scores_all.py::WEIGHTS`).
const WEIGHTS: &[(&str, &[(&str, f64)])] = &[
    (
        SLEEP,
        &[
            ("Total Sleep Score", 35.0),
            ("Restfulness Score", 15.0),
            ("Sleep Efficiency Score", 10.0),
            ("REM Sleep Score", 10.0),
            ("Deep Sleep Score", 10.0),
            ("Sleep Latency Score", 10.0),
            ("Sleep Timin Score", 10.0),
        ],
    ),
    (
        READINESS,
        &[
            ("Resting Heart Rate Score", 17.0),
            ("Previous Night Score", 15.0),
            ("HRV Balance Score", 15.0),
            ("Temperature Score", 13.0),
            ("Sleep Balance Score", 12.0),
            ("Previous Day Activity Score", 10.0),
            ("Recovery Index Score", 10.0),
            ("Activity Balance Score", 8.0),
            ("Sleep Regularity Score", 0.0),
        ],
    ),
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[allow(dead_code)] // `Mean` is written by `fit_contributor` directly
enum Kind {
    Mono,
    Emp,
    Lin,
    Mean,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Mono => "mono",
            Kind::Emp => "emp",
            Kind::Lin => "lin",
            Kind::Mean => "mean",
        }
    }
}

/// Ring-derivable drivers per contributor (`tools/calibrate_scores.py::LIVE_DRIVERS`).
const DRIVERS: &[(&str, &[&str], Kind)] = &[
    ("Total Sleep Score", &["Total Sleep Duration"], Kind::Mono),
    ("Sleep Efficiency Score", &["Sleep Efficiency"], Kind::Mono),
    ("REM Sleep Score", &["REM Sleep Duration"], Kind::Mono),
    ("Deep Sleep Score", &["Deep Sleep Duration"], Kind::Mono),
    ("Sleep Latency Score", &["Sleep Latency"], Kind::Emp),
    ("Restfulness Score", &["awake_frac", "Sleep Efficiency"], Kind::Lin),
    // Distance of the sleep midpoint from the wearer's own usual midpoint (circular
    // mean of the previous 28 nights). Fitted on recent days only (see RECENT_ONLY):
    // Oura re-tuned timing once already, and old days then mislead the curve.
    ("Sleep Timin Score", &["dist_usual"], Kind::Mono),
    ("Previous Night Score", &["Sleep Score"], Kind::Mono),
    (
        "Resting Heart Rate Score",
        &[
            "Lowest Resting Heart Rate",
            "Average Resting Heart Rate",
            "trail14_Average Resting Heart Rate",
        ],
        Kind::Lin,
    ),
    // Past week's HRV against the past two months' (`hrv_ratio`).
    ("HRV Balance Score", &["hrv_ratio"], Kind::Mono),
    ("Temperature Score", &["Temperature Deviation (°C)"], Kind::Emp),
    (
        "Sleep Balance Score",
        &["Total Sleep Duration", "trail14_Total Sleep Duration"],
        Kind::Lin,
    ),
    ("Previous Day Activity Score", &["prev_Average MET"], Kind::Mono),
    (
        "Activity Balance Score",
        &["prev_Average MET", "trail14_Average MET"],
        Kind::Lin,
    ),
    // Hours from the night's lowest heart rate to waking, and where in the night
    // that low came. The older trends export lacks heart-rate curves: then the
    // contributor falls back to its average (see `fit_contributor`).
    ("Recovery Index Score", &["rec_h", "low_frac"], Kind::Lin),
    // Spread of the sleep midpoint over the past week, and tonight's distance from it.
    ("Sleep Regularity Score", &["mid_sd7", "mid_reg"], Kind::Lin),
];

/// Contributors fitted on only the most recent N usable days.
const RECENT_ONLY: &[(&str, usize)] = &[("Sleep Timin Score", 250)];

/// Daily values kept as history: export column → key in the summary JSON.
const HISTORY_COLUMNS: &[(&str, &str)] = &[
    ("Sleep Score", "sleep_score"),
    ("Readiness Score", "readiness"),
    ("Activity Score", "activity_score"),
    ("Total Sleep Duration", "asleep_s"),
    ("Lowest Resting Heart Rate", "rhr"),
    ("Average HRV", "hrv_ms"),
    ("Temperature Deviation (°C)", "temp_deviation"),
    ("Respiratory Rate", "breath_rate"),
    ("Average Breath", "breath_rate"),
    ("SpO2 Average", "spo2"),
    ("Steps", "steps"),
    ("Activity Burn", "active_kcal"),
    ("Active Calories", "active_kcal"),
];

pub fn path(db: &Path) -> PathBuf {
    db.with_file_name("oura_export.json")
}

/// The imported export, if any: `{source, first, last, days, history, params}`.
pub fn load(db: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(path(db)).ok()?;
    serde_json::from_str(&text).ok()
}

pub fn clear(db: &Path) -> Result<()> {
    match std::fs::remove_file(path(db)) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

// ── CSV ──────────────────────────────────────────────────────────────────────

/// Minimal RFC 4180 reader: quoted fields, doubled quotes, CRLF or LF. The
/// delimiter is a comma, or a semicolon when the header line has more of those.
fn parse_csv(text: &str) -> Vec<Vec<String>> {
    let header = text.lines().next().unwrap_or("");
    let delimiter = if header.matches(';').count() > header.matches(',').count() { ';' } else { ',' };
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = text.trim_start_matches('\u{feff}').chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            match c {
                '"' if chars.peek() == Some(&'"') => {
                    field.push('"');
                    chars.next();
                }
                '"' => quoted = false,
                _ => field.push(c),
            }
            continue;
        }
        match c {
            '"' => quoted = true,
            c if c == delimiter => row.push(std::mem::take(&mut field)),
            '\r' => {}
            '\n' => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            _ => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows.retain(|r| r.iter().any(|f| !f.trim().is_empty()));
    rows
}

type Row = HashMap<String, Value>;

fn number(raw: &str) -> Option<f64> {
    let t = raw.trim();
    if t.is_empty() || t == "None" || t == "null" {
        return None;
    }
    t.parse::<f64>().ok().filter(|v| v.is_finite())
}

fn get(row: &Row, key: &str) -> Option<f64> {
    match row.get(key)? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => number(s),
        _ => None,
    }
}

// ── Feature engineering (fit_sleep_score.engineer + fit_scores_all.engineer_seq) ──

/// Local clock hour of an ISO-8601 timestamp ("2024-03-10T23:12:00+01:00"), read
/// from the timestamp's own wall-clock fields, as Python's `fromisoformat` does.
fn clock_hour(ts: &str) -> Option<f64> {
    let t = ts.trim();
    let time = t.get(11..19)?;
    let mut parts = time.split(':');
    let h: f64 = parts.next()?.parse().ok()?;
    let m: f64 = parts.next()?.parse().ok()?;
    let s: f64 = parts.next()?.parse().ok()?;
    (t.as_bytes().get(10) == Some(&b'T') || t.as_bytes().get(10) == Some(&b' '))
        .then_some(h + m / 60.0 + s / 3600.0)
}

/// Absolute seconds of an ISO-8601 timestamp, for the bedtime midpoint.
fn epoch_seconds(ts: &str) -> Option<f64> {
    let t = ts.trim();
    let y: i64 = t.get(0..4)?.parse().ok()?;
    let mo: u32 = t.get(5..7)?.parse().ok()?;
    let d: u32 = t.get(8..10)?.parse().ok()?;
    let local = crate::days_from_civil(y, mo, d) as f64 * 86_400.0 + clock_hour(t)? * 3600.0;
    // The offset, if any, after the seconds (and optional fraction).
    let rest = t.get(19..).unwrap_or("");
    let rest = rest.trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    let offset = if rest.starts_with('Z') || rest.is_empty() {
        0.0
    } else {
        let sign = if rest.starts_with('-') { -1.0 } else { 1.0 };
        let hh: f64 = rest.get(1..3)?.parse().ok()?;
        let mm: f64 = rest.get(4..6).and_then(|v| v.parse().ok()).unwrap_or(0.0);
        sign * (hh * 3600.0 + mm * 60.0)
    };
    Some(local - offset)
}

/// Midpoint hour wrapped to 24-30 for small hours (03:00 → 27.0), as calibrated.
pub fn wrapped_hour(hour: f64) -> f64 {
    if hour < 12.0 {
        hour + 24.0
    } else {
        hour
    }
}

/// Circular distance between clock hours.
pub fn clock_distance(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(24.0);
    d.min(24.0 - d)
}

/// Circular mean of clock hours, `[0, 24)`.
pub fn clock_mean(hours: &[f64]) -> Option<f64> {
    if hours.is_empty() {
        return None;
    }
    let (s, c) = hours.iter().fold((0.0, 0.0), |(s, c), h| {
        let a = h * std::f64::consts::PI / 12.0;
        (s + a.sin(), c + a.cos())
    });
    Some((s.atan2(c) * 12.0 / std::f64::consts::PI).rem_euclid(24.0))
}

fn engineer(rows: &mut [Row]) {
    rows.sort_by(|a, b| {
        let d = |r: &Row| r.get("date").and_then(Value::as_str).unwrap_or("").to_string();
        d(a).cmp(&d(b))
    });
    let mut mids: Vec<Option<f64>> = Vec::new();
    for r in rows.iter_mut() {
        let start = r.get("Bedtime Start").and_then(Value::as_str).map(str::to_string);
        let end = r.get("Bedtime End").and_then(Value::as_str).map(str::to_string);
        let mid = match (start.as_deref().and_then(epoch_seconds), end.as_deref().and_then(epoch_seconds),
                         start.as_deref().and_then(clock_hour)) {
            (Some(s), Some(e), Some(start_hour)) if e > s => {
                Some(wrapped_hour((start_hour + (e - s) / 7200.0).rem_euclid(24.0)))
            }
            _ => None,
        };
        let previous: Vec<f64> = mids.iter().rev().take(7).flatten().copied().collect();
        if let Some(h) = mid {
            r.insert("mid_hour".into(), json!(h));
            r.insert("mid_opt".into(), json!(-((h - 27.0).powi(2))));
            let reg = clock_mean(&previous)
                .map(|usual| clock_distance(h.rem_euclid(24.0), usual))
                .unwrap_or(0.0);
            r.insert("mid_reg".into(), json!(reg));
        }
        mids.push(mid);
        let awake = get(r, "Awake Time");
        let bed = get(r, "Total Bedtime ")
            .or_else(|| get(r, "Total Bedtime"))
            .or_else(|| Some(awake? + get(r, "Total Sleep Duration")?));
        if let (Some(a), Some(b)) = (awake, bed) {
            if b > 0.0 {
                r.insert("awake_frac".into(), json!(a / b));
            }
        }
    }
    // Timing and regularity: distance from the usual (28-night circular mean)
    // midpoint, and the spread of the past week's midpoints.
    let mut mids: Vec<Option<f64>> = Vec::new();
    for r in rows.iter_mut() {
        let h = get(r, "mid_hour");
        if let Some(h) = h {
            let usual: Vec<f64> = mids.iter().rev().take(28).flatten().map(|m| m.rem_euclid(24.0)).collect();
            if usual.len() >= 5 {
                if let Some(u) = clock_mean(&usual) {
                    r.insert("dist_usual".into(), json!(clock_distance(h.rem_euclid(24.0), u)));
                }
            }
            let week: Vec<f64> = mids.iter().rev().take(7).flatten().copied().collect();
            if week.len() >= 3 {
                r.insert("mid_sd7".into(), json!(std_dev(&[week, vec![h]].concat())));
            }
        }
        mids.push(h);
    }
    // HRV balance: mean of the past week (tonight included) over the past 60 days.
    let mut hrv_hist: Vec<f64> = Vec::new();
    for r in rows.iter_mut() {
        if let Some(x) = get(r, "Average HRV") {
            if hrv_hist.len() >= 20 {
                let week: Vec<f64> = hrv_hist[hrv_hist.len().saturating_sub(6)..].iter().copied().chain([x]).collect();
                let base = &hrv_hist[hrv_hist.len().saturating_sub(60)..];
                let b = base.iter().sum::<f64>() / base.len() as f64;
                if b > 0.0 {
                    r.insert("hrv_ratio".into(), json!(week.iter().sum::<f64>() / week.len() as f64 / b));
                }
            }
            hrv_hist.push(x);
        }
    }
    // lag-1 and causal trailing means
    let mut prev: Option<f64> = None;
    for r in rows.iter_mut() {
        if let Some(p) = prev {
            r.insert("prev_Average MET".into(), json!(p));
        }
        prev = get(r, "Average MET");
    }
    for base in ["Average HRV", "Average Resting Heart Rate", "Total Sleep Duration", "Average MET"] {
        let mut hist: Vec<f64> = Vec::new();
        for r in rows.iter_mut() {
            if !hist.is_empty() {
                let tail = &hist[hist.len().saturating_sub(14)..];
                r.insert(format!("trail14_{base}"), json!(tail.iter().sum::<f64>() / tail.len() as f64));
            }
            if let Some(v) = get(r, base) {
                hist.push(v);
            }
        }
    }
}

// ── Curves ───────────────────────────────────────────────────────────────────

/// Pool-adjacent-violators: the nearest non-decreasing fit to `y`.
fn pav(y: &[f64]) -> Vec<f64> {
    let mut blocks: Vec<(f64, f64, usize)> = Vec::new(); // (value, weight, count)
    for &v in y {
        let (mut value, mut weight, mut count) = (v, 1.0, 1);
        while let Some(&(pv, pw, pc)) = blocks.last() {
            if pv <= value {
                break;
            }
            blocks.pop();
            value = (value * weight + pv * pw) / (weight + pw);
            weight += pw;
            count += pc;
        }
        blocks.push((value, weight, count));
    }
    blocks.into_iter().flat_map(|(v, _, c)| std::iter::repeat_n(v, c)).collect()
}

/// Population standard deviation (numpy's default).
pub fn std_dev(v: &[f64]) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    let m = v.iter().sum::<f64>() / v.len() as f64;
    (v.iter().map(|x| (x - m).powi(2)).sum::<f64>() / v.len() as f64).sqrt()
}

fn mean(v: &[f64]) -> f64 {
    v.iter().sum::<f64>() / v.len() as f64
}

fn correlation(x: &[f64], y: &[f64]) -> f64 {
    let (mx, my) = (mean(x), mean(y));
    let (mut sxy, mut sxx, mut syy) = (0.0, 0.0, 0.0);
    for (a, b) in x.iter().zip(y) {
        sxy += (a - mx) * (b - my);
        sxx += (a - mx).powi(2);
        syy += (b - my).powi(2);
    }
    if sxx == 0.0 || syy == 0.0 {
        0.0
    } else {
        sxy / (sxx * syy).sqrt()
    }
}

/// `numpy.quantile` with linear interpolation, on sorted data.
fn quantile(sorted: &[f64], q: f64) -> f64 {
    let pos = q * (sorted.len() - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo as f64)
}

/// Least squares with an intercept (last coefficient), via the normal equations.
/// A tiny ridge keeps a degenerate driver from making the system singular.
fn least_squares(x: &[Vec<f64>], y: &[f64]) -> Option<Vec<f64>> {
    let k = x.first()?.len() + 1;
    let mut a = vec![vec![0.0; k + 1]; k];
    for (row, &target) in x.iter().zip(y) {
        let mut feats = row.clone();
        feats.push(1.0);
        for i in 0..k {
            for j in 0..k {
                a[i][j] += feats[i] * feats[j];
            }
            a[i][k] += feats[i] * target;
        }
    }
    for (i, row) in a.iter_mut().enumerate().take(k - 1) {
        row[i] += 1e-9 * (1.0 + row[i].abs());
    }
    for col in 0..k {
        let pivot = (col..k).max_by(|&i, &j| a[i][col].abs().total_cmp(&a[j][col].abs()))?;
        if a[pivot][col].abs() < 1e-12 {
            return None;
        }
        a.swap(col, pivot);
        for r in 0..k {
            if r != col {
                let f = a[r][col] / a[col][col];
                for c in col..=k {
                    a[r][c] -= f * a[col][c];
                }
            }
        }
    }
    Some((0..k).map(|i| a[i][k] / a[i][i]).collect())
}

fn fit(kind: Kind, x: &[Vec<f64>], y: &[f64]) -> Option<Value> {
    match kind {
        Kind::Mean => Some(json!({ "kind": "mean", "v": mean(y) })),
        Kind::Mono => {
            let raw: Vec<f64> = x.iter().map(|r| r[0]).collect();
            let sign = if correlation(&raw, y) < 0.0 { -1.0 } else { 1.0 };
            let mut pairs: Vec<(f64, f64)> = raw.iter().map(|v| sign * v).zip(y.iter().copied()).collect();
            pairs.sort_by(|a, b| a.0.total_cmp(&b.0));
            let xs: Vec<f64> = pairs.iter().map(|p| p.0).collect();
            let ys = pav(&pairs.iter().map(|p| p.1).collect::<Vec<_>>());
            Some(json!({ "kind": "mono", "sign": sign, "xs": xs, "ys": ys }))
        }
        Kind::Emp => {
            let raw: Vec<f64> = x.iter().map(|r| r[0]).collect();
            let mut sorted = raw.clone();
            sorted.sort_by(|a, b| a.total_cmp(b));
            let mut edges: Vec<f64> = (0..=24).map(|i| quantile(&sorted, i as f64 / 24.0)).collect();
            edges.dedup();
            let (mut xs, mut ys) = (Vec::new(), Vec::new());
            for w in edges.windows(2) {
                let members: Vec<usize> =
                    (0..raw.len()).filter(|&i| raw[i] >= w[0] && raw[i] <= w[1]).collect();
                if !members.is_empty() {
                    xs.push(members.iter().map(|&i| raw[i]).sum::<f64>() / members.len() as f64);
                    ys.push(members.iter().map(|&i| y[i]).sum::<f64>() / members.len() as f64);
                }
            }
            (!xs.is_empty()).then(|| json!({ "kind": "emp", "xs": xs, "ys": ys }))
        }
        Kind::Lin => least_squares(x, y).map(|b| json!({ "kind": "lin", "b": b })),
    }
}

/// `numpy.interp`: clamped linear interpolation over non-decreasing `xs`.
fn interp(xs: &[f64], ys: &[f64], x: f64) -> f64 {
    let upper = xs.partition_point(|v| *v <= x);
    if upper == 0 {
        return ys[0];
    }
    if upper == xs.len() {
        return ys[ys.len() - 1];
    }
    let (x0, x1, y0, y1) = (xs[upper - 1], xs[upper], ys[upper - 1], ys[upper]);
    if x1 <= x0 {
        y0
    } else {
        y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    }
}

fn floats(v: &Value) -> Vec<f64> {
    v.as_array().map(|a| a.iter().filter_map(Value::as_f64).collect()).unwrap_or_default()
}

/// One contributor's 0-100 sub-score from its fitted curve; `None` drivers fall
/// back to the fitted constant or 50, exactly like the Python scorer.
fn sub_score(spec: Option<&Value>, metrics: &HashMap<&str, f64>) -> f64 {
    let Some(spec) = spec else { return 50.0 };
    let curve = &spec["curve"];
    let drivers: Vec<&str> = spec["drivers"]
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let driver = |i: usize| drivers.get(i).and_then(|d| metrics.get(d)).copied();
    let raw = match curve["kind"].as_str() {
        Some("mean") => curve["v"].as_f64(),
        Some("mono") => {
            let (xs, ys) = (floats(&curve["xs"]), floats(&curve["ys"]));
            let sign = curve["sign"].as_f64().unwrap_or(1.0);
            driver(0).filter(|_| !xs.is_empty() && xs.len() == ys.len()).map(|x| interp(&xs, &ys, sign * x))
        }
        Some("emp") => {
            let (xs, ys) = (floats(&curve["xs"]), floats(&curve["ys"]));
            driver(0).filter(|_| !xs.is_empty() && xs.len() == ys.len()).map(|x| interp(&xs, &ys, x))
        }
        Some("lin") => {
            let b = floats(&curve["b"]);
            (b.len() == drivers.len() + 1)
                .then(|| (0..drivers.len()).map(driver).collect::<Option<Vec<f64>>>())
                .flatten()
                .map(|values| values.iter().zip(&b).map(|(x, c)| x * c).sum::<f64>() + b[b.len() - 1])
        }
        _ => None,
    };
    raw.unwrap_or(50.0).clamp(1.0, 100.0)
}

/// Contributor keys shared with the app's labels.
fn component_key(contributor: &str) -> &'static str {
    match contributor {
        "Total Sleep Score" => "total_sleep",
        "Restfulness Score" => "restfulness",
        "Sleep Efficiency Score" => "efficiency",
        "REM Sleep Score" => "rem_sleep",
        "Deep Sleep Score" => "deep_sleep",
        "Sleep Latency Score" => "latency",
        "Sleep Timin Score" => "timing",
        "Resting Heart Rate Score" => "resting_hr",
        "Previous Night Score" => "previous_night",
        "HRV Balance Score" => "hrv_balance",
        "Temperature Score" => "temperature",
        "Sleep Balance Score" => "sleep_balance",
        "Previous Day Activity Score" => "previous_day_activity",
        "Recovery Index Score" => "recovery_index",
        "Activity Balance Score" => "activity_balance",
        "Sleep Regularity Score" => "sleep_regularity",
        _ => "other",
    }
}

/// Score `score_name` from raw metrics with a calibration's `params`, in the same
/// JSON shape as the other scores, or `Null` when the calibration lacks it.
pub fn score(params: &Value, score_name: &str, metrics: &HashMap<&str, f64>, provisional: bool) -> Value {
    let Some(weights) = params["weights"][score_name].as_object() else { return Value::Null };
    let contributors = &params["contributors"];
    if !weights.keys().any(|c| contributors.get(c).is_some()) {
        return Value::Null;
    }
    let mut parts: Vec<(&str, f64, f64)> = weights
        .iter()
        .filter_map(|(c, w)| w.as_f64().map(|w| (c.as_str(), w)))
        .map(|(c, w)| (c, sub_score(contributors.get(c), metrics), w))
        .collect();
    parts.sort_by(|a, b| b.2.total_cmp(&a.2));
    let total: f64 = parts.iter().map(|p| p.1 * p.2 / 100.0).sum();
    json!({
        "score": total.round().clamp(0.0, 100.0),
        "components": parts.iter().map(|(c, s, w)| json!({
            "key": component_key(c),
            "score": s.round(),
            "weight": w / 100.0,
        })).collect::<Vec<_>>(),
        "basis": "oura-calibrated",
        "provisional": provisional,
    })
}

// ── Import ───────────────────────────────────────────────────────────────────

fn ymd_of(raw: &str) -> Option<String> {
    let t = raw.trim();
    let d = t.get(0..10)?;
    (d.as_bytes()[4] == b'-' && d.as_bytes()[7] == b'-').then(|| d.to_string())
}

/// Parse, calibrate and store a single-file export (the older trends CSV, or any one
/// file of the newer layout). Returns what was imported, for display.
pub fn import(db: &Path, csv_text: &str) -> Result<Value> {
    import_files(db, &[("export.csv".to_string(), csv_text.to_string())])
}

/// One file of the newer per-type export, recognised by its columns.
#[derive(Clone, Copy, PartialEq, Debug)]
enum V2Kind {
    DailySleep,
    DailyReadiness,
    SleepPeriods,
    DailyActivity,
    DailySpo2,
}

fn v2_kind(header: &[String]) -> Option<V2Kind> {
    let has = |c: &str| header.iter().any(|h| h == c);
    if !has("day") {
        return None;
    }
    if has("total_sleep_duration") && has("bedtime_start") {
        Some(V2Kind::SleepPeriods)
    } else if has("contributors") && has("temperature_deviation") {
        Some(V2Kind::DailyReadiness)
    } else if has("contributors") && has("active_calories") {
        Some(V2Kind::DailyActivity)
    } else if has("spo2_percentage") {
        Some(V2Kind::DailySpo2)
    } else if has("contributors") && has("score") && header.len() <= 6 {
        Some(V2Kind::DailySleep)
    } else {
        None
    }
}

const V2_SLEEP_CONTRIBUTORS: &[(&str, &str)] = &[
    ("total_sleep", "Total Sleep Score"),
    ("restfulness", "Restfulness Score"),
    ("efficiency", "Sleep Efficiency Score"),
    ("rem_sleep", "REM Sleep Score"),
    ("deep_sleep", "Deep Sleep Score"),
    ("latency", "Sleep Latency Score"),
    ("timing", "Sleep Timin Score"),
];
const V2_READINESS_CONTRIBUTORS: &[(&str, &str)] = &[
    ("resting_heart_rate", "Resting Heart Rate Score"),
    ("previous_night", "Previous Night Score"),
    ("hrv_balance", "HRV Balance Score"),
    ("body_temperature", "Temperature Score"),
    ("sleep_balance", "Sleep Balance Score"),
    ("previous_day_activity", "Previous Day Activity Score"),
    ("recovery_index", "Recovery Index Score"),
    ("activity_balance", "Activity Balance Score"),
    ("sleep_regularity", "Sleep Regularity Score"),
];

/// Hours from a night's lowest heart rate (median of 5 consecutive 5-minute samples,
/// as `readiness::recovery_index_h` does on ring data) to the end of the night, and
/// where in the night that low fell (0 = start, 1 = end).
fn recovery_from_curve(curve: &Value) -> Option<(f64, f64)> {
    let step = curve["interval"].as_f64().unwrap_or(300.0);
    let items = curve["items"].as_array()?;
    let present: Vec<(usize, f64)> =
        items.iter().enumerate().filter_map(|(i, v)| v.as_f64().map(|x| (i, x))).collect();
    if present.len() < 12 {
        return None;
    }
    let lowest = present
        .windows(5)
        .map(|w| {
            let mut v: Vec<f64> = w.iter().map(|p| p.1).collect();
            v.sort_by(|a, b| a.total_cmp(b));
            (w[2].0, v[2])
        })
        .min_by(|a, b| a.1.total_cmp(&b.1))?;
    let hours = (items.len() - lowest.0) as f64 * step / 3600.0;
    let night_hours = items.len() as f64 * step / 3600.0;
    Some((hours, 1.0 - hours / night_hours))
}

/// Merge the newer export's files into one row per day, using the trends export's
/// column names so the rest of the pipeline is shared.
fn merge_v2(tables: &[(V2Kind, Vec<Row>)]) -> Vec<Row> {
    let mut days: BTreeMap<String, Row> = BTreeMap::new();
    let s = |r: &Row, k: &str| r.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    for (kind, rows) in tables {
        for r in rows {
            let Some(day) = ymd_of(&s(r, "day")) else { continue };
            let entry = days.entry(day.clone()).or_insert_with(|| Row::from([("date".to_string(), json!(day))]));
            let mut put = |key: &str, v: Option<f64>| {
                if let Some(v) = v {
                    entry.insert(key.to_string(), json!(v));
                }
            };
            let contributors = |r: &Row| -> Value {
                serde_json::from_str(&s(r, "contributors")).unwrap_or(Value::Null)
            };
            match kind {
                V2Kind::DailySleep => {
                    put("Sleep Score", get(r, "score"));
                    let c = contributors(r);
                    for (k, col) in V2_SLEEP_CONTRIBUTORS {
                        put(col, c[*k].as_f64());
                    }
                }
                V2Kind::DailyReadiness => {
                    put("Readiness Score", get(r, "score"));
                    put("Temperature Deviation (°C)", get(r, "temperature_deviation"));
                    let c = contributors(r);
                    for (k, col) in V2_READINESS_CONTRIBUTORS {
                        put(col, c[*k].as_f64());
                    }
                }
                V2Kind::DailyActivity => {
                    put("Activity Score", get(r, "score"));
                    put("Average MET", get(r, "average_met_minutes"));
                    put("Steps", get(r, "steps"));
                    put("Active Calories", get(r, "active_calories"));
                }
                V2Kind::DailySpo2 => {
                    let v: Value = serde_json::from_str(&s(r, "spo2_percentage")).unwrap_or(Value::Null);
                    put("SpO2 Average", v["average"].as_f64());
                }
                V2Kind::SleepPeriods => {}
            }
        }
    }
    // Sleep periods: the day's main sleep is its longest "long_sleep" in bed.
    let mut main: BTreeMap<String, &Row> = BTreeMap::new();
    for (kind, rows) in tables {
        if *kind != V2Kind::SleepPeriods {
            continue;
        }
        for r in rows {
            if s(r, "type") != "long_sleep" {
                continue;
            }
            let Some(day) = ymd_of(&s(r, "day")) else { continue };
            let longer = main.get(&day).map_or(true, |m| get(r, "time_in_bed") > get(m, "time_in_bed"));
            if longer {
                main.insert(day, r);
            }
        }
    }
    for (day, r) in main {
        let entry = days.entry(day.clone()).or_insert_with(|| Row::from([("date".to_string(), json!(day))]));
        for (from, to) in [
            ("total_sleep_duration", "Total Sleep Duration"),
            ("efficiency", "Sleep Efficiency"),
            ("rem_sleep_duration", "REM Sleep Duration"),
            ("deep_sleep_duration", "Deep Sleep Duration"),
            ("latency", "Sleep Latency"),
            ("awake_time", "Awake Time"),
            ("time_in_bed", "Total Bedtime"),
            ("lowest_heart_rate", "Lowest Resting Heart Rate"),
            ("average_heart_rate", "Average Resting Heart Rate"),
            ("average_hrv", "Average HRV"),
            ("average_breath", "Average Breath"),
        ] {
            if let Some(v) = get(r, from) {
                entry.insert(to.to_string(), json!(v));
            }
        }
        entry.insert("Bedtime Start".into(), json!(s(r, "bedtime_start")));
        entry.insert("Bedtime End".into(), json!(s(r, "bedtime_end")));
        let curve: Value = serde_json::from_str(&s(r, "heart_rate")).unwrap_or(Value::Null);
        if let Some((hours, frac)) = recovery_from_curve(&curve) {
            entry.insert("rec_h".into(), json!(hours));
            entry.insert("low_frac".into(), json!(frac));
        }
    }
    days.into_values().collect()
}

fn table_rows(table: &[Vec<String>]) -> Vec<Row> {
    let header = &table[0];
    table[1..]
        .iter()
        .map(|cells| {
            header
                .iter()
                .zip(cells.iter().chain(std::iter::repeat(&String::new())))
                .map(|(h, v)| (h.clone(), Value::String(v.clone())))
                .collect()
        })
        .collect()
}

/// Parse, calibrate and store an export given as one or more files
/// (`(file name, contents)`). Files that aren't part of a recognised export are
/// skipped; it is an error only when nothing usable is found.
pub fn import_files(db: &Path, files: &[(String, String)]) -> Result<Value> {
    let known: Vec<&str> = HISTORY_COLUMNS.iter().map(|(c, _)| *c).collect();
    let mut trends: Vec<Row> = Vec::new();
    let mut v2: Vec<(V2Kind, Vec<Row>)> = Vec::new();
    let mut unrecognised: Vec<String> = Vec::new();
    for (name, text) in files {
        let table = parse_csv(text);
        let Some(header) = table.first() else {
            unrecognised.push(format!("{name} (empty)"));
            continue;
        };
        if let Some(kind) = v2_kind(header) {
            v2.push((kind, table_rows(&table)));
        } else if header.iter().any(|h| h == "date") && header.iter().any(|h| known.contains(&h.as_str())) {
            trends.extend(table_rows(&table));
        } else {
            unrecognised.push(format!(
                "{name} (columns: {})",
                header.iter().take(12).cloned().collect::<Vec<_>>().join(", ")
            ));
        }
    }
    let (mut rows, source) = if !v2.is_empty() {
        (merge_v2(&v2), "Oura data export")
    } else {
        (trends, "Oura trends export")
    };
    rows.retain(|r| r.get("date").and_then(Value::as_str).and_then(ymd_of).is_some());
    if rows.is_empty() {
        if files.len() == 1 && files[0].1.trim().is_empty() {
            return Err(anyhow!("the file is empty"));
        }
        return Err(anyhow!(
            "no Oura export data was recognised. Pick dailysleep.csv, dailyreadiness.csv, \
sleepmodel.csv and dailyactivity.csv from the export (or its trends CSV). Not used: {}",
            unrecognised.join("; ")
        ));
    }
    calibrate_and_store(db, rows, source)
}

/// Least-squares weights of a score over its contributor sub-scores, in percent,
/// used only when they reproduce the score closely and none is negative.
fn fitted_weights(rows: &[Row], score_name: &str, defaults: &[(&str, f64)]) -> Option<Map<String, Value>> {
    let present: Vec<&str> = defaults
        .iter()
        .map(|(c, _)| *c)
        .filter(|c| rows.iter().filter(|r| get(r, c).is_some()).count() >= 30)
        .collect();
    let usable: Vec<&Row> = rows
        .iter()
        .filter(|r| get(r, score_name).is_some() && present.iter().all(|c| get(r, c).is_some()))
        .collect();
    if present.len() < 3 || usable.len() < 30 {
        return None;
    }
    let x: Vec<Vec<f64>> = usable.iter().map(|r| present.iter().map(|c| get(r, c).unwrap()).collect()).collect();
    let y: Vec<f64> = usable.iter().map(|r| get(r, score_name).unwrap()).collect();
    // No intercept: append a zero column, then drop its coefficient.
    let with_zero: Vec<Vec<f64>> = x.iter().map(|row| row.clone()).collect();
    let b = least_squares_no_intercept(&with_zero, &y)?;
    if b.iter().any(|w| *w < -0.005) {
        return None;
    }
    let mae = x.iter().zip(&y).map(|(row, t)| (row.iter().zip(&b).map(|(v, w)| v * w).sum::<f64>() - t).abs()).sum::<f64>()
        / y.len() as f64;
    if mae > 2.5 {
        return None;
    }
    Some(present.iter().zip(&b).map(|(c, w)| ((*c).to_string(), json!((w.max(0.0) * 1000.0).round() / 10.0))).collect())
}

/// Ordinary least squares through the origin, via the normal equations.
fn least_squares_no_intercept(x: &[Vec<f64>], y: &[f64]) -> Option<Vec<f64>> {
    let k = x.first()?.len();
    let mut a = vec![vec![0.0; k]; k];
    let mut v = vec![0.0; k];
    for (row, t) in x.iter().zip(y) {
        for i in 0..k {
            v[i] += row[i] * t;
            for j in 0..k {
                a[i][j] += row[i] * row[j];
            }
        }
    }
    for (i, r) in a.iter_mut().enumerate() {
        r[i] += 1e-6;
    }
    // Gaussian elimination with partial pivoting.
    for col in 0..k {
        let pivot = (col..k).max_by(|&p, &q| a[p][col].abs().total_cmp(&a[q][col].abs()))?;
        a.swap(col, pivot);
        v.swap(col, pivot);
        if a[col][col].abs() < 1e-12 {
            return None;
        }
        for row in col + 1..k {
            let f = a[row][col] / a[col][col];
            for c in col..k {
                a[row][c] -= f * a[col][c];
            }
            v[row] -= f * v[col];
        }
    }
    let mut b = vec![0.0; k];
    for i in (0..k).rev() {
        b[i] = (v[i] - (i + 1..k).map(|j| a[i][j] * b[j]).sum::<f64>()) / a[i][i];
    }
    Some(b)
}

/// Fit one contributor from `rows`; when its drivers aren't in the export, fall
/// back to the contributor's average so it still counts at its usual level.
fn fit_contributor(rows: &[Row], contributor: &str, drivers: &[&str], kind: Kind) -> Option<(Value, usize)> {
    let recent = RECENT_ONLY.iter().find(|(c, _)| *c == contributor).map(|(_, n)| *n);
    let mut x: Vec<Vec<f64>> = Vec::new();
    let mut y: Vec<f64> = Vec::new();
    for r in rows {
        let Some(target) = get(r, contributor) else { continue };
        let Some(values) = drivers.iter().map(|d| get(r, d)).collect::<Option<Vec<f64>>>() else {
            continue;
        };
        x.push(values);
        y.push(target);
    }
    if let Some(n) = recent {
        let skip = y.len().saturating_sub(n);
        x.drain(..skip);
        y.drain(..skip);
    }
    if y.len() >= 20 && !drivers.is_empty() {
        let curve = fit(kind, &x, &y)?;
        return Some((json!({ "drivers": drivers, "kind": kind.name(), "curve": curve }), y.len()));
    }
    let targets: Vec<f64> = rows.iter().filter_map(|r| get(r, contributor)).collect();
    (targets.len() >= 20).then(|| {
        (json!({ "drivers": [], "kind": "mean", "curve": { "kind": "mean", "v": mean(&targets) } }), targets.len())
    })
}

fn calibrate_and_store(db: &Path, mut rows: Vec<Row>, source: &str) -> Result<Value> {
    engineer(&mut rows);

    // calibration
    let mut weights = Map::new();
    for (score_name, list) in WEIGHTS {
        let fitted = fitted_weights(&rows, score_name, list);
        let m: Map<String, Value> = fitted.unwrap_or_else(|| {
            list.iter().filter(|(_, w)| *w > 0.0).map(|(c, w)| ((*c).to_string(), json!(w))).collect()
        });
        weights.insert((*score_name).to_string(), Value::Object(m));
    }
    let mut contributors = Map::new();
    let mut days_used = 0;
    for (contributor, drivers, kind) in DRIVERS {
        if let Some((spec, n)) = fit_contributor(&rows, contributor, drivers, *kind) {
            contributors.insert((*contributor).to_string(), spec);
            days_used = days_used.max(n);
        }
    }
    let covers = |score_name: &str| {
        weights[score_name].as_object().is_some_and(|w| w.keys().any(|c| contributors.contains_key(c)))
    };
    let calibrated = json!({ "sleep": covers(SLEEP), "readiness": covers(READINESS) });

    // history
    let mut history: BTreeMap<String, Value> = BTreeMap::new();
    for r in &rows {
        let Some(day) = r.get("date").and_then(Value::as_str).and_then(ymd_of) else { continue };
        let mut entry = Map::new();
        for (column, key) in HISTORY_COLUMNS {
            if entry.contains_key(*key) {
                continue;
            }
            if let Some(v) = get(r, column) {
                entry.insert((*key).to_string(), json!(v));
            }
        }
        if !entry.is_empty() {
            history.insert(day, Value::Object(entry));
        }
    }
    let first = history.keys().next().cloned();
    let last = history.keys().next_back().cloned();

    let stored = json!({
        "source": source,
        "imported_rows": rows.len(),
        "first": first,
        "last": last,
        "days": history.len(),
        "calibrated": calibrated,
        "history": history,
        "params": {
            "source": source,
            "n_days": days_used,
            "weights": weights,
            "contributors": contributors,
        },
    });
    let out = path(db);
    let tmp = out.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(&stored)?).context("saving the import")?;
    std::fs::rename(&tmp, &out).context("saving the import")?;
    Ok(json!({
        "days": stored["days"],
        "first": stored["first"],
        "last": stored["last"],
        "calibrated": calibrated,
        "calibration_days": days_used,
        "source": source,
    }))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A synthetic trends export whose sub-scores follow known rules, so the fitted
    /// curves can be checked against them.
    pub(crate) fn synthetic_export(days: usize) -> String {
        let mut out = String::from(
            "date,Sleep Score,Readiness Score,Total Sleep Duration,Sleep Efficiency,REM Sleep Duration,\
Deep Sleep Duration,Sleep Latency,Awake Time,Bedtime Start,Bedtime End,Total Sleep Score,\
Sleep Efficiency Score,REM Sleep Score,Deep Sleep Score,Sleep Latency Score,Restfulness Score,\
Sleep Timin Score,Lowest Resting Heart Rate,Average Resting Heart Rate,Average HRV,\
Temperature Deviation (°C),Average MET,Steps,Activity Burn,Previous Night Score,\
Resting Heart Rate Score,HRV Balance Score,Temperature Score,Sleep Balance Score,\
Previous Day Activity Score,Recovery Index Score,Activity Balance Score\n",
        );
        for i in 0..days {
            let f = i as f64;
            let total = 21_600.0 + (f * 37.0) % 7_200.0; // 6–8 h
            let total_score = (total / 28_800.0 * 100.0).min(100.0);
            let eff = 80.0 + (f * 3.0) % 15.0;
            let hrv = 40.0 + (f * 7.0) % 30.0;
            let day = 1 + i % 28;
            let month = 1 + (i / 28) % 12;
            out.push_str(&format!(
                "2025-{month:02}-{day:02},{s},{r},{total},{eff},{rem},{deep},{lat},{awake},\
2025-{month:02}-{day:02}T23:10:00+01:00,2025-{month:02}-{day:02}T23:10:00+01:00,{ts},{es},{remsc},{deepsc},90,70,85,\
50,55,{hrv},0.1,1.5,{steps},300,{s},80,{hrvsc},95,85,80,88,82\n",
                s = (total_score * 0.6 + 30.0).round(),
                r = 80,
                rem = total * 0.2,
                deep = total * 0.15,
                lat = 600,
                awake = 1800,
                ts = total_score.round(),
                es = eff.round(),
                remsc = (total * 0.2 / 72.0).min(100.0).round(),
                deepsc = (total * 0.15 / 54.0).min(100.0).round(),
                hrvsc = (hrv + 30.0).min(100.0),
                steps = 6000 + i * 13,
            ));
        }
        out
    }

    fn temp_db(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("oura-export-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("oura.db")
    }

    #[test]
    fn csv_handles_quotes_and_crlf() {
        let rows = parse_csv("a,b\r\n\"1,5\",\"say \"\"hi\"\"\"\r\n3,\n");
        assert_eq!(rows, vec![vec!["a", "b"], vec!["1,5", "say \"hi\""], vec!["3", ""]]);
    }

    #[test]
    fn pav_and_quantile_match_numpy() {
        assert_eq!(pav(&[1.0, 3.0, 2.0, 4.0]), vec![1.0, 2.5, 2.5, 4.0]);
        assert_eq!(quantile(&[1.0, 2.0, 3.0, 4.0], 0.5), 2.5);
        let b = least_squares(&[vec![1.0], vec![2.0], vec![3.0]], &[3.0, 5.0, 7.0]).unwrap();
        assert!((b[0] - 2.0).abs() < 1e-6 && (b[1] - 1.0).abs() < 1e-6, "{b:?}");
    }

    #[test]
    fn timestamps_and_midpoints() {
        assert_eq!(clock_hour("2025-01-01T23:30:00+01:00"), Some(23.5));
        let a = epoch_seconds("2025-01-01T23:00:00+01:00").unwrap();
        let b = epoch_seconds("2025-01-02T07:00:00+01:00").unwrap();
        assert_eq!(b - a, 8.0 * 3600.0);
        assert_eq!(wrapped_hour(3.0), 27.0);
        assert_eq!(clock_distance(23.0, 1.0), 2.0);
    }

    #[test]
    fn imports_calibrates_and_scores() {
        let db = temp_db("import");
        let result = import(&db, &synthetic_export(120)).unwrap();
        assert_eq!(result["days"], 120);
        assert_eq!(result["calibrated"]["sleep"], true);
        assert_eq!(result["calibrated"]["readiness"], true);

        let stored = load(&db).unwrap();
        assert_eq!(stored["history"]["2025-01-01"]["steps"], 6000.0);
        assert_eq!(stored["history"]["2025-01-01"]["readiness"], 80.0);
        let params = &stored["params"];
        assert_eq!(params["contributors"]["Total Sleep Score"]["curve"]["kind"], "mono");

        // Total sleep was generated as total/8h·100, so 7 h must map close to 87.5.
        let metrics = HashMap::from([("Total Sleep Duration", 25_200.0)]);
        let sub = sub_score(params["contributors"].get("Total Sleep Score"), &metrics);
        assert!((sub - 87.5).abs() < 1.5, "{sub}");

        let scored = score(params, SLEEP, &HashMap::new(), false);
        assert_eq!(scored["basis"], "oura-calibrated");
        assert_eq!(scored["components"].as_array().unwrap().len(), 7);
        assert_eq!(scored["components"][0]["key"], "total_sleep");

        clear(&db).unwrap();
        assert!(load(&db).is_none());
    }

    /// A small export in the newer per-type layout: semicolons, JSON contributors,
    /// a nap alongside each main sleep, and an unrelated file that must be skipped.
    fn synthetic_v2(days: usize) -> Vec<(String, String)> {
        let mut sleep = String::from("id;contributors;day;score;timestamp\n");
        let mut ready = String::from("id;contributors;day;score;temperature_deviation;temperature_trend_deviation;timestamp\n");
        let mut periods = String::from("id;average_breath;average_heart_rate;average_hrv;awake_time;bedtime_end;bedtime_start;day;deep_sleep_duration;efficiency;heart_rate;latency;lowest_heart_rate;rem_sleep_duration;time_in_bed;total_sleep_duration;type\n");
        let mut activity = String::from("id;active_calories;average_met_minutes;contributors;day;score;steps\n");
        for i in 0..days {
            let day = format!("2025-{:02}-{:02}", 1 + (i / 28) % 12, 1 + i % 28);
            let f = i as f64;
            let total = 21_600.0 + (f * 37.0) % 7_200.0;
            let ts = (total / 28_800.0 * 100.0).min(100.0).round();
            let eff = 80.0 + (f * 3.0) % 15.0;
            let (rest, rem, deep, lat, tim) = (
                60.0 + (f * 11.0) % 40.0,
                50.0 + (f * 17.0) % 50.0,
                55.0 + (f * 23.0) % 45.0,
                40.0 + (f * 29.0) % 60.0,
                20.0 + (f * 31.0) % 80.0,
            );
            let score = (0.35 * ts + 0.15 * rest + 0.10 * (eff + rem + deep + lat + tim)).round();
            sleep.push_str(&format!(
                "s{i};\"{{\"\"total_sleep\"\": {ts}, \"\"restfulness\"\": {rest}, \"\"efficiency\"\": {eff}, \"\"rem_sleep\"\": {rem}, \"\"deep_sleep\"\": {deep}, \"\"latency\"\": {lat}, \"\"timing\"\": {tim}}}\";{day};{score};{day}T00:00:00.000+00:00\n"
            ));
            let hrv = 40.0 + (f * 7.0) % 30.0;
            let rem_s = total * 0.2;
            ready.push_str(&format!(
                "r{i};\"{{\"\"resting_heart_rate\"\": 85, \"\"previous_night\"\": {score}, \"\"hrv_balance\"\": {hb}, \"\"body_temperature\"\": 95, \"\"sleep_balance\"\": 80, \"\"previous_day_activity\"\": 75, \"\"recovery_index\"\": 90, \"\"activity_balance\"\": 80, \"\"sleep_regularity\"\": 70}}\";{day};80;0.1;0.0;{day}T00:00:00.000+00:00\n",
                hb = (hrv + 30.0).min(100.0)
            ));
            let hr: Vec<String> = (0..96).map(|k| format!("{}", 60.0 - (k as f64 - 40.0).abs() * 0.1)).collect();
            for (kind, start, end, bed) in [("long_sleep", "00:10", "08:10", 28_800.0), ("sleep", "14:00", "14:30", 1_800.0)] {
                periods.push_str(&format!(
                    "p{i}{kind};14.5;55;{hrv};1800;{day}T{end}:00.000-08:00;{day}T{start}:00.000-08:00;{day};{deep};{eff};\"{{\"\"interval\"\": 300.0, \"\"items\"\": [{hr}]}}\";600;50;{rem};{bed};{total};{kind}\n",
                    deep = total * 0.15, rem = rem_s, hr = hr.join(", ")
                ));
            }
            activity.push_str(&format!("a{i};300;1.5;\"{{}}\";{day};80;{}\n", 6000 + i * 13));
        }
        vec![
            ("dailysleep.csv".into(), sleep),
            ("dailyreadiness.csv".into(), ready),
            ("sleepmodel.csv".into(), periods),
            ("dailyactivity.csv".into(), activity),
            ("ringbatterylevel.csv".into(), "id;level;timestamp\nx;90;2025-01-01\n".into()),
        ]
    }

    #[test]
    fn imports_the_per_type_export() {
        let db = temp_db("v2");
        let result = import_files(&db, &synthetic_v2(90)).unwrap();
        assert_eq!(result["days"], 90, "{result}");
        assert_eq!(result["source"], "Oura data export");
        assert_eq!(result["calibrated"]["sleep"], true);
        assert_eq!(result["calibrated"]["readiness"], true);
        let stored = load(&db).unwrap();
        // The main sleep wins over the afternoon nap.
        assert_eq!(stored["history"]["2025-01-01"]["asleep_s"], 21_600.0);
        assert_eq!(stored["history"]["2025-01-01"]["steps"], 6000.0);
        let params = &stored["params"];
        // Sleep weights are learned from the contributors: the generator used 35/15/10…
        let w = &params["weights"][SLEEP];
        assert!((w["Total Sleep Score"].as_f64().unwrap() - 35.0).abs() < 1.0, "{w}");
        // Recovery index is fitted from the heart-rate curves, not held at its average.
        assert_eq!(params["contributors"]["Recovery Index Score"]["kind"], "lin");
        assert_eq!(params["contributors"]["Sleep Timin Score"]["drivers"][0], "dist_usual");
        clear(&db).unwrap();
    }

    #[test]
    fn rejects_other_files_with_a_useful_message() {
        let db = temp_db("reject");
        let err = import(&db, "name,value\nx,1\n").unwrap_err().to_string();
        assert!(err.contains("columns: name, value"), "{err}");
        assert!(import(&db, "").is_err());
    }
}
