// Hide the console window on Windows release builds — devs still get one in dev.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Fine.Shyt desktop shell — Phase C1.
//!
//! What this binary does:
//!
//!   1. Opens a Tauri 2 window pre-loaded with a splash page.
//!   2. On a background thread, runs `make compose-init` (idempotent), then
//!      `docker compose --profile compose up -d --build`.
//!   3. Polls 127.0.0.1:4000 over TCP until Phoenix is listening (or the
//!      timeout fires).
//!   4. On success, navigates the main webview to http://localhost:4000.
//!      On failure, emits `services-failed` so the splash can render the
//!      error message.
//!   5. When the user closes the window, runs `docker compose down` so we
//!      don't leave containers running in the background.
//!
//! What it deliberately doesn't do:
//!
//!   * Bundle the orchestrator / ai_worker / Postgres / Ollama. Those are
//!     phases C2–C5. C1 is "wrap the existing stack in a native window."
//!   * First-run config (PHOTO_LIBRARY, SECRET_KEY_BASE). The compose
//!     stack already validates `.env`; if it's missing, we surface the
//!     compose error to the user rather than reinventing a wizard.
//!   * Single-instance enforcement. If the user double-launches, both
//!     shells will try to bring up compose — Docker handles the second
//!     `up` as a no-op, so it works out, but we should add proper
//!     single-instance for C2.

use std::net::TcpStream;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager, Url};

/// Where Phoenix listens. The Rust shell never overrides this — it has to
/// match what Phoenix actually binds to (4000 in dev, configurable in
/// prod via the `PORT` env var).
const PHOENIX_HOST: &str = "127.0.0.1";
const PHOENIX_PORT: u16 = 4000;

/// How long to wait for Phoenix to come up before declaring failure.
/// First-time docker builds easily push past 60s when images are pulled,
/// so we give the boot pass some breathing room.
const POLL_TIMEOUT: Duration = Duration::from_secs(180);
const POLL_INTERVAL: Duration = Duration::from_millis(500);

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let app_handle = app.handle().clone();

            // The whole startup pipeline runs off the UI thread so the
            // splash window paints immediately and stays interactive.
            std::thread::spawn(move || run_startup_pipeline(&app_handle));

            Ok(())
        })
        .on_window_event(|window, event| {
            // We tear down services when the user closes the main window,
            // not when the OS sends us a "minimize/hide" — so only handle
            // CloseRequested.
            if matches!(event, tauri::WindowEvent::CloseRequested { .. }) {
                let app = window.app_handle();
                shutdown_services(app);
            }
        })
        .run(tauri::generate_context!())
        .expect("fineshyt-desktop: failed to launch tauri app");
}

/// The setup-and-launch sequence. Runs to completion or emits a failure
/// event with the offending error string.
fn run_startup_pipeline(app: &AppHandle) {
    let repo = match repo_root() {
        Ok(p) => p,
        Err(e) => {
            emit_failure(app, format!("couldn't find repo root: {e}"));
            return;
        }
    };

    if let Err(e) = run_compose_init(&repo) {
        emit_failure(
            app,
            format!(
                "make compose-init failed.\n\n\
                 This usually means PHOTO_LIBRARY (or PHOTO_LIBRARIES) \
                 isn't set in .env yet. Open the repo's .env file, set \
                 it to the folder where your photos live, then re-launch.\n\n\
                 Underlying error:\n{e}"
            ),
        );
        return;
    }

    if let Err(e) = run_compose_up(&repo) {
        emit_failure(
            app,
            format!(
                "docker compose up failed.\n\n\
                 Make sure Docker Desktop is running, then re-launch.\n\n\
                 Underlying error:\n{e}"
            ),
        );
        return;
    }

    if let Err(e) = wait_for_phoenix() {
        emit_failure(
            app,
            format!(
                "Services started, but Phoenix never opened port {PHOENIX_PORT} \
                 within {}s. Check the docker compose logs for the orchestrator \
                 container.\n\n\
                 Underlying error:\n{e}",
                POLL_TIMEOUT.as_secs()
            ),
        );
        return;
    }

    // Phoenix is up. Navigate the splash window to the live UI.
    if let Some(window) = app.get_webview_window("main") {
        let url: Url = format!("http://{PHOENIX_HOST}:{PHOENIX_PORT}/")
            .parse()
            .expect("hardcoded URL parses");

        if let Err(e) = window.navigate(url) {
            emit_failure(app, format!("couldn't navigate webview: {e}"));
            return;
        }
    }

    // Belt-and-suspenders: also fire the JS-side event in case the splash
    // wants to do anything specific before the navigation lands.
    let _ = app.emit("services-ready", ());
}

/// Resolves the repo root from CARGO_MANIFEST_DIR (which points at
/// `desktop/src-tauri/` at compile time). Walks up two levels.
fn repo_root() -> Result<PathBuf, String> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .map(|p| p.to_path_buf())
        .ok_or_else(|| {
            format!(
                "CARGO_MANIFEST_DIR ({}) has no parent twice over",
                manifest_dir.display()
            )
        })
}

/// Runs `make compose-init` in the repo root. Idempotent: bootstraps `.env`
/// from `.env.example`, generates SECRET_KEY_BASE if missing, validates
/// PHOTO_LIBRARY is set. Surfaces stderr on failure for visibility.
fn run_compose_init(repo: &PathBuf) -> Result<(), String> {
    let output = Command::new("make")
        .arg("compose-init")
        .current_dir(repo)
        .output()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                "`make` is not on PATH. Install Xcode Command Line Tools (macOS) \
                 or your distro's build-essential package."
                    .to_string()
            } else {
                format!("couldn't spawn make: {e}")
            }
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(format!(
            "make compose-init exited with {:?}\nstdout:\n{stdout}\nstderr:\n{stderr}",
            output.status.code()
        ));
    }

    Ok(())
}

/// Runs `docker compose --profile compose up -d --build`. Detached so we
/// don't keep a streaming-logs child process alive — once compose returns,
/// containers are running independently.
fn run_compose_up(repo: &PathBuf) -> Result<(), String> {
    let output = Command::new("docker")
        .args([
            "compose",
            "--profile",
            "compose",
            "up",
            "-d",
            "--build",
        ])
        .current_dir(repo)
        .output()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                "`docker` is not on PATH. Install Docker Desktop \
                 (https://www.docker.com/products/docker-desktop/) and \
                 launch it before re-opening Fine.Shyt."
                    .to_string()
            } else {
                format!("couldn't spawn docker: {e}")
            }
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "docker compose up exited with {:?}\nstderr:\n{stderr}",
            output.status.code()
        ));
    }

    Ok(())
}

/// TCP-polls Phoenix on 127.0.0.1:4000 until it accepts a connection or
/// the timeout fires. We don't bother with HTTP — a successful TCP connect
/// means Bandit is listening, which is good enough.
fn wait_for_phoenix() -> Result<(), String> {
    let addr = format!("{PHOENIX_HOST}:{PHOENIX_PORT}")
        .parse::<std::net::SocketAddr>()
        .expect("hardcoded socket addr parses");

    let deadline = std::time::Instant::now() + POLL_TIMEOUT;
    let mut last_error: Option<std::io::Error> = None;

    while std::time::Instant::now() < deadline {
        match TcpStream::connect_timeout(&addr, Duration::from_millis(200)) {
            Ok(_) => return Ok(()),
            Err(e) => {
                last_error = Some(e);
                std::thread::sleep(POLL_INTERVAL);
            }
        }
    }

    Err(match last_error {
        Some(e) => format!("last connect error: {e}"),
        None => "timed out before any connect attempt".to_string(),
    })
}

/// Best-effort shutdown: emit a `down` for the compose stack so containers
/// stop. We block on this so the process doesn't exit before docker has
/// settled — Tauri's CloseRequested fires on the UI thread and waits for
/// us to return. Failures are logged but not surfaced; we're already on
/// the way out the door.
fn shutdown_services(app: &AppHandle) {
    let Ok(repo) = repo_root() else {
        eprintln!("fineshyt-desktop: repo_root() failed during shutdown");
        return;
    };

    let result = Command::new("docker")
        .args(["compose", "--profile", "compose", "down"])
        .current_dir(&repo)
        .output();

    match result {
        Ok(output) if !output.status.success() => {
            eprintln!(
                "fineshyt-desktop: docker compose down exited with {:?}\nstderr:\n{}",
                output.status.code(),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        Err(e) => eprintln!("fineshyt-desktop: couldn't run docker compose down: {e}"),
        _ => {}
    }

    // Also let the splash know we're tearing down, in case the user
    // re-opens a Cmd+Q'd window before the cleanup finishes.
    let _ = app.emit("services-shutdown", ());
}

/// Helper to unify the failure event shape. Splash listens for
/// `services-failed` and renders the payload as the error string.
fn emit_failure(app: &AppHandle, message: String) {
    eprintln!("fineshyt-desktop: startup failed:\n{message}");
    let _ = app.emit("services-failed", message);
}
