// Ember PC (test build): proves the two risky parts before the real app is built on top -
// mpv playing your streams (with passthrough options), inside the Ember window or full screen,
// and reporting where you are to the Pi's progress store.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::Command;
use std::sync::Mutex;
use tauri::Manager;

struct Player(Mutex<Option<std::process::Child>>);

#[tauri::command]
fn play(
    app: tauri::AppHandle,
    window: tauri::WebviewWindow,
    state: tauri::State<Player>,
    url: String,
    start: f64,
    embed: bool,
    passthrough: bool,
    opts: String,
) -> Result<String, String> {
    let res = app.path().resource_dir().map_err(|e| e.to_string())?;
    let mpv = res.join("mpv").join("mpv.exe");
    let script = res.join("ember.lua");
    if !mpv.exists() {
        return Err(format!("mpv not found at {}", mpv.display()));
    }
    stop_inner(&state);

    let mut cmd = Command::new(&mpv);
    cmd.arg(&url)
        .arg(format!("--start={}", start.max(0.0)))
        .arg(format!("--script={}", script.display()))
        .arg(format!("--script-opts={}", opts))
        .arg("--force-window=immediate")
        .arg("--title=Ember")
        .arg("--hwdec=auto-safe")
        .arg("--vo=gpu-next")
        .arg("--keep-open=no")
        .arg("--input-default-bindings=yes")
        .arg("--osc=yes")
        .arg("--sub-auto=fuzzy")
        .arg("--slang=en,eng")
        .arg("--alang=en,eng");
    if passthrough {
        // Sends Dolby / DTS untouched to a receiver or soundbar over HDMI. Leave off for PC speakers.
        cmd.arg("--audio-spdif=ac3,eac3,dts,dts-hd,truehd");
    }
    if embed {
        let hwnd = window.hwnd().map_err(|e| e.to_string())?;
        cmd.arg(format!("--wid={}", hwnd.0 as isize));
    } else {
        cmd.arg("--fs");
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // no console window
    }
    let child = cmd.spawn().map_err(|e| e.to_string())?;
    *state.0.lock().unwrap() = Some(child);
    Ok("playing".into())
}

fn stop_inner(state: &tauri::State<Player>) {
    if let Some(mut c) = state.0.lock().unwrap().take() {
        let _ = c.kill();
    }
}

#[tauri::command]
fn stop(state: tauri::State<Player>) {
    stop_inner(&state);
}

#[tauri::command]
fn playing(state: tauri::State<Player>) -> bool {
    let mut g = state.0.lock().unwrap();
    match g.as_mut() {
        Some(c) => matches!(c.try_wait(), Ok(None)),
        None => false,
    }
}

fn main() {
    tauri::Builder::default()
        .manage(Player(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![play, stop, playing])
        .run(tauri::generate_context!())
        .expect("couldn't start Ember");
}
