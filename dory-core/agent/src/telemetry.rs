//! Guest memory + pressure telemetry. Pure parsers over `/proc/meminfo` and `/proc/pressure/memory`
//! (unit-tested on any host); the `/proc` reads are Linux-only and return zeros elsewhere. doryd
//! polls this to compute balloon set-points and idle decisions.

/// Parse `MemTotal:` and `MemAvailable:` (kB) from `/proc/meminfo` contents.
pub fn parse_meminfo(text: &str) -> (u64, u64) {
    let mut total = 0;
    let mut available = 0;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            total = first_number(rest);
        } else if let Some(rest) = line.strip_prefix("MemAvailable:") {
            available = first_number(rest);
        }
    }
    (total, available)
}

/// Parse the `some`/`full` 10s averages (percent) from `/proc/pressure/memory` contents. Lines look
/// like `some avg10=0.00 avg60=0.00 avg300=0.00 total=12345`.
pub fn parse_pressure(text: &str) -> (f64, f64) {
    let mut some = 0.0;
    let mut full = 0.0;
    for line in text.lines() {
        let avg10 = line
            .split_whitespace()
            .find_map(|f| f.strip_prefix("avg10="))
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(0.0);
        if line.starts_with("some ") {
            some = avg10;
        } else if line.starts_with("full ") {
            full = avg10;
        }
    }
    (some, full)
}

fn first_number(s: &str) -> u64 {
    s.split_whitespace()
        .find_map(|t| t.parse::<u64>().ok())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_meminfo_total_and_available() {
        let sample = "\
MemTotal:        4030820 kB
MemFree:          128460 kB
MemAvailable:    3512300 kB
Buffers:           12345 kB
";
        assert_eq!(parse_meminfo(sample), (4_030_820, 3_512_300));
    }

    #[test]
    fn missing_fields_default_to_zero() {
        assert_eq!(parse_meminfo("MemFree: 100 kB\n"), (0, 0));
        assert_eq!(parse_meminfo(""), (0, 0));
    }

    #[test]
    fn parses_pressure_some_and_full_avg10() {
        let sample = "\
some avg10=1.25 avg60=0.50 avg300=0.10 total=999
full avg10=0.75 avg60=0.20 avg300=0.05 total=111
";
        let (some, full) = parse_pressure(sample);
        assert_eq!(some, 1.25);
        assert_eq!(full, 0.75);
    }

    #[test]
    fn pressure_absent_full_line_defaults_to_zero() {
        // Some kernels emit only `some` for a resource; `full` must default, not error.
        let (some, full) = parse_pressure("some avg10=2.00 avg60=1.00 avg300=0.50 total=42\n");
        assert_eq!(some, 2.00);
        assert_eq!(full, 0.0);
    }
}
