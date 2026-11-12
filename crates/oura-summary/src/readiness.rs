//! Readiness score: how recovered you look this morning compared with your own
//! recent nights.
//!
//! Oura's combiner weights were recovered by regression (see open_oura's
//! `docs/algorithms/score-weights.md`): resting heart rate 17, previous night 15, HRV
//! balance 15, temperature 13, sleep balance 12, recovery index 10, plus two activity
//! contributors (previous-day activity 10, activity balance 7) that are left out here.
//! Oura's per-contributor curves do not read back from its binary, so the curves below
//! are this project's own, hand-set and unvalidated. When a calibration fitted to the
//! user's Oura export is available, [`crate::calibration`] replaces this estimate.
//!
//! The output has the same shape as [`crate::sleep_score::score_night`]:
//! `{score, components: [{key, score, weight}], basis, provisional}`.

use serde_json::{json, Value};

/// Nights of history a baseline looks back over and needs before it is settled.
pub const MATURE_NIGHTS: usize = 14;
/// Fewest earlier nights before a baseline-relative contributor is used at all.
pub const MIN_BASELINE_NIGHTS: usize = 3;

/// Tonight's values and the trailing personal baselines they are compared with.
/// A `None` baseline means too little history; that contributor drops out.
#[derive(Default, Clone, Copy, Debug)]
pub struct ReadinessInput {
    pub sleep_score: Option<f64>,
    pub lowest_hr: Option<f64>,
    pub baseline_lowest_hr: Option<f64>,
    pub hrv_ms: Option<f64>,
    pub baseline_hrv_ms: Option<f64>,
    pub skin_temp: Option<f64>,
    pub baseline_skin_temp: Option<f64>,
    /// Mean total sleep (seconds) over the trailing nights including this one.
    pub recent_sleep_s: Option<f64>,
    /// Hours between the night's lowest heart rate and waking up.
    pub recovery_index_h: Option<f64>,
    pub history_nights: usize,
}

/// Piecewise-linear through `(x, y)` knots sorted by x, clamped at both ends.
pub(crate) fn curve(x: f64, knots: &[(f64, f64)]) -> f64 {
    if x <= knots[0].0 {
        return knots[0].1;
    }
    for pair in knots.windows(2) {
        let ((x0, y0), (x1, y1)) = (pair[0], pair[1]);
        if x <= x1 {
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
        }
    }
    knots[knots.len() - 1].1
}

/// Total-sleep hours → 0-100, also used for sleep balance.
pub(crate) fn total_sleep_score(seconds: f64) -> f64 {
    curve(
        seconds / 3600.0,
        &[
            (0.0, 0.0),
            (4.0, 20.0),
            (5.0, 40.0),
            (6.0, 60.0),
            (7.0, 80.0),
            (7.75, 95.0),
            (8.5, 100.0),
        ],
    )
}

/// The estimated readiness score, or `Null` with fewer than three contributors
/// (typically the first few nights).
pub fn estimate(input: &ReadinessInput) -> Value {
    let mut parts: Vec<(&str, f64, f64)> = Vec::new();

    if let (Some(hr), Some(base)) = (input.lowest_hr, input.baseline_lowest_hr) {
        let score = curve(
            hr - base,
            &[(0.0, 100.0), (2.0, 85.0), (5.0, 55.0), (8.0, 30.0), (12.0, 0.0)],
        );
        parts.push(("resting_hr", score, 17.0));
    }
    if let Some(score) = input.sleep_score {
        parts.push(("previous_night", score, 15.0));
    }
    if let (Some(hrv), Some(base)) = (input.hrv_ms, input.baseline_hrv_ms) {
        if base > 0.0 {
            let score = curve(
                hrv / base,
                &[(0.4, 0.0), (0.6, 30.0), (0.8, 65.0), (0.9, 85.0), (1.0, 100.0)],
            );
            parts.push(("hrv_balance", score, 15.0));
        }
    }
    if let (Some(temp), Some(base)) = (input.skin_temp, input.baseline_skin_temp) {
        let score = curve(
            (temp - base).abs(),
            &[(0.3, 100.0), (0.5, 85.0), (1.0, 45.0), (1.5, 10.0), (2.0, 0.0)],
        );
        parts.push(("temperature", score, 13.0));
    }
    if let Some(recent) = input.recent_sleep_s {
        parts.push(("sleep_balance", total_sleep_score(recent), 12.0));
    }
    if let Some(hours) = input.recovery_index_h {
        let score = curve(hours, &[(0.0, 20.0), (1.0, 40.0), (3.0, 70.0), (6.0, 100.0)]);
        parts.push(("recovery_index", score, 10.0));
    }

    if parts.len() < 3 {
        return Value::Null;
    }
    combine(&parts, input.history_nights < MATURE_NIGHTS, "estimate")
}

/// Weighted mean of `(key, score, weight)`, weights renormalised over what is present.
pub(crate) fn combine(parts: &[(&str, f64, f64)], provisional: bool, basis: &str) -> Value {
    let total: f64 = parts.iter().map(|p| p.2).sum();
    let score = parts.iter().map(|p| p.1 * p.2).sum::<f64>() / total;
    json!({
        "score": score.round().clamp(0.0, 100.0),
        "components": parts.iter().map(|(key, s, w)| json!({
            "key": key,
            "score": s.round().clamp(0.0, 100.0),
            "weight": ((w / total) * 100.0).round() / 100.0,
        })).collect::<Vec<_>>(),
        "basis": basis,
        "provisional": provisional,
    })
}

/// Hours between the night's lowest heart rate (median of 5 consecutive samples, so a
/// single noisy beat can't be the minimum) and waking up. `samples` are `(ds, bpm)`.
pub fn recovery_index_h(samples: &[(i64, f64)], end_ds: i64) -> Option<f64> {
    if samples.len() < 12 {
        return None;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_by_key(|s| s.0);
    let lowest = sorted
        .windows(5)
        .map(|w| {
            let mut v: Vec<f64> = w.iter().map(|s| s.1).collect();
            v.sort_by(|a, b| a.total_cmp(b));
            (v[2], w[2].0)
        })
        .min_by(|a, b| a.0.total_cmp(&b.0))?;
    let hours = (end_ds - lowest.1) as f64 / 36_000.0;
    Some((hours.max(0.0) * 100.0).round() / 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rested() -> ReadinessInput {
        ReadinessInput {
            sleep_score: Some(88.0),
            lowest_hr: Some(50.0),
            baseline_lowest_hr: Some(51.0),
            hrv_ms: Some(62.0),
            baseline_hrv_ms: Some(60.0),
            skin_temp: Some(34.9),
            baseline_skin_temp: Some(34.8),
            recent_sleep_s: Some(7.8 * 3600.0),
            recovery_index_h: Some(5.5),
            history_nights: 20,
        }
    }

    #[test]
    fn rested_scores_high_and_strained_scores_low() {
        let good = estimate(&rested());
        let bad = estimate(&ReadinessInput {
            sleep_score: Some(55.0),
            lowest_hr: Some(58.0),
            hrv_ms: Some(40.0),
            skin_temp: Some(35.9),
            recovery_index_h: Some(0.5),
            history_nights: 5,
            ..rested()
        });
        assert!(good["score"].as_f64().unwrap() >= 90.0, "{good}");
        assert!(bad["score"].as_f64().unwrap() < 55.0, "{bad}");
        assert_eq!(good["provisional"], false);
        assert_eq!(bad["provisional"], true);
        let weights: f64 = good["components"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["weight"].as_f64().unwrap())
            .sum();
        assert!((weights - 1.0).abs() < 0.02);
    }

    #[test]
    fn needs_three_contributors() {
        let v = estimate(&ReadinessInput {
            sleep_score: Some(80.0),
            recovery_index_h: Some(4.0),
            ..Default::default()
        });
        assert!(v.is_null());
    }

    #[test]
    fn recovery_index_finds_the_smoothed_minimum() {
        // HR falls to 45 two hours before waking, with one noisy 30 spike earlier.
        let end = 8 * 36_000;
        let mut samples: Vec<(i64, f64)> = (0..16).map(|i| (i * 18_000, 60.0)).collect();
        samples[3].1 = 30.0;
        for s in samples.iter_mut().skip(10).take(5) {
            s.1 = 45.0;
        }
        let h = recovery_index_h(&samples, end).unwrap();
        // The smoothed rate first reaches 45 in the window centred on sample 10
        // (5 h); waking is at 8 h. The lone 30-bpm spike is ignored.
        assert_eq!(h, 3.0);
        assert_eq!(recovery_index_h(&samples[..5], end), None);
    }
}
