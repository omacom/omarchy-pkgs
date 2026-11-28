use std::ops::Range;

const RATE: usize = 16_000;
const MAX: usize = 35 * RATE;
const SEARCH: usize = 5 * RATE / 2;
const HALF_WINDOW: usize = RATE / 20;

/// Cohere's recommended limit is 35 seconds, despite accepting longer inputs.
/// Balance the remaining audio across windows, then prefer a quiet 100 ms
/// boundary within 2.5 seconds of that target. Ranges partition the input:
/// no dropped samples, overlap, or transcript deduplication heuristics.
pub fn segments(pcm: &[f32]) -> Vec<Range<usize>> {
    let mut result = Vec::new();
    let mut start = 0;
    while pcm.len() - start > MAX {
        let remaining = pcm.len() - start;
        let count = remaining.div_ceil(MAX);
        let target = start + remaining / count;
        let low = (target - SEARCH).max(start + HALF_WINDOW);
        let high = (target + SEARCH)
            .min(start + MAX)
            .min(pcm.len() - HALF_WINDOW);
        // Start at the target so ties (silence or constant amplitude) retain
        // balanced chunks, including recordings just above the 35 s limit.
        let energy = |cut: usize| -> f64 {
            pcm[cut - HALF_WINDOW..cut + HALF_WINDOW]
                .iter()
                .map(|x| f64::from(*x).powi(2))
                .sum()
        };
        let mut cut = target;
        let mut quietest = energy(cut);
        for candidate in (low..=high).step_by(RATE / 50) {
            let level = energy(candidate);
            if level < quietest {
                quietest = level;
                cut = candidate;
            }
        }
        result.push(start..cut);
        start = cut;
    }
    if start < pcm.len() {
        result.push(start..pcm.len());
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partitions_short_boundary_and_long_recordings_without_loss() {
        for length in [
            0,
            1,
            MAX - 1,
            MAX,
            MAX + 1,
            60 * RATE,
            120 * RATE,
            600 * RATE,
        ] {
            let parts = segments(&vec![0.1; length]);
            let mut end = 0;
            for part in parts {
                assert_eq!(part.start, end);
                assert!(!part.is_empty() && part.len() <= MAX);
                end = part.end;
            }
            assert_eq!(end, length);
        }
    }

    #[test]
    fn prefers_a_pause_near_the_balanced_boundary() {
        let mut pcm = vec![0.5; 60 * RATE];
        pcm[31 * RATE..31 * RATE + 3200].fill(0.0);
        let parts = segments(&pcm);
        assert_eq!(parts.len(), 2);
        assert!((31 * RATE + HALF_WINDOW..=31 * RATE + 3200 - HALF_WINDOW).contains(&parts[0].end));
    }
}
