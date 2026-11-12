//! Import of an Oura account "trends" export (CSV), done entirely on the device.
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
        ],
    ),
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
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
    ("Sleep Timin Score", &["mid_opt", "mid_reg", "mid_hour"], Kind::Lin),
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
    ("HRV Balance Score", &["Average HRV", "trail14_Average HRV"], Kind::Lin),
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
    ("Recovery Index Score", &[], Kind::Mean),
];

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

/// Minimal RFC 4180 reader: quoted fields, doubled quotes, CRLF or LF.
fn parse_csv(text: &str) -> Vec<Vec<String>> {
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
            ',' => row.push(std::mem::take(&mut field)),
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

/// Parse, calibrate and store an export. Returns what was imported, for display.
pub fn import(db: &Path, csv_text: &str) -> Result<Value> {
    let table = parse_csv(csv_text);
    let header = table.first().ok_or_else(|| anyhow!("the file is empty"))?;
    let header: Vec<String> = header.iter().map(|h| h.to_string()).collect();
    if !header.iter().any(|h| h == "date") {
        return Err(anyhow!(
            "this doesn't look like an Oura trends export (no \"date\" column). Columns found: {}",
            header.iter().take(12).cloned().collect::<Vec<_>>().join(", ")
        ));
    }
    let known: Vec<&str> = HISTORY_COLUMNS.iter().map(|(c, _)| *c).collect();
    if !header.iter().any(|h| known.contains(&h.as_str())) {
        return Err(anyhow!(
            "no score or sleep columns were recognised. Columns found: {}",
            header.iter().take(12).cloned().collect::<Vec<_>>().join(", ")
        ));
    }

    let mut rows: Vec<Row> = table[1..]
        .iter()
        .map(|cells| {
            header
                .iter()
                .zip(cells.iter().chain(std::iter::repeat(&String::new())))
                .map(|(h, v)| (h.clone(), Value::String(v.clone())))
                .collect()
        })
        .collect();
    rows.retain(|r| r.get("date").and_then(Value::as_str).and_then(ymd_of).is_some());
    if rows.is_empty() {
        return Err(anyhow!("the export has no dated rows"));
    }
    engineer(&mut rows);

    // calibration
    let mut weights = Map::new();
    for (score_name, list) in WEIGHTS {
        let mut m = Map::new();
        for (c, w) in *list {
            m.insert((*c).to_string(), json!(w));
        }
        weights.insert((*score_name).to_string(), Value::Object(m));
    }
    let mut contributors = Map::new();
    let mut days_used = 0;
    for (contributor, drivers, kind) in DRIVERS {
        let mut x: Vec<Vec<f64>> = Vec::new();
        let mut y: Vec<f64> = Vec::new();
        for r in &rows {
            let Some(target) = get(r, contributor) else { continue };
            let Some(values) = drivers.iter().map(|d| get(r, d)).collect::<Option<Vec<f64>>>() else {
                continue;
            };
            x.push(values);
            y.push(target);
        }
        if y.len() < 20 {
            continue;
        }
        if let Some(curve) = fit(*kind, &x, &y) {
            contributors.insert(
                (*contributor).to_string(),
                json!({ "drivers": drivers, "kind": kind.name(), "curve": curve }),
            );
            days_used = days_used.max(y.len());
        }
    }
    let covers = |score_name: &str| {
        WEIGHTS
            .iter()
            .find(|(n, _)| *n == score_name)
            .is_some_and(|(_, list)| list.iter().any(|(c, _)| contributors.contains_key(*c)))
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
        "source": "Oura trends export",
        "imported_rows": rows.len(),
        "first": first,
        "last": last,
        "days": history.len(),
        "calibrated": calibrated,
        "history": history,
        "params": {
            "source": "Oura trends export",
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

    #[test]
    fn rejects_other_files_with_a_useful_message() {
        let db = temp_db("reject");
        let err = import(&db, "name,value\nx,1\n").unwrap_err().to_string();
        assert!(err.contains("Columns found: name, value"), "{err}");
        assert!(import(&db, "").is_err());
    }
}
