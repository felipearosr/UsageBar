//! CodexBar Linux tray (MVP): supervises `codexbar serve`, polls /usage, and
//! renders a usage-gauge tray icon with per-provider menu rows.

mod client;
mod gauge;
mod menu;
mod popup;
mod serve;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use client::RenderState;
use tauri::tray::TrayIconBuilder;

const TRAY_ID: &str = "codexbar";
const TICK_SECS: u64 = 30;
const FETCH_EVERY_SECS: u64 = 55;

#[derive(Default)]
pub(crate) struct Shared {
    pub(crate) state: RenderState,
    pub(crate) last_fetch: Option<Instant>,
}

/// Handles the popup commands need, managed by tauri (see popup.rs).
pub(crate) struct Ctx {
    pub(crate) shared: Arc<Mutex<Shared>>,
    pub(crate) shutdown: Arc<AtomicBool>,
    pub(crate) child: Arc<Mutex<Option<std::process::Child>>>,
    pub(crate) cost_cache: Mutex<Option<(Instant, Vec<client::CostReport>)>>,
}

enum Wake {
    Refresh,
    Update,
}

fn main() {
    // Wayland doesn't let toplevels position themselves, which would strand the
    // popup in the middle of the screen. Run on XWayland instead so it can
    // anchor to the tray corner. Must happen before GTK initializes.
    if std::env::var_os("GDK_BACKEND").is_none() && std::env::var_os("WAYLAND_DISPLAY").is_some()
    {
        std::env::set_var("GDK_BACKEND", "x11");
    }

    let shared = Arc::new(Mutex::new(Shared::default()));
    let shutdown = Arc::new(AtomicBool::new(false));
    let child_slot: Arc<Mutex<Option<std::process::Child>>> = Arc::new(Mutex::new(None));
    let (tx, rx) = mpsc::channel::<Wake>();

    let setup_shared = shared.clone();
    let setup_shutdown = shutdown.clone();
    let setup_child = child_slot.clone();
    let setup_tx = tx.clone();
    let exit_child = child_slot.clone();
    let exit_shutdown = shutdown.clone();

    tauri::Builder::default()
        .manage(Ctx {
            shared: shared.clone(),
            shutdown: shutdown.clone(),
            child: child_slot.clone(),
            cost_cache: Mutex::new(None),
        })
        .invoke_handler(tauri::generate_handler![
            popup::state,
            popup::cost,
            popup::open_url,
            popup::hide_popup,
            popup::quit_app,
        ])
        .on_window_event(|window, event| {
            if window.label() != popup::LABEL {
                return;
            }
            match event {
                // Wayland can't anchor us to the tray, so the popup behaves
                // like a menu instead: it goes away when it loses focus.
                tauri::WindowEvent::Focused(false) => {
                    let _ = window.hide();
                }
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    api.prevent_close();
                    let _ = window.hide();
                }
                _ => {}
            }
        })
        .setup(move |app| {
            let initial = setup_shared.lock().unwrap().state.clone();
            let menu = menu::build(app, &initial)?;
            let menu_tx = setup_tx.clone();
            let menu_shutdown = setup_shutdown.clone();
            let menu_child = setup_child.clone();
            TrayIconBuilder::with_id(TRAY_ID)
                .icon(gauge::render(None, false))
                .tooltip("CodexBar")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    menu::ID_OPEN => {
                        popup::open(app);
                    }
                    menu::ID_REFRESH => {
                        let _ = menu_tx.send(Wake::Refresh);
                    }
                    menu::ID_QUIT => {
                        menu_shutdown.store(true, Ordering::SeqCst);
                        serve::Supervisor::kill_child(&menu_child);
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(app)?;

            serve::hint_if_no_status_notifier_watcher();

            let Some(binary) = serve::find_binary() else {
                setup_shared.lock().unwrap().state.status =
                    "codexbar CLI not found — install it (brew install steipete/tap/codexbar) or set $CODEXBAR_BIN".into();
                spawn_render_loop(app.handle().clone(), setup_shared.clone(), setup_shutdown.clone(), rx);
                return Ok(());
            };

            // Display names, off the hot path (one slow CLI invocation).
            {
                let shared = setup_shared.clone();
                let tx = setup_tx.clone();
                let binary = binary.clone();
                std::thread::spawn(move || {
                    if let Ok(names) = client::provider_display_names(&binary) {
                        shared.lock().unwrap().state.names = names;
                        let _ = tx.send(Wake::Update);
                    }
                });
            }

            // Serve supervisor.
            {
                let shared = setup_shared.clone();
                let shutdown = setup_shutdown.clone();
                let tx = setup_tx.clone();
                let child = setup_child.clone();
                std::thread::spawn(move || {
                    let port = match serve::pick_free_port() {
                        Ok(p) => p,
                        Err(e) => {
                            shared.lock().unwrap().state.status =
                                format!("no free loopback port: {e}");
                            let _ = tx.send(Wake::Update);
                            return;
                        }
                    };
                    PORT.store(port, Ordering::SeqCst);
                    let supervisor = serve::Supervisor { binary, port, child };
                    supervisor.run(shutdown, |port_up, status| {
                        let mut guard = shared.lock().unwrap();
                        guard.state.serve_up = port_up.is_some();
                        guard.state.status = status;
                        drop(guard);
                        let _ = tx.send(if port_up.is_some() {
                            Wake::Refresh
                        } else {
                            Wake::Update
                        });
                    });
                });
            }

            // Poll + render loop. `port` lives in serve_up + supervisor port; we
            // re-read it from the supervisor via shared state updates.
            spawn_poll_loop(
                app.handle().clone(),
                setup_shared.clone(),
                setup_shutdown.clone(),
                rx,
            );
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build tauri app")
        .run(move |_app, event| {
            if let tauri::RunEvent::Exit = event {
                exit_shutdown.store(true, Ordering::SeqCst);
                serve::Supervisor::kill_child(&exit_child);
            }
        });
}

/// Degenerate loop for when the CLI is missing: just keeps the menu current.
fn spawn_render_loop(
    handle: tauri::AppHandle,
    shared: Arc<Mutex<Shared>>,
    shutdown: Arc<AtomicBool>,
    rx: mpsc::Receiver<Wake>,
) {
    std::thread::spawn(move || loop {
        let _ = rx.recv_timeout(Duration::from_secs(TICK_SECS));
        if shutdown.load(Ordering::SeqCst) {
            return;
        }
        render(&handle, &shared);
    });
}

fn spawn_poll_loop(
    handle: tauri::AppHandle,
    shared: Arc<Mutex<Shared>>,
    shutdown: Arc<AtomicBool>,
    rx: mpsc::Receiver<Wake>,
) {
    std::thread::spawn(move || {
        loop {
            let wake = rx.recv_timeout(Duration::from_secs(TICK_SECS));
            if shutdown.load(Ordering::SeqCst) {
                return;
            }
            let force = matches!(wake, Ok(Wake::Refresh));
            if matches!(wake, Err(RecvTimeoutError::Disconnected)) {
                return;
            }
            let (serve_up, due) = {
                let guard = shared.lock().unwrap();
                let due = guard
                    .last_fetch
                    .map_or(true, |t| t.elapsed() >= Duration::from_secs(FETCH_EVERY_SECS));
                (guard.state.serve_up, due)
            };
            if serve_up && (force || due) {
                match client::fetch_usage(PORT.load(Ordering::SeqCst)) {
                    Ok(rows) => {
                        let mut guard = shared.lock().unwrap();
                        guard.state.rows = client::merge_stale(&guard.state.rows, rows);
                        guard.state.status.clear();
                        guard.last_fetch = Some(Instant::now());
                    }
                    Err(e) => {
                        shared.lock().unwrap().state.status = format!("usage fetch failed: {e:#}");
                    }
                }
            }
            render(&handle, &shared);
        }
    });
}

/// The serve port, published once by the supervisor thread for the poll loop
/// and the popup's /cost proxy.
pub(crate) static PORT: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(0);

fn render(handle: &tauri::AppHandle, shared: &Arc<Mutex<Shared>>) {
    let snapshot = {
        let guard = shared.lock().unwrap();
        let mut st = guard.state.clone();
        st.last_fetch_secs_ago = guard.last_fetch.map(|t| t.elapsed().as_secs());
        st
    };
    let handle_inner = handle.clone();
    let _ = handle.run_on_main_thread(move || {
        let Some(tray) = handle_inner.tray_by_id(TRAY_ID) else {
            return;
        };
        let percent = snapshot.worst_used_percent();
        let _ = tray.set_icon(Some(gauge::render(percent, snapshot.any_error())));
        let tooltip = match percent {
            Some(p) => format!("CodexBar — {p:.0}% used (worst window)"),
            None => "CodexBar".to_string(),
        };
        let _ = tray.set_tooltip(Some(tooltip));
        if let Ok(m) = menu::build(&handle_inner, &snapshot) {
            let _ = tray.set_menu(Some(m));
        }
        popup::notify_state_updated(&handle_inner);
    });
}
