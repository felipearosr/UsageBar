//! Builds the tray dbusmenu from a RenderState snapshot. The menu is rebuilt
//! wholesale on every tick — cheap for a dbusmenu, and it sidesteps menu-item
//! handle bookkeeping across threads.

use tauri::menu::{Menu, MenuBuilder, MenuItemBuilder, PredefinedMenuItem};
use tauri::{Manager, Runtime};
use time::OffsetDateTime;

use crate::client::{parse_resets_at, RateWindow, RenderState};

pub const ID_OPEN: &str = "open";
pub const ID_REFRESH: &str = "refresh";
pub const ID_QUIT: &str = "quit";

pub fn build<R: Runtime, M: Manager<R>>(
    mgr: &M,
    state: &RenderState,
) -> tauri::Result<Menu<R>> {
    let mut builder = MenuBuilder::new(mgr);

    // appindicator trays deliver no click events, so the popup opens from here.
    builder = builder.item(&MenuItemBuilder::with_id(ID_OPEN, "Open CodexBar").build(mgr)?);
    builder = builder.item(&PredefinedMenuItem::separator(mgr)?);

    let header = match state.last_fetch_secs_ago {
        Some(ago) => format!("CodexBar · updated {}", ago_text(ago)),
        None if state.serve_up => "CodexBar · fetching usage…".to_string(),
        None => "CodexBar · starting codexbar serve…".to_string(),
    };
    builder = builder.item(
        &MenuItemBuilder::with_id("header", header)
            .enabled(false)
            .build(mgr)?,
    );
    if !state.status.is_empty() {
        builder = builder.item(
            &MenuItemBuilder::with_id("status", format!("⚠ {}", truncate(&state.status, 70)))
                .enabled(false)
                .build(mgr)?,
        );
    }
    builder = builder.item(&PredefinedMenuItem::separator(mgr)?);

    let now = OffsetDateTime::now_utc();
    let mut row_index = 0usize;
    for row in &state.rows {
        let name = state.display_name(&row.provider);
        let windows = row.windows();
        if windows.is_empty() {
            if let Some(err) = &row.error {
                let msg = err.message.as_deref().unwrap_or("unavailable");
                builder = builder.item(
                    &MenuItemBuilder::with_id(format!("p{row_index}"), format!("{name} · unavailable"))
                        .enabled(false)
                        .build(mgr)?,
                );
                builder = builder.item(
                    &MenuItemBuilder::with_id(
                        format!("p{row_index}e"),
                        format!("    {}", truncate(msg, 70)),
                    )
                    .enabled(false)
                    .build(mgr)?,
                );
            } else {
                builder = builder.item(
                    &MenuItemBuilder::with_id(
                        format!("p{row_index}"),
                        format!("{name} · no usage data"),
                    )
                    .enabled(false)
                    .build(mgr)?,
                );
            }
        } else {
            for (slot, window) in windows {
                let mut line = window_line(&name, slot, window, now);
                if row.stale {
                    line.push_str(" · stale");
                }
                builder = builder.item(
                    &MenuItemBuilder::with_id(format!("p{row_index}w{slot}"), line)
                        .enabled(false)
                        .build(mgr)?,
                );
            }
            if let Some(err) = &row.error {
                let msg = err.message.as_deref().unwrap_or("fetch failed");
                builder = builder.item(
                    &MenuItemBuilder::with_id(
                        format!("p{row_index}e"),
                        format!("    ⚠ {}", truncate(msg, 70)),
                    )
                    .enabled(false)
                    .build(mgr)?,
                );
            } else if let Some(summary) = row.pace_summary() {
                builder = builder.item(
                    &MenuItemBuilder::with_id(
                        format!("p{row_index}pace"),
                        format!("    {}", truncate(summary, 70)),
                    )
                    .enabled(false)
                    .build(mgr)?,
                );
            }
        }
        row_index += 1;
    }
    if state.rows.is_empty() && state.serve_up {
        builder = builder.item(
            &MenuItemBuilder::with_id("none", "No providers enabled — run: codexbar config enable --provider <id>")
                .enabled(false)
                .build(mgr)?,
        );
    }

    builder = builder.item(&PredefinedMenuItem::separator(mgr)?);
    builder = builder.item(&MenuItemBuilder::with_id(ID_REFRESH, "Refresh now").build(mgr)?);
    builder = builder.item(&MenuItemBuilder::with_id(ID_QUIT, "Quit CodexBar Tray").build(mgr)?);
    builder.build()
}

/// "Codex · weekly · 13% used · resets in 5d 13h"
fn window_line(name: &str, slot: usize, window: &RateWindow, now: OffsetDateTime) -> String {
    let used = window.used_percent.unwrap_or(0.0);
    let label = window_label(window.window_minutes, slot);
    let reset = window
        .resets_at
        .as_deref()
        .and_then(parse_resets_at)
        .map(|at| {
            let secs = (at - now).whole_seconds();
            if secs <= 0 {
                "resets now".to_string()
            } else {
                format!("resets in {}", humanize_secs(secs as u64))
            }
        })
        .or_else(|| window.reset_description.clone().map(|d| format!("resets {d}")))
        .unwrap_or_default();
    let mut line = format!("{name} · {label} · {used:.0}% used");
    if !reset.is_empty() {
        line.push_str(" · ");
        line.push_str(&reset);
    }
    line
}

fn window_label(window_minutes: Option<i64>, slot: usize) -> String {
    match window_minutes {
        Some(m) if m >= 40_000 => "monthly".to_string(),
        Some(m) if m >= 9_000 => "weekly".to_string(),
        Some(m) if m >= 1_440 => format!("{}d", (m + 719) / 1_440),
        Some(m) if m >= 60 => format!("{}h", (m + 29) / 60),
        Some(m) => format!("{m}m"),
        None => ["session", "weekly", "monthly"]
            .get(slot)
            .unwrap_or(&"window")
            .to_string(),
    }
}

fn humanize_secs(secs: u64) -> String {
    let (d, h, m) = (secs / 86_400, (secs % 86_400) / 3_600, (secs % 3_600) / 60);
    if d > 0 {
        format!("{d}d {h}h")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else if m > 0 {
        format!("{m}m")
    } else {
        "under 1m".to_string()
    }
}

fn ago_text(secs: u64) -> String {
    if secs < 10 {
        "just now".to_string()
    } else if secs < 90 {
        format!("{secs}s ago")
    } else {
        format!("{}m ago", secs / 60)
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let cut: String = s.chars().take(max.saturating_sub(1)).collect();
        format!("{cut}…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::macros::datetime;

    #[test]
    fn window_line_formats_usage_and_countdown() {
        let window = RateWindow {
            used_percent: Some(13.0),
            resets_at: Some("2026-07-20T05:43:09Z".into()),
            reset_description: Some("Jul 20 at 1:43 AM".into()),
            window_minutes: Some(10_080),
            is_synthetic_placeholder: None,
        };
        let now = datetime!(2026-07-14 16:00:00 UTC);
        let line = window_line("Codex", 1, &window, now);
        assert_eq!(line, "Codex · weekly · 13% used · resets in 5d 13h");
    }

    #[test]
    fn window_line_falls_back_to_reset_description() {
        let window = RateWindow {
            used_percent: Some(50.0),
            resets_at: Some("not-a-date".into()),
            reset_description: Some("tomorrow".into()),
            window_minutes: Some(300),
            is_synthetic_placeholder: None,
        };
        let now = datetime!(2026-07-14 16:00:00 UTC);
        assert_eq!(
            window_line("Claude", 0, &window, now),
            "Claude · 5h · 50% used · resets tomorrow"
        );
    }

    #[test]
    fn humanize_and_labels() {
        assert_eq!(humanize_secs(30), "under 1m");
        assert_eq!(humanize_secs(150), "2m");
        assert_eq!(humanize_secs(7_800), "2h 10m");
        assert_eq!(humanize_secs(480_600), "5d 13h");
        assert_eq!(window_label(Some(43_200), 0), "monthly");
        assert_eq!(window_label(None, 0), "session");
    }
}
