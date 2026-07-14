//! Integration test against a real `codexbar serve` child. Needs the codexbar
//! CLI installed (and network for provider fetches), so it is #[ignore]d by
//! default — run with: cargo test -- --ignored

use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::time::Duration;

fn find_codexbar() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("CODEXBAR_BIN") {
        return Some(p.into());
    }
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|d| d.join("codexbar"))
            .find(|p| p.is_file())
    })
}

#[test]
#[ignore = "spawns the real codexbar CLI; run with --ignored"]
fn serve_health_and_usage_roundtrip() {
    let binary = find_codexbar().expect("codexbar CLI not found on PATH");
    let port = TcpListener::bind(("127.0.0.1", 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let mut child = Command::new(&binary)
        .args([
            "serve",
            "--port",
            &port.to_string(),
            "--refresh-interval",
            "30",
            "--request-timeout",
            "120",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn codexbar serve");

    // Wait for /health.
    let health_url = format!("http://127.0.0.1:{port}/health");
    let mut healthy = false;
    for _ in 0..40 {
        if let Ok(resp) = ureq::get(&health_url).timeout(Duration::from_secs(2)).call() {
            let body = resp.into_string().unwrap_or_default();
            assert!(body.contains("\"ok\""), "unexpected /health body: {body}");
            healthy = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(500));
    }

    let result = healthy.then(|| {
        ureq::get(&format!("http://127.0.0.1:{port}/usage"))
            .timeout(Duration::from_secs(130))
            .call()
            .expect("/usage call")
            .into_string()
            .expect("/usage body")
    });

    let _ = child.kill();
    let _ = child.wait();

    let body = result.expect("serve never became healthy");
    let rows: Vec<serde_json::Value> = serde_json::from_str(&body).expect("usage JSON array");
    for row in &rows {
        assert!(row.get("provider").is_some(), "row missing provider: {row}");
    }
}
