//! Supervisor for the `codexbar serve` child process: locate the binary, pick a
//! free port, spawn, wait for /health, restart with backoff, kill on shutdown.

use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::client;

// Gentle upstream cadence: Claude's usage endpoint rate-limits aggressive
// pollers. serve refreshes on demand at most this often; /usage stays a cache
// hit in between.
pub const REFRESH_INTERVAL_SECS: u32 = 300;
pub const REQUEST_TIMEOUT_SECS: u32 = 120;

/// $CODEXBAR_BIN override → $PATH → ~/.local/bin/codexbar.
pub fn find_binary() -> Option<PathBuf> {
    if let Ok(explicit) = std::env::var("CODEXBAR_BIN") {
        let p = PathBuf::from(explicit);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let p = dir.join("codexbar");
            if p.is_file() {
                return Some(p);
            }
        }
    }
    let fallback = PathBuf::from(std::env::var("HOME").ok()?).join(".local/bin/codexbar");
    fallback.is_file().then_some(fallback)
}

pub fn pick_free_port() -> std::io::Result<u16> {
    Ok(TcpListener::bind(("127.0.0.1", 0))?.local_addr()?.port())
}

pub struct Supervisor {
    pub binary: PathBuf,
    pub port: u16,
    /// The live child; the quit path takes it out and kills it synchronously.
    pub child: Arc<Mutex<Option<Child>>>,
}

impl Supervisor {
    /// Kill the child synchronously. Safe to call from the exit path.
    pub fn kill_child(child: &Arc<Mutex<Option<Child>>>) {
        if let Some(mut c) = child.lock().unwrap().take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    /// Blocking supervision loop; run on a dedicated thread.
    /// `on_state(port_up, status_message)` fires on every serve state change.
    pub fn run(
        &self,
        shutdown: Arc<AtomicBool>,
        on_state: impl Fn(Option<u16>, String),
    ) {
        let mut backoff_secs = 2u64;
        loop {
            if shutdown.load(Ordering::SeqCst) {
                return;
            }
            let mut command = Command::new(&self.binary);
            command
                .args([
                    "serve",
                    "--port",
                    &self.port.to_string(),
                    "--refresh-interval",
                    &REFRESH_INTERVAL_SECS.to_string(),
                    "--request-timeout",
                    &REQUEST_TIMEOUT_SECS.to_string(),
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            // The kernel reaps the child even if we die without cleanup
            // (SIGKILL, session logout).
            #[cfg(target_os = "linux")]
            {
                use std::os::unix::process::CommandExt;
                unsafe {
                    command.pre_exec(|| {
                        if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                            return Err(std::io::Error::last_os_error());
                        }
                        Ok(())
                    });
                }
            }
            let spawned = command.spawn();
            match spawned {
                Ok(c) => *self.child.lock().unwrap() = Some(c),
                Err(e) => {
                    on_state(None, format!("failed to start codexbar serve: {e}"));
                    if !self.sleep_unless_shutdown(&shutdown, backoff_secs) {
                        return;
                    }
                    backoff_secs = (backoff_secs * 2).min(30);
                    continue;
                }
            }

            if self.wait_ready(&shutdown) {
                backoff_secs = 2;
                on_state(Some(self.port), String::new());
            } else if !shutdown.load(Ordering::SeqCst) {
                on_state(None, "codexbar serve did not become ready".into());
            }

            // Wait for exit (or shutdown), polling so quit stays responsive.
            loop {
                if shutdown.load(Ordering::SeqCst) {
                    Self::kill_child(&self.child);
                    return;
                }
                let exited = {
                    let mut guard = self.child.lock().unwrap();
                    match guard.as_mut() {
                        Some(c) => c.try_wait().ok().flatten().is_some(),
                        None => true, // quit path already took it
                    }
                };
                if exited {
                    break;
                }
                std::thread::sleep(Duration::from_millis(500));
            }
            self.child.lock().unwrap().take();
            on_state(None, "codexbar serve exited — restarting…".into());
            if !self.sleep_unless_shutdown(&shutdown, backoff_secs) {
                return;
            }
            backoff_secs = (backoff_secs * 2).min(30);
        }
    }

    /// Poll /health until ok. Returns false on timeout/shutdown/child death.
    fn wait_ready(&self, shutdown: &AtomicBool) -> bool {
        for _ in 0..60 {
            if shutdown.load(Ordering::SeqCst) {
                return false;
            }
            if client::fetch_health(self.port).is_ok() {
                return true;
            }
            let died = {
                let mut guard = self.child.lock().unwrap();
                match guard.as_mut() {
                    Some(c) => c.try_wait().ok().flatten().is_some(),
                    None => true,
                }
            };
            if died {
                return false;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        false
    }

    fn sleep_unless_shutdown(&self, shutdown: &AtomicBool, secs: u64) -> bool {
        for _ in 0..(secs * 2) {
            if shutdown.load(Ordering::SeqCst) {
                return false;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        true
    }
}

/// One-time hint for desktops with no StatusNotifier host (stock Fedora GNOME).
pub fn hint_if_no_status_notifier_watcher() {
    let Ok(out) = Command::new("busctl")
        .args(["--user", "--no-pager", "status", "org.kde.StatusNotifierWatcher"])
        .output()
    else {
        return; // busctl unavailable — can't tell, stay quiet
    };
    if out.status.success() {
        return;
    }
    let msg = "No system tray host found (org.kde.StatusNotifierWatcher is not on the bus). \
               On GNOME (e.g. stock Fedora Workstation) install and enable the AppIndicator \
               extension: gnome-shell-extension-appindicator. Ubuntu ships it by default.";
    eprintln!("codexbar-tray: {msg}");
    let _ = Command::new("notify-send")
        .args(["--app-name=CodexBar Tray", "CodexBar Tray", msg])
        .status();
}
