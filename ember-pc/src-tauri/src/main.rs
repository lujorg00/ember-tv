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
    layer: isize,   // mpv's window while it's attached over the page, 0 if none
    last_exit: i32, // how mpv last finished: 0 fine, 2 couldn't play, 4 stalled (Ember's script), -1 running/unknown
}

#[derive(Clone, Default)]
struct Player(Arc<Mutex<Inner>>);

#[cfg(windows)]
mod layer {
    // mpv only gets the mouse and keyboard properly in its own window, so "inside Ember" means: mpv's own
    // borderless window, made a child-like "owned" window of Ember's (stays above it, minimises with it,
    // no extra taskbar button) and kept exactly over Ember's page as you move or resize it.
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM, POINT, RECT};
    use windows_sys::Win32::Graphics::Gdi::ClientToScreen;
    use windows_sys::Win32::UI::WindowsAndMessaging::*;

    fn page_rect(parent: HWND) -> (i32, i32, i32, i32) {
        unsafe {
            let mut r: RECT = std::mem::zeroed();
            GetClientRect(parent, &mut r);
            let mut p = POINT { x: 0, y: 0 };
            ClientToScreen(parent, &mut p);
            (p.x, p.y, r.right - r.left, r.bottom - r.top)
        }
    }

    /// "--geometry" for mpv so its window opens in the right place before we take it over.
    pub fn geometry(parent: isize) -> String {
        let (x, y, w, h) = page_rect(parent as HWND);
        format!("{}x{}+{}+{}", w, h, x, y)
    }

    struct Find {
        pid: u32,
        found: HWND,
    }

    unsafe extern "system" fn each(h: HWND, l: LPARAM) -> BOOL {
        let f = &mut *(l as *mut Find);
        let mut pid = 0u32;
        GetWindowThreadProcessId(h, &mut pid);
        if pid == f.pid && IsWindowVisible(h) != 0 && GetWindow(h, GW_OWNER).is_null() {
            f.found = h;
            return 0;
        }
        1
    }

    /// mpv's main window, once it exists.
    pub fn find(pid: u32) -> isize {
        let mut f = Find { pid, found: std::ptr::null_mut() };
        unsafe {
            EnumWindows(Some(each), &mut f as *mut Find as LPARAM);
        }
        f.found as isize
    }

    pub fn adopt(video: isize, parent: isize) {
        unsafe {
            let v = video as HWND;
            SetWindowLongPtrW(v, GWLP_HWNDPARENT, parent);
            let ex = GetWindowLongPtrW(v, GWL_EXSTYLE);
            SetWindowLongPtrW(v, GWL_EXSTYLE, (ex & !(WS_EX_APPWINDOW as isize)) | WS_EX_TOOLWINDOW as isize);
            fit(video, parent);
            SetForegroundWindow(v);
        }
    }

    pub fn fit(video: isize, parent: isize) {
        unsafe {
            let (x, y, w, h) = page_rect(parent as HWND);
            SetWindowPos(video as HWND, std::ptr::null_mut(), x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
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

fn remove_layer(_app: &tauri::AppHandle, player: &Player) {
    player.0.lock().unwrap().layer = 0; // mpv's window closes with mpv
}

fn stop_inner(app: &tauri::AppHandle, player: &Player) {
    let mut g = player.0.lock().unwrap();
    if let Some(mut c) = g.child.take() {
        let _ = c.kill();
        g.last_exit = 0; // you stopped it: not a failure
    }
    drop(g);
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
        let parent = main_hwnd(&app);
        #[cfg(windows)]
        cmd.arg(format!("--geometry={}", layer::geometry(parent)));
        cmd.arg("--no-border").arg("--title=Ember video");
    } else {
        cmd.arg("--fs");
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // no console window
    }
    let child = cmd.spawn().map_err(|e| e.to_string())?;
    {
        let mut g = player.0.lock().unwrap();
        g.child = Some(child);
        g.last_exit = -1;
    }

    // In the window: find mpv's window, attach it over Ember's page. Then watch for playback ending.
    let pid = player.0.lock().unwrap().child.as_ref().map(|c| c.id()).unwrap_or(0);
    let (app2, p2) = (app.clone(), player.clone());
    std::thread::spawn(move || {
        let parent = main_hwnd(&app2);
        let mut tries = 0;
        loop {
            std::thread::sleep(Duration::from_millis(if tries < 40 { 150 } else { 500 }));
            tries += 1;
            let mut g = p2.0.lock().unwrap();
            let done = match g.child.as_mut() {
                Some(c) => match c.try_wait() {
                    Ok(None) => false,
                    Ok(Some(st)) => {
                        g.last_exit = st.code().unwrap_or(-1);
                        true
                    }
                    Err(_) => true,
                },
                None => true,
            };
            if done {
                g.child = None;
            }
            let attached = g.layer != 0;
            drop(g);
            if done {
                remove_layer(&app2, &p2);
                break;
            }
            #[cfg(windows)]
            if embed && !attached && tries < 80 {
                let v = layer::find(pid);
                if v != 0 {
                    p2.0.lock().unwrap().layer = v;
                    let _ = app2.run_on_main_thread(move || layer::adopt(v, parent));
                }
            }
            let _ = (attached, parent, pid);
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
fn last_exit(player: tauri::State<Player>) -> i32 {
    player.0.lock().unwrap().last_exit
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
        .invoke_handler(tauri::generate_handler![play, stop, playing, player_log, last_exit])
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Resized(_) | tauri::WindowEvent::Moved(_)) {
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
