// Hide the console window on Windows release builds — devs still get one in dev.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Fineshyt desktop shell — Phase C4 (in progress).
//!
//! All three runtime services run **natively** as child processes of this
//! Tauri shell — no Docker:
//!   - **Orchestrator** = native Elixir release (C2).
//!   - **Vision LLM** = native `llama-server` from llama.cpp (C5).
//!   - **AI worker** = native PyApp launcher (C4) — a tiny Rust binary that
//!     bootstraps a Python venv + the FastAPI worker on first run.
//! Since C3 the database is a native SQLite file; Postgres + pgvector are
//! gone.
//!
//! Boot sequence:
//!
//!   1. Spawn the PyApp ai_worker launcher; spawn `llama-server` (both
//!      bind their own ports; they initialise in parallel).
//!   2. TCP-poll both ports until each is listening. First launch of the
//!      ai_worker pip-installs deps into a per-user venv (a few minutes
//!      on a cold machine); first launch of llama-server downloads the
//!      vision GGUF (~5–7 GB).
//!   3. Resolve the Phoenix release binary via Tauri's resource path
//!      manager (dev: project layout, bundled: `<App>/Contents/Resources/
//!      phoenix/bin/server`). Fail fast with a "run `make release` first"
//!      message if missing in dev.
//!   4. Ensure SECRET_KEY_BASE: read from `.env` (dev) or
//!      `<app_data_dir>/secret_key_base` (bundled), generating on first
//!      run if missing. Assemble the env block.
//!   5. Run `bin/migrate` (one-shot, idempotent).
//!   6. Spawn `bin/server` as a tracked child process. Stash all `Child`
//!      handles in Tauri managed state so cleanup can find them.
//!   7. TCP-poll 127.0.0.1:4000 until Phoenix is listening.
//!   8. The splash JS already polls Phoenix itself and redirects via
//!      `window.location.href` — Rust doesn't navigate.
//!
//! Shutdown sequence on window close: SIGKILL each tracked child
//! (orchestrator, llama-server, ai_worker) and wait for it to exit.
//! Erlang's signal handler does a graceful BEAM shutdown; the PyApp
//! launcher tree is just Python so SIGKILL is fine.

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

/// Native ai_worker (Phase C4) — a PyApp launcher built by
/// `make ai-worker-launcher`. It bootstraps a per-user Python venv +
/// FastAPI on first run, then binds this port.
const AI_WORKER_HOST: &str = "127.0.0.1";
const AI_WORKER_PORT: u16 = 8000;
/// Path of the launcher INSIDE a bundled `.app` (relative to
/// `Resources/`). In dev (`cargo run`) Tauri's path manager points
/// resource_dir() at the project's `runtime/` layout so the same
/// relative path resolves either way. See `tauri.conf.json`'s
/// `bundle.resources` for the source-side mapping.
const AI_WORKER_LAUNCHER_BUNDLED: &str = "bin/fineshyt-ai-worker";

const POLL_TIMEOUT: Duration = Duration::from_secs(180);
/// Longer fallback for the ai_worker's first launch: PyApp downloads
/// Python + pip-installs deps (~1 GB) into the per-user venv before
/// uvicorn binds. After the cache is populated subsequent launches are
/// seconds.
const AI_WORKER_POLL_TIMEOUT: Duration = Duration::from_secs(600);
const POLL_INTERVAL: Duration = Duration::from_millis(500);

/// Path of the release binary INSIDE a bundled `.app` (relative to
/// `Resources/`). The whole release tree (~46 MB) ships under `phoenix/`
/// via `tauri.conf.json`'s `bundle.resources` glob. Built by `make
/// release` (which boils down to `MIX_ENV=prod mix release`).
const RELEASE_BIN_BUNDLED: &str = "phoenix/bin/server";
const RELEASE_MIGRATE_BUNDLED: &str = "phoenix/bin/migrate";

/// Vision model the shell loads on launch. ggml-org's HuggingFace
/// collection of multimodal GGUFs is the blessed source — llama-server's
/// `-hf` flag auto-fetches both the main model and the mmproj file.
/// Override at build time via env if you want a smaller/larger model.
const LLAMA_MODEL_HF: &str = "ggml-org/Qwen2.5-Omni-7B-GGUF";

/// Tauri-managed state: child processes we own and need to clean up on
/// quit. None until we successfully spawn each one.
struct OrchestratorChild(Mutex<Option<Child>>);
struct LlamaServerChild(Mutex<Option<Child>>);
struct AiWorkerChild(Mutex<Option<Child>>);

/// Last-known startup state, queryable by the splash. Solves the race where
/// Rust emits `services-failed` or `startup-phase` *before* the JS listener
/// is registered — Tauri's `emit` is fire-and-forget, so without this, the
/// fastest failure paths (e.g. llama-server not found) drop the event on
/// the floor and the splash spins forever.
#[derive(Default, Clone, serde::Serialize)]
struct StartupState {
    phase_label: Option<String>,
    phase_detail: Option<String>,
    failure: Option<String>,
}

struct StartupStateLock(Mutex<StartupState>);

#[tauri::command]
fn get_startup_state(state: tauri::State<'_, StartupStateLock>) -> StartupState {
    state.0.lock().unwrap().clone()
}

fn main() {
    tauri::Builder::default()
        .manage(OrchestratorChild(Mutex::new(None)))
        .manage(LlamaServerChild(Mutex::new(None)))
        .manage(AiWorkerChild(Mutex::new(None)))
        .manage(StartupStateLock(Mutex::new(StartupState::default())))
        .invoke_handler(tauri::generate_handler![get_startup_state])
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

    let first_run_ai = is_first_launch_ai_worker();
    let first_run_llama = is_first_launch_llama(app);

    // No `make compose-init` step here: the bundled app has no Makefile,
    // and the desktop path doesn't use docker-compose anyway. The maintainer
    // can still run `make compose-init` manually in dev for the compose
    // path. SECRET_KEY_BASE is handled below in `ensure_secret_key_base`.

    emit_phase(
        app,
        "Starting AI worker",
        if first_run_ai {
            "First launch — installing Python dependencies (~1 GB, 2–5 min). \
             No progress bar yet, just patience."
        } else {
            "Loading the Python environment."
        },
    );
    eprintln!("[fineshyt-desktop] startup: spawning ai_worker (PyApp launcher)");
    match spawn_ai_worker(app, &repo) {
        Ok(mut child) => {
            if let Err(e) = verify_alive(&mut child, "ai_worker", AI_WORKER_PORT) {
                let _ = child.wait();
                emit_failure(app, e);
                return;
            }
            *app.state::<AiWorkerChild>().0.lock().unwrap() = Some(child);
        }
        Err(e) => {
            emit_failure(
                app,
                format!(
                    "Couldn't start the ai_worker.\n\n\
                     Build the PyApp launcher once with `make ai-worker-launcher` \
                     from the repo root, then re-launch.\n\n\
                     Underlying error:\n{e}"
                ),
            );
            return;
        }
    }

    emit_phase(
        app,
        "Starting vision LLM",
        if first_run_llama {
            "First launch — downloading the Qwen2.5-Omni-7B model (~4 GB, \
             5–10 min on a fast connection). It runs entirely on your machine."
        } else {
            "Loading the vision model."
        },
    );
    eprintln!("[fineshyt-desktop] startup: spawning llama-server (vision LLM)");
    match spawn_llama_server(&app, &repo) {
        Ok(mut child) => {
            if let Err(e) = verify_alive(&mut child, "llama-server", LLAMA_PORT) {
                let _ = child.wait();
                emit_failure(app, e);
                return;
            }
            *app.state::<LlamaServerChild>().0.lock().unwrap() = Some(child);
        }
        Err(e) => {
            emit_failure(
                app,
                format!(
                    "Couldn't start llama-server. Fineshyt embeds a local vision \
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

    // ai_worker and llama-server initialise in parallel — both children are
    // already spawned. Wait sequentially for each port; total wall time is
    // max(ai_worker_ready, llama_ready), not the sum.
    eprintln!(
        "[fineshyt-desktop] startup: waiting for ai_worker on {AI_WORKER_HOST}:{AI_WORKER_PORT} \
         (first launch pip-installs ~1 GB of deps into a per-user venv)"
    );
    if let Err(e) = wait_for_ai_worker() {
        emit_failure(
            app,
            format!(
                "ai_worker started but never opened port {AI_WORKER_PORT}. On \
                 first launch PyApp installs Python deps; if the network is \
                 slow this can take several minutes — try again, or check \
                 the launcher's logs in the terminal.\n\n\
                 Underlying error:\n{e}"
            ),
        );
        return;
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
    let release_bin = match resolve_resource(app, RELEASE_BIN_BUNDLED) {
        Ok(p) => p,
        Err(e) => {
            emit_failure(app, format!("couldn't resolve release path: {e}"));
            return;
        }
    };
    if !release_bin.is_file() {
        emit_failure(
            app,
            format!(
                "The Phoenix release isn't built yet.\n\n\
                 Expected to find: {}\n\n\
                 Build it once with `make release` from the repo root, \
                 then re-launch Fineshyt. The first build takes a few \
                 minutes; subsequent rebuilds are fast.",
                release_bin.display()
            ),
        );
        return;
    }

    eprintln!("[fineshyt-desktop] startup: ensuring SECRET_KEY_BASE");
    let secret = match ensure_secret_key_base(app, &repo) {
        Ok(s) => s,
        Err(e) => {
            emit_failure(
                app,
                format!(
                    "Couldn't read or generate SECRET_KEY_BASE.\n\n\
                     Underlying error:\n{e}"
                ),
            );
            return;
        }
    };

    let env = match release_env(app, &repo, &secret) {
        Ok(e) => e,
        Err(e) => {
            emit_failure(
                app,
                format!(
                    "Couldn't resolve the orchestrator's data directories.\n\n\
                     Underlying error:\n{e}"
                ),
            );
            return;
        }
    };

    eprintln!("[fineshyt-desktop] startup: running orchestrator migrations");
    if let Err(e) = run_migrate(app, &repo, &env) {
        emit_failure(
            app,
            format!(
                "Orchestrator migrations failed.\n\n\
                 The SQLite database file may not be writable, or the schema \
                 is in a bad state. Check that DATABASE_PATH's directory is \
                 writable.\n\n\
                 Underlying error:\n{e}"
            ),
        );
        return;
    }

    emit_phase(app, "Starting Phoenix", "Warming up the archive UI.");
    eprintln!("[fineshyt-desktop] startup: spawning native orchestrator release");
    let child = match spawn_orchestrator(app, &repo, &env) {
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

/// Resolve a bundled resource path.
///
/// We don't go through `app.path().resource_dir()` because Tauri's path
/// resolver returns "unknown path" when queried from a setup-spawned thread
/// in some launch contexts (running the inner binary directly, vs being
/// launched via `open`/NSWorkspace). Computing the resource directory from
/// `current_exe()` directly is the same calculation Tauri does internally
/// for bundled .app/.exe layouts, and works deterministically regardless of
/// how the binary was started.
///
/// In dev (`cargo run`) the binary lives at `target/debug/` and we fall
/// through to the repo's `desktop/runtime/` layout — the same paths
/// tauri.conf.json's `bundle.resources` points at.
fn resolve_resource(_app: &AppHandle, rel: &str) -> Result<PathBuf, String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("current_exe failed: {e}"))?;

    // Bundled macOS layout: <Bundle>.app/Contents/MacOS/<binary>
    //   resources at        <Bundle>.app/Contents/Resources/<rel>
    // The "Contents/MacOS" pair is the tell.
    let in_bundle = exe
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        == Some("MacOS")
        && exe
            .parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            == Some("Contents");

    if in_bundle {
        let resources = exe
            .parent()
            .and_then(|p| p.parent())
            .map(|p| p.join("Resources"))
            .ok_or_else(|| "couldn't derive Resources from current_exe".to_string())?;
        return Ok(resources.join(rel));
    }

    // Dev fallback: tauri.conf.json's `bundle.resources` source paths are
    // relative to desktop/src-tauri/ — `../runtime/...`. From the repo root
    // that's `desktop/runtime/...`. We map the dest (`bin/...`,
    // `phoenix/...`) back to the source layout so a single resolve call
    // works in both modes.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let runtime = manifest_dir
        .parent()
        .map(|p| p.join("runtime"))
        .ok_or_else(|| "CARGO_MANIFEST_DIR has no parent".to_string())?;
    Ok(runtime.join(rel))
}

/// Spawn the PyApp ai_worker launcher (Phase C4 — replaces the previous
/// Docker container). The launcher is a ~3 MB Rust binary that on first
/// run pip-installs the FastAPI worker + its deps into a per-user venv
/// (`~/Library/Application Support/pyapp/ai-worker/<hash>/<ver>/`); on
/// subsequent runs it just re-execs the existing venv's Python entry.
///
/// The launcher binary is shipped as a Tauri bundle resource — `app.path()
/// .resource_dir()` works in both dev (resolves to the project layout)
/// and bundled (`<App>/Contents/Resources/`).
fn spawn_ai_worker(app: &AppHandle, repo: &Path) -> Result<Child, String> {
    let launcher = resolve_resource(app, AI_WORKER_LAUNCHER_BUNDLED)?;
    if !launcher.is_file() {
        return Err(format!(
            "PyApp launcher not built. Expected: {}\n\n\
             Build it once with `make ai-worker-launcher` from the repo \
             root — uses uv + cargo, takes ~1 min.",
            launcher.display()
        ));
    }

    let (uploads_dir, _db_path) = data_paths(app, repo)?;

    let mut cmd = Command::new(&launcher);
    cmd.env("AI_WORKER_HOST", AI_WORKER_HOST);
    cmd.env("AI_WORKER_PORT", AI_WORKER_PORT.to_string());
    cmd.env("STATIC_UPLOADS_DIR", &uploads_dir);
    // The worker calls llama-server at host:11434; from a native process
    // that's just localhost (no host.docker.internal needed any more).
    cmd.env("LLM_BASE_URL", format!("http://{LLAMA_HOST}:{LLAMA_PORT}/v1/"));
    // Pipe logs so first-run pip output is visible alongside Tauri's own.
    cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit());

    cmd.spawn().map_err(|e| {
        format!(
            "couldn't spawn {}: {e}",
            launcher.display()
        )
    })
}

fn wait_for_ai_worker() -> Result<(), String> {
    wait_for_port_with_timeout(AI_WORKER_HOST, AI_WORKER_PORT, AI_WORKER_POLL_TIMEOUT)
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
/// LLAMA_CACHE points at:
///   * dev (`cargo run`): `<repo>/desktop/runtime/models` — keeps downloaded
///     weights alongside the repo so iteration doesn't re-download a 4 GB
///     GGUF on every clean.
///   * bundled `.app` (release): `<app_data_dir>/llama-cache` — a writable
///     per-user dir. The previous behaviour used `env!("CARGO_MANIFEST_DIR")`
///     baked at build time, which resolved to the CI runner's path
///     (`/Users/runner/work/fineshyt/...`) at runtime and crashed on every
///     non-developer install with `Permission denied`.
fn spawn_llama_server(app: &AppHandle, repo: &Path) -> Result<Child, String> {
    let cache_dir = if cfg!(debug_assertions) {
        repo.join("desktop").join("runtime").join("models")
    } else {
        app.path()
            .app_data_dir()
            .map_err(|e| format!("couldn't resolve app_data_dir: {e}"))?
            .join("llama-cache")
    };
    std::fs::create_dir_all(&cache_dir)
        .map_err(|e| format!("couldn't create {}: {e}", cache_dir.display()))?;

    let llama_bin = find_llama_server().ok_or_else(|| {
        "`llama-server` couldn't be found. Install it once with \
         `brew install llama.cpp`, then re-launch."
            .to_string()
    })?;

    let port_str = LLAMA_PORT.to_string();
    let mut cmd = Command::new(&llama_bin);
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

    cmd.spawn()
        .map_err(|e| format!("couldn't spawn {}: {e}", llama_bin.display()))
}

/// Find the `llama-server` binary, working around a macOS quirk:
/// `.app` bundles launched from Finder don't inherit the user's shell PATH,
/// only the stripped-down launchd PATH (`/usr/bin:/bin:/usr/sbin:/sbin`).
/// Homebrew installs to `/opt/homebrew/bin/` (Apple Silicon) or
/// `/usr/local/bin/` (Intel), neither of which is in that minimal set.
///
/// We try the well-known install locations first, then fall back to a PATH
/// lookup via `which` so dev launches (which DO have the shell PATH) keep
/// working. This is a stopgap — Phase 2 should bundle llama-server into
/// the .app/.msi so users don't need brew at all.
fn find_llama_server() -> Option<PathBuf> {
    // Apple Silicon Homebrew default. Most likely on modern Macs.
    let known = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
        "/opt/local/bin/llama-server",
    ];
    for candidate in known {
        let p = PathBuf::from(candidate);
        if p.is_file() {
            return Some(p);
        }
    }
    // Final fallback — full PATH lookup. This works in dev (cargo run
    // inherits the shell PATH) but typically fails for .app launches.
    let out = Command::new("/usr/bin/which")
        .arg("llama-server")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let path = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(PathBuf::from(path))
    }
}

fn wait_for_llama_server() -> Result<(), String> {
    wait_for_port(LLAMA_HOST, LLAMA_PORT)
}

/// Read SECRET_KEY_BASE, generating + persisting one on first run.
///
/// Dev builds keep using the repo `.env` so the maintainer's existing value
/// stays in place. Release builds persist to `<app_data_dir>/secret_key_base`
/// — a one-line file (no .env parsing needed in the bundled shape). 48
/// random bytes, base64-encoded, matching what `mix phx.gen.secret` writes.
fn ensure_secret_key_base(app: &AppHandle, repo: &Path) -> Result<String, String> {
    if cfg!(debug_assertions) {
        return read_or_generate_in_env(repo);
    }

    use tauri::Manager;
    let data_root = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("couldn't resolve app_data_dir: {e}"))?;
    std::fs::create_dir_all(&data_root)
        .map_err(|e| format!("couldn't create {}: {e}", data_root.display()))?;

    let secret_path = data_root.join("secret_key_base");
    if secret_path.is_file() {
        let s = std::fs::read_to_string(&secret_path)
            .map_err(|e| format!("read {}: {e}", secret_path.display()))?;
        let trimmed = s.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }

    let secret = generate_secret_key_base();
    std::fs::write(&secret_path, &secret)
        .map_err(|e| format!("write {}: {e}", secret_path.display()))?;
    Ok(secret)
}

fn read_or_generate_in_env(repo: &Path) -> Result<String, String> {
    let env_path = repo.join(".env");

    if env_path.is_file() {
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
    }

    // Generate and append. .env may exist but lack the key, or be missing
    // entirely — append-or-create is fine either way.
    let secret = generate_secret_key_base();
    let line = format!("SECRET_KEY_BASE={secret}\n");
    let combined = match std::fs::read_to_string(&env_path) {
        Ok(s) if s.ends_with('\n') => s + &line,
        Ok(s) => s + "\n" + &line,
        Err(_) => line,
    };
    std::fs::write(&env_path, combined)
        .map_err(|e| format!("write {}: {e}", env_path.display()))?;
    Ok(secret)
}

/// 48 random bytes → base64. Same shape `mix phx.gen.secret` emits.
fn generate_secret_key_base() -> String {
    use base64::Engine;
    use rand::RngCore;
    let mut bytes = [0u8; 48];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// The env block we pass to bin/migrate and bin/server. Everything the
/// release reads at runtime lives in config/runtime.exs — the values
/// here mirror that file's expected vars.
///
/// `STATIC_UPLOADS_DIR` + `DATABASE_PATH` are environment-split:
///   - **Dev build** (`cargo run` / `make desktop-dev`) — point at the
///     repo's `orchestrator/priv/...` so the maintainer's existing ~12k
///     photo JPEGs + SQLite db keep working.
///   - **Bundled .app** (`cargo tauri build`) — point at the OS-specific
///     app-data dir (macOS: `~/Library/Application Support/Fineshyt/`).
///     The Phoenix app creates the file + parent dir on boot
///     (see `Orchestrator.Application.ensure_db_dir/0` +
///     `ensure_uploads_symlink/0`).
/// Where the orchestrator's mutable state lives (uploads dir + SQLite db).
/// Dev builds keep using the in-repo `orchestrator/priv/` so the maintainer's
/// existing data carries over; release builds move to the OS-specific app-data
/// dir (Tauri picks the right thing per-OS — `~/Library/Application Support/
/// Fineshyt/` on macOS, `%APPDATA%/Fineshyt/` on Windows, `$XDG_DATA_HOME/
/// Fineshyt/` on Linux). Single source of truth for both `release_env` and
/// `spawn_ai_worker`.
fn data_paths(app: &AppHandle, repo: &Path) -> Result<(PathBuf, PathBuf), String> {
    if cfg!(debug_assertions) {
        let priv_dir = repo.join("orchestrator").join("priv");
        Ok((
            priv_dir.join("static").join("uploads"),
            priv_dir.join("fineshyt.db"),
        ))
    } else {
        use tauri::Manager;
        let data_root = app
            .path()
            .app_data_dir()
            .map_err(|e| format!("couldn't resolve app_data_dir: {e}"))?;
        std::fs::create_dir_all(&data_root)
            .map_err(|e| format!("couldn't create {}: {e}", data_root.display()))?;
        Ok((data_root.join("uploads"), data_root.join("fineshyt.db")))
    }
}

fn release_env(
    app: &AppHandle,
    repo: &Path,
    secret: &str,
) -> Result<Vec<(&'static str, String)>, String> {
    let (uploads_dir, database_path) = data_paths(app, repo)?;
    let uploads_dir = uploads_dir.to_string_lossy().into_owned();
    let database_path = database_path.to_string_lossy().into_owned();

    Ok(vec![
        ("DATABASE_PATH", database_path),
        ("SECRET_KEY_BASE", secret.to_string()),
        ("PHX_HOST", "localhost".to_string()),
        ("PHX_SCHEME", "http".to_string()),
        ("PHX_URL_PORT", PHOENIX_PORT.to_string()),
        ("PORT", PHOENIX_PORT.to_string()),
        ("AI_WORKER_URL", "http://localhost:8000".to_string()),
        ("STATIC_UPLOADS_DIR", uploads_dir),
    ])
}

fn run_migrate(
    app: &AppHandle,
    repo: &Path,
    env: &[(&'static str, String)],
) -> Result<(), String> {
    let migrate_bin = resolve_resource(app, RELEASE_MIGRATE_BUNDLED)?;
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

fn spawn_orchestrator(
    app: &AppHandle,
    repo: &Path,
    env: &[(&'static str, String)],
) -> Result<Child, String> {
    let server_bin = resolve_resource(app, RELEASE_BIN_BUNDLED)?;
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

/// Briefly verify a freshly-spawned child is still alive. Catches the most
/// common silent failure mode: the child exits within ~1s because its port
/// is already in use (a leaked previous run). Without this check the boot
/// pipeline would poll a port that some *other* (leaked) process is
/// serving, and either timeout 10 min later or — worse — succeed against
/// the wrong process. The child's stderr is inherit'd so the real error
/// message (e.g. "address already in use") appears in the terminal above.
fn verify_alive(child: &mut Child, name: &str, port: u16) -> Result<(), String> {
    std::thread::sleep(Duration::from_secs(1));
    match child.try_wait() {
        Ok(Some(status)) => Err(format!(
            "{name} exited immediately ({status}).\n\n\
             Almost always means port {port} is already in use by a leaked \
             previous run. See the terminal above for the underlying error.\n\n\
             Clean up with:\n  \
             lsof -ti:{port} | xargs kill -9\n\
             pkill -9 -f 'fineshyt-ai-worker|fineshyt_ai.serve|llama-server'\n\
             then re-launch."
        )),
        Ok(None) => Ok(()),
        Err(e) => Err(format!("couldn't check {name} status: {e}")),
    }
}

/// Poll a TCP port until it accepts a connection or POLL_TIMEOUT elapses.
/// Used by Phoenix + llama-server; the ai_worker uses the longer-timeout
/// variant below because PyApp's first launch can pip-install for several
/// minutes. We don't bother with HTTP — a successful TCP connect means
/// the listener is up, which is good enough for "ready" in all cases.
fn wait_for_port(host: &str, port: u16) -> Result<(), String> {
    wait_for_port_with_timeout(host, port, POLL_TIMEOUT)
}

fn wait_for_port_with_timeout(host: &str, port: u16, timeout: Duration) -> Result<(), String> {
    let addr = format!("{host}:{port}")
        .parse::<std::net::SocketAddr>()
        .map_err(|e| format!("couldn't parse {host}:{port}: {e}"))?;

    let deadline = std::time::Instant::now() + timeout;
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
/// Kill every tracked child process. Since C4 there's no Docker to tear
/// down — every service is a native child of this shell. SIGKILL is OK
/// for all three: the Erlang release closes ports cleanly under it, and
/// the PyApp launcher tree + llama-server are stateless re: this process.
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
        // closed cleanly. C2.5: replace with a proper SIGTERM + wait +
        // SIGKILL fallback.
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

    eprintln!("[fineshyt-desktop] shutdown: stopping ai_worker child");
    if let Some(mut child) = app.state::<AiWorkerChild>().0.lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    let _ = app.emit("services-shutdown", ());
}

/// Emit a phase-change event so the splash can show what we're doing and
/// roughly how long it'll take. `detail` is shown in italic muted text under
/// the headline `label`; pass an empty string to clear it.
///
/// We *both* emit a live event and persist the state to `StartupStateLock`.
/// The split exists because Tauri emits are fire-and-forget — if the splash
/// hasn't registered its listener yet (race common on cold launches), the
/// event is lost. The persisted state lets the splash recover by calling
/// `get_startup_state` after its listeners are wired.
fn emit_phase(app: &AppHandle, label: &str, detail: &str) {
    use tauri::Emitter;
    if let Some(state) = app.try_state::<StartupStateLock>() {
        let mut st = state.0.lock().unwrap();
        st.phase_label = Some(label.to_string());
        st.phase_detail = Some(detail.to_string());
    }
    let _ = app.emit(
        "startup-phase",
        serde_json::json!({ "label": label, "detail": detail }),
    );
}

/// First-launch heuristics. PyApp writes its venv into a per-user dir on
/// first run; llama-server downloads a multi-GB GGUF into LLAMA_CACHE. If
/// neither dir exists yet, the user is about to wait a *long* time — and
/// the splash needs to tell them so they don't think it's hung.
fn is_first_launch_ai_worker() -> bool {
    let home = match std::env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return true,
    };
    let pyapp_data = if cfg!(target_os = "macos") {
        home.join("Library/Application Support/pyapp")
    } else {
        home.join(".local/share/pyapp")
    };
    match std::fs::read_dir(&pyapp_data) {
        Ok(mut iter) => iter.next().is_none(),
        Err(_) => true,
    }
}

fn is_first_launch_llama(app: &AppHandle) -> bool {
    let cache_dir = if cfg!(debug_assertions) {
        match repo_root() {
            Ok(r) => r.join("desktop").join("runtime").join("models"),
            Err(_) => return true,
        }
    } else {
        match app.path().app_data_dir() {
            Ok(p) => p.join("llama-cache"),
            Err(_) => return true,
        }
    };
    !has_gguf_files(&cache_dir)
}

fn has_gguf_files(dir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    entries
        .filter_map(Result::ok)
        .any(|e| e.path().extension().is_some_and(|x| x == "gguf"))
}

fn emit_failure(app: &AppHandle, message: String) {
    eprintln!("[fineshyt-desktop] startup failed:\n{message}");
    if let Some(state) = app.try_state::<StartupStateLock>() {
        state.0.lock().unwrap().failure = Some(message.clone());
    }
    let _ = app.emit("services-failed", message);
}
