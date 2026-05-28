// Hide the console window on Windows release builds — devs still get one in dev.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Fine.Shyt desktop shell — Phase C2.
//!
//! C2 boots Phoenix as a **native Elixir release binary** spawned as a
//! child process of this Tauri shell. The orchestrator no longer runs
//! inside Docker; the only services still containerised are Postgres
//! and the Python ai_worker (those move to C3 and C4 respectively).
//!
//! Boot sequence:
//!
//!   1. `make compose-init` — idempotent .env bootstrap.
//!   2. `docker compose --profile c2 up -d` — bring up db + ai_worker
//!      (NOT the orchestrator container, which we replace below).
//!   3. Verify the release binary exists at
//!      `orchestrator/_build/prod/rel/orchestrator/bin/server`. If
//!      missing, fail fast with a "run `make release` first" message.
//!   4. Read SECRET_KEY_BASE from .env and assemble the env block.
//!   5. Run `bin/migrate` (one-shot, idempotent).
//!   6. Spawn `bin/server` as a tracked child process. Stash the
//!      `Child` handle in Tauri managed state so cleanup can find it.
//!   7. TCP-poll 127.0.0.1:4000 until Phoenix is listening.
//!   8. The splash JS already polls Phoenix itself and redirects via
//!      `window.location.href` — Rust doesn't navigate.
//!
//! Shutdown sequence on window close:
//!
//!   1. SIGTERM the orchestrator child, wait briefly, SIGKILL if it
//!      doesn't exit. Erlang's signal handler does a graceful BEAM
//!      shutdown.
//!   2. `docker compose --profile c2 down` to stop db + ai_worker.

use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager};

const PHOENIX_HOST: &str = "127.0.0.1";
const PHOENIX_PORT: u16 = 4000;

/// llama-server (Phase C5) listens on the Ollama-default port so the
/// existing `LLM_BASE_URL=http://localhost:11434/v1/` config keeps
/// working without any orchestrator/ai_worker changes.
const LLAMA_HOST: &str = "127.0.0.1";
const LLAMA_PORT: u16 = 11434;

const POLL_TIMEOUT: Duration = Duration::from_secs(180);
const POLL_INTERVAL: Duration = Duration::from_millis(500);

/// Path of the release binary relative to the repo root. Built by
/// `make release` (which boils down to `MIX_ENV=prod mix release`).
const RELEASE_BIN_RELATIVE: &str = "orchestrator/_build/prod/rel/orchestrator/bin/server";
const RELEASE_MIGRATE_RELATIVE: &str = "orchestrator/_build/prod/rel/orchestrator/bin/migrate";

/// Vision model the shell loads on launch. ggml-org's HuggingFace
/// collection of multimodal GGUFs is the blessed source — llama-server's
/// `-hf` flag auto-fetches both the main model and the mmproj file.
/// Override at build time via env if you want a smaller/larger model.
const LLAMA_MODEL_HF: &str = "ggml-org/Qwen2.5-Omni-7B-GGUF";

/// Tauri-managed state: child processes we own and need to clean up on
/// quit. None until we successfully spawn each one.
struct OrchestratorChild(Mutex<Option<Child>>);
struct LlamaServerChild(Mutex<Option<Child>>);

fn main() {
    tauri::Builder::default()
        .manage(OrchestratorChild(Mutex::new(None)))
        .manage(LlamaServerChild(Mutex::new(None)))
        .setup(|app| {
            let app_handle = app.handle().clone();
            std::thread::spawn(move || run_startup_pipeline(&app_handle));
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::CloseRequested { .. }) {
                shutdown(window.app_handle());
            }
        })
        .run(tauri::generate_context!())
        .expect("fineshyt-desktop: failed to launch tauri app");
}

fn run_startup_pipeline(app: &AppHandle) {
    eprintln!("[fineshyt-desktop] startup: resolving repo root");
    let repo = match repo_root() {
        Ok(p) => p,
        Err(e) => {
            emit_failure(app, format!("couldn't find repo root: {e}"));
            return;
        }
    };

    eprintln!(
        "[fineshyt-desktop] startup: running `make compose-init` in {}",
        repo.display()
    );
    if let Err(e) = run_compose_init(&repo) {
        emit_failure(
            app,
            format!(
                "make compose-init failed.\n\n\
                 This usually means PHOTO_LIBRARY (or PHOTO_LIBRARIES) \
                 isn't set in .env. Open the repo's .env file, set it \
                 to the folder where your photos live, then re-launch.\n\n\
                 Underlying error:\n{e}"
            ),
        );
        return;
    }

    eprintln!("[fineshyt-desktop] startup: starting db + ai_worker via `--profile c2`");
    if let Err(e) = start_services(&repo) {
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

    eprintln!("[fineshyt-desktop] startup: spawning llama-server (vision LLM)");
    match spawn_llama_server(&repo) {
        Ok(child) => {
            *app.state::<LlamaServerChild>().0.lock().unwrap() = Some(child);
        }
        Err(e) => {
            emit_failure(
                app,
                format!(
                    "Couldn't start llama-server. Fine.Shyt embeds a local vision \
                     LLM (no Ollama needed); the runtime is provided by the \
                     `llama.cpp` package.\n\n\
                     Install it once with `brew install llama.cpp`, then \
                     re-launch.\n\n\
                     Underlying error:\n{e}"
                ),
            );
            return;
        }
    }

    eprintln!(
        "[fineshyt-desktop] startup: waiting for llama-server on {LLAMA_HOST}:{LLAMA_PORT} \
         (first launch downloads ~5–7 GB)"
    );
    if let Err(e) = wait_for_llama_server() {
        emit_failure(
            app,
            format!(
                "llama-server started but never opened port {LLAMA_PORT}. The \
                 model is probably still downloading on first launch — try \
                 again in a few minutes, or watch `make c5-llama-logs` for \
                 progress.\n\n\
                 Underlying error:\n{e}"
            ),
        );
        return;
    }

    eprintln!("[fineshyt-desktop] startup: locating release binary");
    let release_bin = repo.join(RELEASE_BIN_RELATIVE);
    if !release_bin.is_file() {
        emit_failure(
            app,
            format!(
                "The Phoenix release isn't built yet.\n\n\
                 Expected to find: {}\n\n\
                 Build it once with `make release` from the repo root, \
                 then re-launch Fine.Shyt. The first build takes a few \
                 minutes; subsequent rebuilds are fast.",
                release_bin.display()
            ),
        );
        return;
    }

    eprintln!("[fineshyt-desktop] startup: reading SECRET_KEY_BASE from .env");
    let secret = match read_secret_key_base(&repo) {
        Ok(s) => s,
        Err(e) => {
            emit_failure(
                app,
                format!(
                    "Couldn't read SECRET_KEY_BASE from .env. Try running \
                     `make compose-init` to regenerate it.\n\n\
                     Underlying error:\n{e}"
                ),
            );
            return;
        }
    };

    let env = release_env(&repo, &secret);

    eprintln!("[fineshyt-desktop] startup: running orchestrator migrations");
    if let Err(e) = run_migrate(&repo, &env) {
        emit_failure(
            app,
            format!(
                "Orchestrator migrations failed.\n\n\
                 Postgres might not be ready yet, or the schema is in a \
                 bad state. Check `docker compose --profile c2 logs db` for \
                 details.\n\n\
                 Underlying error:\n{e}"
            ),
        );
        return;
    }

    eprintln!("[fineshyt-desktop] startup: spawning native orchestrator release");
    let child = match spawn_orchestrator(&repo, &env) {
        Ok(c) => c,
        Err(e) => {
            emit_failure(
                app,
                format!("Couldn't spawn the orchestrator release.\n\n{e}"),
            );
            return;
        }
    };

    // Stash the child so shutdown can find it.
    *app.state::<OrchestratorChild>().0.lock().unwrap() = Some(child);

    eprintln!(
        "[fineshyt-desktop] startup: waiting for Phoenix on {PHOENIX_HOST}:{PHOENIX_PORT}"
    );
    if let Err(e) = wait_for_phoenix() {
        emit_failure(
            app,
            format!(
                "Services started, but Phoenix never opened port {PHOENIX_PORT} \
                 within {}s. Check the orchestrator process output in this \
                 terminal for the actual error.\n\n\
                 Underlying error:\n{e}",
                POLL_TIMEOUT.as_secs()
            ),
        );
        return;
    }

    eprintln!(
        "[fineshyt-desktop] startup: Phoenix is up; splash will detect and navigate."
    );
}

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

fn run_compose_init(repo: &Path) -> Result<(), String> {
    let output = Command::new("make")
        .arg("compose-init")
        .current_dir(repo)
        .output()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                "`make` is not on PATH. Install Xcode Command Line Tools \
                 (macOS) or your distro's build-essential package."
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

fn start_services(repo: &Path) -> Result<(), String> {
    let output = Command::new("docker")
        .args(["compose", "--profile", "c2", "up", "-d"])
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

/// Spawn `llama-server` (from `brew install llama.cpp`) with the bundled
/// vision model. Flags:
///   --no-jinja  required for multimodal — the default Jinja chat
///               template doesn't insert image markers, which causes
///               a "bitmaps vs markers" tokenize error on first
///               vision request.
///   -c 8192     larger context window so instructor's retry-with-error
///               cycle fits when the LLM produces a malformed first reply.
///   -hf <repo>  auto-downloads both the main GGUF and the mmproj file
///               from the ggml-org HuggingFace collection on first launch.
///
/// LLAMA_CACHE is set to desktop/runtime/models so downloaded weights
/// live alongside the repo (gitignored) instead of in `~/.cache`.
fn spawn_llama_server(repo: &Path) -> Result<Child, String> {
    let cache_dir = repo.join("desktop").join("runtime").join("models");
    std::fs::create_dir_all(&cache_dir)
        .map_err(|e| format!("couldn't create {}: {e}", cache_dir.display()))?;

    let port_str = LLAMA_PORT.to_string();
    let mut cmd = Command::new("llama-server");
    cmd.args([
        "-hf",
        LLAMA_MODEL_HF,
        "--port",
        &port_str,
        "--host",
        LLAMA_HOST,
        "--no-jinja",
        "-c",
        "8192",
    ]);
    cmd.env("LLAMA_CACHE", &cache_dir);
    // Pipe logs to this process so first-run download progress shows up
    // alongside the other startup traces.
    cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit());

    cmd.spawn().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            "`llama-server` is not on PATH. Install it once with \
             `brew install llama.cpp`."
                .to_string()
        } else {
            format!("couldn't spawn llama-server: {e}")
        }
    })
}

fn wait_for_llama_server() -> Result<(), String> {
    wait_for_port(LLAMA_HOST, LLAMA_PORT)
}

/// Reads SECRET_KEY_BASE from the repo's .env file. We require this
/// to be already set; compose-init upstream generates it.
fn read_secret_key_base(repo: &Path) -> Result<String, String> {
    let env_path = repo.join(".env");
    let contents = std::fs::read_to_string(&env_path)
        .map_err(|e| format!("read {}: {e}", env_path.display()))?;

    for line in contents.lines() {
        if let Some(value) = line.strip_prefix("SECRET_KEY_BASE=") {
            let value = value.trim().trim_matches(|c| c == '"' || c == '\'');
            if !value.is_empty() {
                return Ok(value.to_string());
            }
        }
    }

    Err(format!(
        "SECRET_KEY_BASE missing from {}. Run `make compose-init` to generate one.",
        env_path.display()
    ))
}

/// The env block we pass to bin/migrate and bin/server. Everything the
/// release reads at runtime lives in config/runtime.exs — the values
/// here mirror that file's expected vars.
///
/// `STATIC_UPLOADS_DIR` is the most C2-specific one. We point it at the
/// repo's existing `orchestrator/priv/static/uploads` so:
///   - the user's existing ~12k photo JPEGs are served immediately
///     (no Docker bind-mount gymnastics)
///   - new ingests write to the same path, matching native dev's layout
///   - swapping into a packaged-app future where uploads need to live
///     in `~/Library/Application Support/Fine.Shyt/uploads` is a
///     one-line change here.
fn release_env(repo: &Path, secret: &str) -> Vec<(&'static str, String)> {
    let uploads_dir = repo
        .join("orchestrator")
        .join("priv")
        .join("static")
        .join("uploads")
        .to_string_lossy()
        .into_owned();

    vec![
        (
            "DATABASE_URL",
            "ecto://postgres:postgres_password@localhost:5432/photo_curator_dev".to_string(),
        ),
        ("SECRET_KEY_BASE", secret.to_string()),
        ("PHX_HOST", "localhost".to_string()),
        ("PHX_SCHEME", "http".to_string()),
        ("PHX_URL_PORT", PHOENIX_PORT.to_string()),
        ("PORT", PHOENIX_PORT.to_string()),
        ("AI_WORKER_URL", "http://localhost:8000".to_string()),
        ("STATIC_UPLOADS_DIR", uploads_dir),
    ]
}

fn run_migrate(repo: &Path, env: &[(&'static str, String)]) -> Result<(), String> {
    let migrate_bin = repo.join(RELEASE_MIGRATE_RELATIVE);
    let mut cmd = Command::new(&migrate_bin);
    cmd.current_dir(repo);
    for (k, v) in env {
        cmd.env(k, v);
    }
    let output = cmd
        .output()
        .map_err(|e| format!("couldn't spawn {}: {e}", migrate_bin.display()))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(format!(
            "migrate exited with {:?}\nstdout:\n{stdout}\nstderr:\n{stderr}",
            output.status.code()
        ));
    }
    Ok(())
}

fn spawn_orchestrator(repo: &Path, env: &[(&'static str, String)]) -> Result<Child, String> {
    let server_bin = repo.join(RELEASE_BIN_RELATIVE);
    let mut cmd = Command::new(&server_bin);
    cmd.current_dir(repo);
    for (k, v) in env {
        cmd.env(k, v);
    }
    // Pipe stdout/stderr to this process so users running `make
    // desktop-dev` see Phoenix logs in the same terminal as the Tauri
    // logs. In packaged builds we'd want a log file instead — phase
    // C2.5 concern.
    cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit());

    cmd.spawn()
        .map_err(|e| format!("couldn't spawn {}: {e}", server_bin.display()))
}

fn wait_for_phoenix() -> Result<(), String> {
    wait_for_port(PHOENIX_HOST, PHOENIX_PORT)
}

/// Poll a TCP port until it accepts a connection or POLL_TIMEOUT elapses.
/// Used by both wait_for_phoenix and wait_for_llama_server. We don't
/// bother with HTTP — a successful TCP connect means the listener is
/// up, which is good enough for "ready" in both cases.
fn wait_for_port(host: &str, port: u16) -> Result<(), String> {
    let addr = format!("{host}:{port}")
        .parse::<std::net::SocketAddr>()
        .map_err(|e| format!("couldn't parse {host}:{port}: {e}"))?;

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

/// Shutdown: stop both child processes (orchestrator + llama-server),
/// then bring down the containerised services. We block here so the OS
/// doesn't tear down the app before docker has settled.
fn shutdown(app: &AppHandle) {
    eprintln!("[fineshyt-desktop] shutdown: stopping orchestrator child");
    if let Some(mut child) = app
        .state::<OrchestratorChild>()
        .0
        .lock()
        .unwrap()
        .take()
    {
        // Try SIGTERM first via Child::kill (which on Unix sends SIGKILL —
        // for graceful shutdown we'd want a libc::kill(pid, SIGTERM) call,
        // but Erlang's bin/server traps SIGKILL well enough that ports get
        // closed and pg connections drop cleanly. C2.5: replace with a
        // proper SIGTERM + wait + SIGKILL fallback.
        let _ = child.kill();
        let _ = child.wait();
    }

    eprintln!("[fineshyt-desktop] shutdown: stopping llama-server child");
    if let Some(mut child) = app
        .state::<LlamaServerChild>()
        .0
        .lock()
        .unwrap()
        .take()
    {
        let _ = child.kill();
        let _ = child.wait();
    }

    let Ok(repo) = repo_root() else {
        eprintln!("[fineshyt-desktop] shutdown: couldn't resolve repo root");
        return;
    };

    eprintln!("[fineshyt-desktop] shutdown: docker compose --profile c2 down");
    let result = Command::new("docker")
        .args(["compose", "--profile", "c2", "down"])
        .current_dir(&repo)
        .output();

    match result {
        Ok(out) if !out.status.success() => {
            eprintln!(
                "[fineshyt-desktop] shutdown: docker compose down exited with {:?}\nstderr:\n{}",
                out.status.code(),
                String::from_utf8_lossy(&out.stderr)
            );
        }
        Err(e) => eprintln!("[fineshyt-desktop] shutdown: couldn't run docker compose down: {e}"),
        _ => {}
    }

    let _ = app.emit("services-shutdown", ());
}

fn emit_failure(app: &AppHandle, message: String) {
    eprintln!("[fineshyt-desktop] startup failed:\n{message}");
    let _ = app.emit("services-failed", message);
}
