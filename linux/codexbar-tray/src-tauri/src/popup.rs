//! The popup webview window (dist/index.html) and the Tauri commands backing
//! it. Wayland gives us no tray-anchored positioning, so the window is a small
//! centered always-on-top panel, created lazily on first "Open CodexBar" and
//! then shown/hidden; main.rs hides it on focus loss and close-request.

use std::process::Stdio;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::client::{self, CostReport, RenderState};
use crate::{Ctx, PORT};

pub const LABEL: &str = "popup";

/// serve caches /cost upstream, but a scan can still be slow; don't let an
/// impatient frontend stack requests.
const COST_TTL: Duration = Duration::from_secs(120);

/// Show the popup, creating it on first use. Safe to call from menu-event
/// context; window creation is marshalled to the main thread.
pub fn open(app: &AppHandle) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        if let Some(window) = app.get_webview_window(LABEL) {
            anchor_top_right(&window);
            let _ = window.show();
            let _ = window.set_focus();
            let _ = window.emit("popup-shown", ());
            return;
        }
        let built = WebviewWindowBuilder::new(&app, LABEL, WebviewUrl::App("index.html".into()))
            .title("CodexBar")
            .inner_size(380.0, 560.0)
            .resizable(false)
            .decorations(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .visible(false)
            .build();
        match built {
            Ok(window) => {
                anchor_top_right(&window);
                let _ = window.show();
                let _ = window.set_focus();
            }
            Err(e) => eprintln!("codexbar-tray: failed to create popup window: {e}"),
        }
    });
}

/// Place the popup below the panel in the top-right corner — where the tray
/// icon lives on GNOME — approximating a tray-anchored popover (appindicator
/// gives us no icon coordinates to anchor to exactly).
fn anchor_top_right(window: &tauri::WebviewWindow) {
    let Ok(Some(monitor)) = window.current_monitor() else {
        return;
    };
    let scale = monitor.scale_factor();
    let width = window
        .outer_size()
        .map(|s| s.width as i32)
        .unwrap_or((380.0 * scale) as i32);
    let margin = (8.0 * scale) as i32;
    let panel = (40.0 * scale) as i32; // GNOME top bar ≈ 32–40 logical px
    let x = monitor.position().x + monitor.size().width as i32 - width - margin;
    let y = monitor.position().y + panel + margin;
    let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
}

/// Nudge the (existing, possibly hidden) popup to re-pull state.
pub fn notify_state_updated(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.emit("state-updated", ());
    }
}

#[tauri::command]
pub fn state(ctx: tauri::State<'_, Ctx>) -> RenderState {
    let guard = ctx.shared.lock().unwrap();
    let mut st = guard.state.clone();
    st.last_fetch_secs_ago = guard.last_fetch.map(|t| t.elapsed().as_secs());
    st
}

#[tauri::command]
pub async fn cost(app: AppHandle) -> Result<Vec<CostReport>, String> {
    {
        let ctx = app.state::<Ctx>();
        let cache = ctx.cost_cache.lock().unwrap();
        if let Some((at, reports)) = cache.as_ref() {
            if at.elapsed() < COST_TTL {
                return Ok(reports.clone());
            }
        }
    }
    let port = PORT.load(Ordering::SeqCst);
    if port == 0 {
        return Err("codexbar serve is not running yet".into());
    }
    let reports = tauri::async_runtime::spawn_blocking(move || client::fetch_cost(port))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| format!("{e:#}"))?;
    *app.state::<Ctx>().cost_cache.lock().unwrap() = Some((Instant::now(), reports.clone()));
    Ok(reports)
}

#[tauri::command]
pub fn open_url(url: String) -> Result<(), String> {
    if !url.starts_with("https://") && !url.starts_with("http://") {
        return Err(format!("refusing to open non-http(s) URL: {url}"));
    }
    std::process::Command::new("xdg-open")
        .arg(&url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("xdg-open: {e}"))?;
    Ok(())
}

#[tauri::command]
pub fn hide_popup(window: tauri::WebviewWindow) {
    let _ = window.hide();
}

#[tauri::command]
pub fn quit_app(app: AppHandle) {
    let ctx = app.state::<Ctx>();
    ctx.shutdown.store(true, Ordering::SeqCst);
    crate::serve::Supervisor::kill_child(&ctx.child);
    app.exit(0);
}
