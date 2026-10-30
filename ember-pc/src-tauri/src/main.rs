// Ember PC (test build 2): mpv plays inside the Ember window on its own layer above the page
// (the first test showed mpv ends up behind the page otherwise), or full screen; and reports
// where you are to the Pi's progress store.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::{Child, Command};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::Manager;

#[derive(Default)]
struct Inner {
    child: Option<Child>,
    layer: isize, // our video layer (a child window above the page), 0 if none
}

#[derive(Clone, Default)]
struct Player(Arc<Mutex<Inner>>);

#[cfg(windows)]
mod layer {
    use windows_sys::Win32::Foundation::{HWND, RECT};
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::SetFocus;
    use windows_sys::Win32::UI::WindowsAndMessaging::*;

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// A plain black child window covering the whole page, on top of it. mpv draws into this.
    pub fn create(parent: isize) -> isize {
        unsafe {
            let parent = parent as HWND;
            let mut r: RECT = std::mem::zeroed();
            GetClientRect(parent, &mut r);
            let class = wide("STATIC");
            let name = wide("Ember video");
            let h = CreateWindowExW(
                0,
                class.as_ptr(),
                name.as_ptr(),
                WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                0,
                0,
                r.right - r.left,
                r.bottom - r.top,
                parent,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null(),
            );
            SetWindowPos(h, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
            h as isize
        }
    }

    pub fn fit(layer: isize, parent: isize) {
        unsafe {
            let mut r: RECT = std::mem::zeroed();
            GetClientRect(parent as HWND, &mut r);
            SetWindowPos(layer as HWND, HWND_TOP, 0, 0, r.right - r.left, r.bottom - r.top, 0);
        }
    }

    pub fn focus_video(layer: isize) {
        unsafe {
            // mpv makes its own window inside ours; give it the keyboard
            let inner = GetWindow(layer as HWND, GW_CHILD);
            SetFocus(if inner.is_null() { layer as HWND } else { inner });
        }
    }

    pub fn destroy(layer: isize) {
        unsafe {
            DestroyWindow(layer as HWND);
        }
    }
}

fn main_hwnd(app: &tauri::AppHandle) -> isize {
    #[cfg(windows)]
    {
        if let Some(w) = app.get_webview_window("main") {
            if let Ok(h) = w.hwnd() {
                return h.0 as isize;
            }
        }
    }
    let _ = app;
    0
}

fn remove_layer(app: &tauri::AppHandle, player: &Player) {
    let layer = std::mem::take(&mut player.0.lock().unwrap().layer);
    if layer != 0 {
        let _ = app.run_on_main_thread(move || {
            #[cfg(windows)]
            layer::destroy(layer);
        });
    }
}

fn stop_inner(app: &tauri::AppHandle, player: &Player) {
    if let Some(mut c) = player.0.lock().unwrap().child.take() {
        let _ = c.kill();
    }
    remove_layer(app, player);
}

#[tauri::command]
async fn play(
    app: tauri::AppHandle,
    player: tauri::State<'_, Player>,
    url: String,
    start: f64,
    embed: bool,
    passthrough: bool,
    opts: String,
) -> Result<String, String> {
    let player: Player = (*player).clone();
    let res = app.path().resource_dir().map_err(|e| e.to_string())?;
    let mpv = res.join("mpv").join("mpv.exe");
    let script = res.join("ember.lua");
    if !mpv.exists() {
        return Err(format!("mpv not found at {}", mpv.display()));
    }
    stop_inner(&app, &player);
    let logdir = app.path().app_local_data_dir().map_err(|e| e.to_string())?;
    let _ = std::fs::create_dir_all(&logdir);
    let logfile = logdir.join("mpv-log.txt");
    let _ = std::fs::remove_file(&logfile);

    let mut cmd = Command::new(&mpv);
    cmd.arg(&url)
        .arg(format!("--start={}", start.max(0.0)))
        .arg(format!("--script={}", script.display()))
        .arg(format!("--script-opts={}", opts))
        .arg(format!("--log-file={}", logfile.display()))
        .arg("--msg-level=all=warn,ember=v")
        .arg("--force-window=immediate")
        .arg("--title=Ember")
        .arg("--hwdec=auto-safe")
        .arg("--vo=gpu-next")
        .arg("--keep-open=no")
        .arg("--input-default-bindings=yes")
        .arg("--input-vo-keyboard=yes")
        .arg("--osc=yes")
        .arg("--sub-auto=fuzzy")
        .arg("--slang=en,eng")
        .arg("--alang=en,eng");
    if passthrough {
        // Sends Dolby / DTS untouched to a receiver or soundbar over HDMI. Leave off for PC speakers.
        cmd.arg("--audio-spdif=ac3,eac3,dts,dts-hd,truehd");
    }

    if embed {
        // Make the video layer on the window's own thread, then hand it to mpv.
        let parent = main_hwnd(&app);
        let (tx, rx) = std::sync::mpsc::channel();
        app.run_on_main_thread(move || {
            #[cfg(windows)]
            let _ = tx.send(layer::create(parent));
            #[cfg(not(windows))]
            let _ = tx.send(0isize);
        })
        .map_err(|e| e.to_string())?;
        let layer = rx.recv_timeout(Duration::from_secs(3)).map_err(|e| e.to_string())?;
        if layer == 0 {
            return Err("couldn't make the video layer".into());
        }
        player.0.lock().unwrap().layer = layer;
        cmd.arg(format!("--wid={}", layer));
    } else {
        cmd.arg("--fs");
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // no console window
    }
    let child = cmd.spawn().map_err(|e| e.to_string())?;
    player.0.lock().unwrap().child = Some(child);

    // Give mpv the keyboard once its window exists, and clear the layer away when playback ends.
    let (app2, p2) = (app.clone(), player.clone());
    std::thread::spawn(move || {
        let mut focused = false;
        loop {
            std::thread::sleep(Duration::from_millis(500));
            let mut g = p2.0.lock().unwrap();
            let done = match g.child.as_mut() {
                Some(c) => !matches!(c.try_wait(), Ok(None)),
                None => true,
            };
            let layer = g.layer;
            drop(g);
            if done {
                remove_layer(&app2, &p2);
                break;
            }
            if !focused && layer != 0 {
                focused = true;
                let _ = app2.run_on_main_thread(move || {
                    #[cfg(windows)]
                    layer::focus_video(layer);
                });
            }
        }
    });
    Ok("playing".into())
}

#[tauri::command]
fn stop(app: tauri::AppHandle, player: tauri::State<Player>) {
    stop_inner(&app, &player);
}

/// The player's log lines about Ember's progress reports (and any errors), for checking resume.
#[tauri::command]
fn player_log(app: tauri::AppHandle) -> String {
    let Ok(dir) = app.path().app_local_data_dir() else { return String::new() };
    let text = std::fs::read_to_string(dir.join("mpv-log.txt")).unwrap_or_else(|_| "No player log yet: play something first.".into());
    let lines: Vec<&str> = text.lines().filter(|l| l.contains("[ember]") || l.contains("error") || l.contains("Lua")).collect();
    lines[lines.len().saturating_sub(40)..].join("\n")
}

#[tauri::command]
fn playing(player: tauri::State<Player>) -> bool {
    let mut g = player.0.lock().unwrap();
    match g.child.as_mut() {
        Some(c) => matches!(c.try_wait(), Ok(None)),
        None => false,
    }
}

fn main() {
    tauri::Builder::default()
        .manage(Player::default())
        .invoke_handler(tauri::generate_handler![play, stop, playing, player_log])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Resized(_) = event {
                let app = window.app_handle();
                let player = app.state::<Player>();
                let layer = player.0.lock().unwrap().layer;
                if layer != 0 {
                    let parent = main_hwnd(app);
                    #[cfg(windows)]
                    layer::fit(layer, parent);
                    let _ = parent;
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("couldn't start Ember");
}
