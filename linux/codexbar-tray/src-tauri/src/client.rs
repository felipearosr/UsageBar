//! Serde models mirroring the `codexbar serve` / `codexbar usage --format json`
//! payloads (see Sources/CodexBarCLI/CLIPayloads.swift and
//! Sources/CodexBarCore/UsageFetcher.swift upstream), plus the HTTP client.
//!
//! The JSON schema is an implicit contract with the CLI: every field is
//! optional/defaulted and unknown fields are ignored, so a newer CLI can only
//! degrade gracefully, never break deserialization. Fixture tests below guard
//! against drift.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct ProviderRow {
    pub provider: String,
    pub account: Option<String>,
    pub version: Option<String>,
    pub source: Option<String>,
    pub usage: Option<UsageSnapshot>,
    pub error: Option<ProviderError>,
    pub pace: Option<ProviderPace>,
    /// Usage carried over from the last good fetch after an error row.
    /// Never present in serve payloads (only set by merge_stale), but the
    /// popup frontend needs it, so it serializes.
    #[serde(skip_deserializing)]
    pub stale: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct UsageSnapshot {
    pub primary: Option<RateWindow>,
    pub secondary: Option<RateWindow>,
    pub tertiary: Option<RateWindow>,
    pub identity: Option<Identity>,
    pub data_confidence: Option<String>,
    pub updated_at: Option<String>,
    pub account_email: Option<String>,
    pub login_method: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct RateWindow {
    pub used_percent: Option<f64>,
    pub resets_at: Option<String>,
    pub reset_description: Option<String>,
    pub window_minutes: Option<i64>,
    pub is_synthetic_placeholder: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Identity {
    pub account_email: Option<String>,
    pub account_organization: Option<String>,
    pub login_method: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct ProviderError {
    pub code: Option<i64>,
    pub kind: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct ProviderPace {
    pub primary: Option<Pace>,
    pub secondary: Option<Pace>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct Pace {
    pub stage: Option<String>,
    pub summary: Option<String>,
    pub will_last_to_reset: Option<bool>,
}

impl ProviderRow {
    /// Rate windows worth showing, in slot order, skipping synthetic placeholders
    /// and windows with unknown usage.
    pub fn windows(&self) -> Vec<(usize, &RateWindow)> {
        let Some(usage) = &self.usage else {
            return Vec::new();
        };
        [&usage.primary, &usage.secondary, &usage.tertiary]
            .into_iter()
            .enumerate()
            .filter_map(|(slot, w)| w.as_ref().map(|w| (slot, w)))
            .filter(|(_, w)| !w.is_synthetic_placeholder.unwrap_or(false) && w.used_percent.is_some())
            .collect()
    }

    /// The single most urgent window: highest used percent.
    pub fn worst_used_percent(&self) -> Option<f64> {
        self.windows()
            .iter()
            .filter_map(|(_, w)| w.used_percent)
            .fold(None, |acc, p| Some(acc.map_or(p, |a: f64| a.max(p))))
    }

    pub fn pace_summary(&self) -> Option<&str> {
        let pace = self.pace.as_ref()?;
        pace.primary
            .as_ref()
            .or(pace.secondary.as_ref())?
            .summary
            .as_deref()
            .filter(|s| !s.is_empty())
    }
}

/// Serve replaces a provider's row with a bare error row when a fetch fails
/// (e.g. Claude's usage endpoint rate-limiting). Carry the last known usage
/// forward so the menu shows "52% (stale)" instead of going blank; the error
/// stays on the row so it can be surfaced alongside.
pub fn merge_stale(previous: &[ProviderRow], mut fresh: Vec<ProviderRow>) -> Vec<ProviderRow> {
    for row in &mut fresh {
        if row.error.is_some() && row.windows().is_empty() {
            if let Some(prev) = previous
                .iter()
                .find(|p| p.provider == row.provider && !p.windows().is_empty())
            {
                row.usage = prev.usage.clone();
                row.pace = prev.pace.clone();
                if row.account.is_none() {
                    row.account = prev.account.clone();
                }
                row.stale = true;
            }
        }
    }
    fresh
}

pub fn parse_resets_at(raw: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(raw, &Rfc3339).ok()
}

/// GET /usage from the supervised `codexbar serve` instance.
pub fn fetch_usage(port: u16) -> Result<Vec<ProviderRow>> {
    let url = format!("http://127.0.0.1:{port}/usage");
    let body = ureq::get(&url)
        .timeout(Duration::from_secs(130))
        .call()
        .with_context(|| format!("GET {url}"))?
        .into_string()
        .context("reading /usage body")?;
    serde_json::from_str(&body).context("parsing /usage JSON")
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthResponse {
    pub status: String,
    #[serde(default)]
    pub version: Option<String>,
}

pub fn fetch_health(port: u16) -> Result<HealthResponse> {
    let url = format!("http://127.0.0.1:{port}/health");
    let body = ureq::get(&url)
        .timeout(Duration::from_secs(3))
        .call()
        .with_context(|| format!("GET {url}"))?
        .into_string()?;
    let health: HealthResponse = serde_json::from_str(&body)?;
    if health.status != "ok" {
        return Err(anyhow!("serve health status: {}", health.status));
    }
    Ok(health)
}

/// One provider's entry in the `/cost` payload (CostPayload upstream in
/// Sources/CodexBarCLI/CLICostCommand.swift). Cost data comes from local CLI
/// session logs, so `$` fields are absent for providers without pricing.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct CostReport {
    pub provider: String,
    pub source: Option<String>,
    pub updated_at: Option<String>,
    pub currency_code: Option<String>,
    pub session_tokens: Option<i64>,
    #[serde(rename = "sessionCostUSD")]
    pub session_cost_usd: Option<f64>,
    pub history_days: Option<i64>,
    #[serde(rename = "last30DaysTokens")]
    pub last30_days_tokens: Option<i64>,
    #[serde(rename = "last30DaysCostUSD")]
    pub last30_days_cost_usd: Option<f64>,
    pub daily: Vec<CostDailyEntry>,
    pub totals: Option<CostTotals>,
    pub error: Option<ProviderError>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct CostDailyEntry {
    pub date: String,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_creation_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    /// Upstream serializes costUSD under the key "totalCost".
    #[serde(rename = "totalCost")]
    pub cost_usd: Option<f64>,
    pub models_used: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
pub struct CostTotals {
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub cache_creation_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    #[serde(rename = "totalCost")]
    pub cost_usd: Option<f64>,
}

/// GET /cost from the supervised `codexbar serve` instance. First call can be
/// slow (serve scans local session logs); cached upstream afterwards.
pub fn fetch_cost(port: u16) -> Result<Vec<CostReport>> {
    let url = format!("http://127.0.0.1:{port}/cost");
    let body = ureq::get(&url)
        .timeout(Duration::from_secs(130))
        .call()
        .with_context(|| format!("GET {url}"))?
        .into_string()
        .context("reading /cost body")?;
    serde_json::from_str(&body).context("parsing /cost JSON")
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProviderCatalogEntry {
    provider: String,
    display_name: String,
}

/// Provider id → display name, via `codexbar config providers --format json`.
pub fn provider_display_names(binary: &PathBuf) -> Result<HashMap<String, String>> {
    let out = Command::new(binary)
        .args(["config", "providers", "--format", "json"])
        .output()
        .context("running codexbar config providers")?;
    if !out.status.success() {
        return Err(anyhow!("codexbar config providers exited with {}", out.status));
    }
    let entries: Vec<ProviderCatalogEntry> = serde_json::from_slice(&out.stdout)?;
    Ok(entries
        .into_iter()
        .map(|e| (e.provider, e.display_name))
        .collect())
}

/// Everything the render pass (icon + menu + popup) needs, snapshotted off the
/// shared state. Serialized as-is to the popup webview via the `state` command.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderState {
    pub rows: Vec<ProviderRow>,
    pub names: HashMap<String, String>,
    pub status: String,
    pub serve_up: bool,
    pub last_fetch_secs_ago: Option<u64>,
}

impl RenderState {
    pub fn display_name(&self, provider: &str) -> String {
        self.names.get(provider).cloned().unwrap_or_else(|| {
            let mut chars = provider.chars();
            match chars.next() {
                Some(f) => f.to_uppercase().collect::<String>() + chars.as_str(),
                None => provider.to_string(),
            }
        })
    }

    /// Worst (highest) used percent across all providers, for the tray gauge.
    pub fn worst_used_percent(&self) -> Option<f64> {
        self.rows
            .iter()
            .filter_map(|r| r.worst_used_percent())
            .fold(None, |acc, p| Some(acc.map_or(p, |a: f64| a.max(p))))
    }

    pub fn any_error(&self) -> bool {
        self.rows.iter().any(|r| r.error.is_some())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Vec<ProviderRow> {
        let path = format!("{}/../fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
        let body = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        serde_json::from_str(&body).unwrap_or_else(|e| panic!("{path}: {e}"))
    }

    #[test]
    fn parses_cli_usage_fixture() {
        let rows = fixture("usage.json");
        assert!(!rows.is_empty());
        let codex = rows.iter().find(|r| r.provider == "codex").expect("codex row");
        assert!(codex.error.is_none());
        let windows = codex.windows();
        assert!(!windows.is_empty(), "codex should expose at least one rate window");
        let (_, weekly) = windows[0];
        assert!(weekly.used_percent.unwrap() > 0.0);
        assert_eq!(weekly.window_minutes, Some(10080));
        let resets = parse_resets_at(weekly.resets_at.as_deref().unwrap()).expect("parse resetsAt");
        assert!(resets.year() >= 2026);
    }

    #[test]
    fn parses_serve_usage_fixture_with_error_row() {
        let rows = fixture("serve_usage.json");
        let claude = rows.iter().find(|r| r.provider == "claude").expect("claude row");
        let err = claude.error.as_ref().expect("claude fixture captured an error row");
        assert!(err.message.as_deref().unwrap_or("").len() > 0);
        assert!(claude.windows().is_empty());
    }

    #[test]
    fn tolerates_unknown_fields_and_missing_everything() {
        let rows: Vec<ProviderRow> =
            serde_json::from_str(r#"[{"provider":"new","brandNewField":{"x":1}}]"#).unwrap();
        assert_eq!(rows[0].provider, "new");
        assert!(rows[0].windows().is_empty());
        assert!(rows[0].worst_used_percent().is_none());
    }

    #[test]
    fn merge_stale_carries_usage_through_error_rows() {
        let good = fixture("usage.json");
        let codex_percent = good
            .iter()
            .find(|r| r.provider == "codex")
            .and_then(|r| r.worst_used_percent())
            .expect("fixture codex usage");

        let error_only: Vec<ProviderRow> = serde_json::from_str(
            r#"[{"provider":"codex","error":{"kind":"provider","message":"rate limited"}}]"#,
        )
        .unwrap();

        // First failure: usage carried forward, marked stale, error kept.
        let merged = merge_stale(&good, error_only.clone());
        let codex = &merged[0];
        assert!(codex.stale);
        assert!(codex.error.is_some());
        assert_eq!(codex.worst_used_percent(), Some(codex_percent));

        // Consecutive failure: the stale row itself still seeds the carry-over.
        let merged_again = merge_stale(&merged, error_only);
        assert!(merged_again[0].stale);
        assert_eq!(merged_again[0].worst_used_percent(), Some(codex_percent));

        // Recovery: a fresh good row passes through untouched.
        let recovered = merge_stale(&merged_again, good.clone());
        let codex = recovered.iter().find(|r| r.provider == "codex").unwrap();
        assert!(!codex.stale);
        assert!(codex.error.is_none());
    }

    #[test]
    fn parses_current_serve_usage_fixture() {
        // Captured from serve v0.37.2; includes newer fields (codexResetCredits,
        // credits) that must fall into the unknown-field bucket without error.
        let rows = fixture("usage_live.json");
        for provider in ["codex", "claude"] {
            let row = rows.iter().find(|r| r.provider == provider).expect(provider);
            assert!(!row.windows().is_empty(), "{provider} should expose windows");
        }
        let codex = rows.iter().find(|r| r.provider == "codex").unwrap();
        let plan = codex.usage.as_ref().unwrap().login_method.as_deref();
        assert_eq!(plan, Some("plus"), "loginMethod feeds the popup plan badge");
    }

    #[test]
    fn parses_cost_fixture() {
        let path = format!("{}/../fixtures/cost.json", env!("CARGO_MANIFEST_DIR"));
        let body = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let reports: Vec<CostReport> =
            serde_json::from_str(&body).unwrap_or_else(|e| panic!("{path}: {e}"));

        let claude = reports.iter().find(|r| r.provider == "claude").expect("claude cost");
        let totals = claude.totals.as_ref().expect("claude totals");
        assert!(totals.cost_usd.unwrap() > 0.0, "claude 30d cost in dollars");
        assert!(totals.total_tokens.unwrap() > 0);
        assert!(claude.session_cost_usd.unwrap() > 0.0);
        assert!(!claude.daily.is_empty());
        let day = &claude.daily[0];
        assert!(day.date.starts_with("20"), "daily date is YYYY-MM-DD: {}", day.date);
        assert!(day.cost_usd.unwrap() > 0.0, "daily totalCost maps to cost_usd");

        // Codex counts tokens locally but has no pricing — dollars stay None.
        let codex = reports.iter().find(|r| r.provider == "codex").expect("codex cost");
        assert!(codex.last30_days_tokens.unwrap() > 0);
        assert!(codex.totals.as_ref().unwrap().cost_usd.is_none());
    }

    #[test]
    fn cost_tolerates_unknown_and_missing_fields() {
        let reports: Vec<CostReport> =
            serde_json::from_str(r#"[{"provider":"new","futureField":[1,2]}]"#).unwrap();
        assert_eq!(reports[0].provider, "new");
        assert!(reports[0].totals.is_none());
        assert!(reports[0].daily.is_empty());
    }

    #[test]
    fn render_state_serializes_camel_case_for_the_popup() {
        let mut st = RenderState::default();
        st.rows = fixture("usage.json");
        st.rows[0].stale = true;
        st.last_fetch_secs_ago = Some(42);
        let json = serde_json::to_value(&st).unwrap();
        assert_eq!(json["lastFetchSecsAgo"], 42);
        assert_eq!(json["rows"][0]["stale"], true);
        let row = st.rows.iter().find(|r| r.provider == "codex").unwrap();
        let (slot, w) = row.windows()[0];
        let rows = json["rows"].as_array().unwrap();
        let jrow = rows.iter().find(|r| r["provider"] == "codex").unwrap();
        let key = ["primary", "secondary", "tertiary"][slot];
        assert_eq!(
            jrow["usage"][key]["usedPercent"].as_f64(),
            w.used_percent
        );
    }

    #[test]
    fn render_state_picks_worst_percent() {
        let mut st = RenderState::default();
        st.rows = fixture("serve_usage.json");
        let worst = st.worst_used_percent().expect("codex row has usage");
        assert!(worst > 0.0 && worst <= 100.0);
        assert!(st.any_error(), "claude error row should be flagged");
    }
}
