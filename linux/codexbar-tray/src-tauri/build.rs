fn main() {
    // The version `codexbar-tray --version` reports: the UsageBar release
    // version when the release workflow sets USAGEBAR_VERSION, else Cargo's.
    println!("cargo:rerun-if-env-changed=USAGEBAR_VERSION");
    let version = std::env::var("USAGEBAR_VERSION")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| std::env::var("CARGO_PKG_VERSION").unwrap());
    println!("cargo:rustc-env=TRAY_VERSION={version}");
    tauri_build::build()
}
