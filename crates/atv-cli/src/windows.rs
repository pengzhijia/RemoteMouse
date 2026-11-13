use crate::gyro;
// Native Windows controller: translates Apple TV remote buttons and touch gestures
// into Win32 keyboard/mouse input, media/volume keys, and monitor sleep/wake.
//
// Uses a handful of `user32` calls directly (no extra crates); no special
// permission is required on Windows (unlike macOS Accessibility).

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use atv_core::{AtvDelegate, EventKind, TouchPhase, TrackpadMode};
use tracing::{debug, info, warn};

#[repr(C)]
#[derive(Default)]
struct Point {
    x: i32,
    y: i32,
}

#[link(name = "user32")]
extern "system" {
    fn keybd_event(vk: u8, scan: u8, flags: u32, extra: usize);
    fn mouse_event(flags: u32, dx: i32, dy: i32, data: u32, extra: usize);
    fn GetCursorPos(p: *mut Point) -> i32;
    fn SetCursorPos(x: i32, y: i32) -> i32;
    fn GetSystemMetrics(index: i32) -> i32;
    fn PostMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> i32;
    fn SetProcessDPIAware() -> i32;
}

const KEYEVENTF_EXTENDEDKEY: u32 = 0x1;
const KEYEVENTF_KEYUP: u32 = 0x2;
const MOUSEEVENTF_MOVE: u32 = 0x1;
const MOUSEEVENTF_LEFTDOWN: u32 = 0x2;
const MOUSEEVENTF_LEFTUP: u32 = 0x4;
const MOUSEEVENTF_WHEEL: u32 = 0x0800;
const MOUSEEVENTF_HWHEEL: u32 = 0x1000;

const VK_RETURN: u8 = 0x0D;
const VK_VOLUME_MUTE: u8 = 0xAD;
const VK_VOLUME_DOWN: u8 = 0xAE;
const VK_VOLUME_UP: u8 = 0xAF;
const VK_MEDIA_NEXT: u8 = 0xB0;
const VK_MEDIA_PREV: u8 = 0xB1;
const VK_MEDIA_PLAY_PAUSE: u8 = 0xB3;

/// Windows virtual-key codes for simple remote buttons.
fn vk_for_button(name: &str) -> Option<u8> {
    Some(match name {
        "up" => 0x26,
        "down" => 0x28,
        "left" | "rewind" => 0x25,
        "right" | "fast_forward" => 0x27,
        "menu" => 0x1B,                       // Escape
        "home" => 0x24,                       // Home
        "channel_up" | "page_up" => 0x21,     // Page Up
        "channel_down" | "page_down" => 0x22, // Page Down
        "guide" => 0x09,                      // Tab
        "play" | "pause" => VK_MEDIA_PLAY_PAUSE,
        "next" | "next_track" => VK_MEDIA_NEXT,
        "prev" | "previous" | "prev_track" | "previous_track" => VK_MEDIA_PREV,
        "volume_up" => VK_VOLUME_UP,
        "volume_down" => VK_VOLUME_DOWN,
        "mute" => VK_VOLUME_MUTE,
        _ => return None,
    })
}

fn press_key(vk: u8) {
    // Arrows, Home, PgUp/PgDn and media keys are "extended" keys; Esc/Tab/Enter are not.
    let ext = if matches!(vk, 0x21..=0x28 | 0x2d | 0x2e | 0x5b | 0x5c | 0xad..=0xb3) {
        KEYEVENTF_EXTENDEDKEY
    } else {
        0
    };
    unsafe {
        keybd_event(vk, 0, ext, 0);
        keybd_event(vk, 0, ext | KEYEVENTF_KEYUP, 0);
    }
}

fn cursor_pos() -> (f64, f64) {
    let mut p = Point::default();
    unsafe { GetCursorPos(&mut p) };
    (p.x as f64, p.y as f64)
}

/// Bounds of the whole virtual desktop (all monitors): (left, top, right, bottom).
fn virtual_screen() -> (f64, f64, f64, f64) {
    unsafe {
        let (x, y) = (GetSystemMetrics(76), GetSystemMetrics(77));
        let (w, h) = (GetSystemMetrics(78), GetSystemMetrics(79));
        (x as f64, y as f64, (x + w - 1) as f64, (y + h - 1) as f64)
    }
}

fn set_monitor_power(on: bool) {
    unsafe {
        if on {
            // Any user input wakes the display.
            mouse_event(MOUSEEVENTF_MOVE, 1, 0, 0, 0);
            mouse_event(MOUSEEVENTF_MOVE, -1, 0, 0, 0);
        } else {
            // HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off
            PostMessageW(0xFFFF, 0x0112, 0xF170, 2);
        }
    }
}

#[derive(Clone)]
pub struct WinDelegate {
    mouse_mode: Arc<AtomicBool>,
    mouse_speed: Arc<AtomicU64>,
    mouse_accel: Arc<AtomicBool>,
    verbose_events: Arc<AtomicBool>,
    display_asleep: Arc<AtomicBool>,
    cursor: Arc<Mutex<(f64, f64)>>,
    scroll_mode: Arc<AtomicBool>,
    three_finger_mode: Arc<AtomicBool>,
    four_finger_mode: Arc<AtomicBool>,
    scroll_remainder: Arc<Mutex<(f64, f64)>>,
    pending: Arc<Mutex<std::collections::HashMap<String, (Instant, u8)>>>,
    /// (last click time, click count) for play/pause multi-click detection.
    play_clicks: Arc<Mutex<(Instant, u32)>>,
    play_gen: Arc<AtomicU32>,
    dragging: Arc<AtomicBool>,
    mapped_drag: Arc<AtomicBool>,
}

impl WinDelegate {
    pub fn new(mouse_mode: Arc<AtomicBool>, speed: f64, accel: bool, verbose: bool) -> Self {
        unsafe { SetProcessDPIAware() };
        info!("[Windows] native input controller ready");
        Self {
            mouse_mode,
            mouse_speed: Arc::new(AtomicU64::new(speed.clamp(0.1, 10.0).to_bits())),
            mouse_accel: Arc::new(AtomicBool::new(accel)),
            verbose_events: Arc::new(AtomicBool::new(verbose)),
            display_asleep: Arc::new(AtomicBool::new(false)),
            cursor: Arc::new(Mutex::new(cursor_pos())),
            scroll_mode: Arc::new(AtomicBool::new(false)),
            three_finger_mode: Arc::new(AtomicBool::new(false)),
            four_finger_mode: Arc::new(AtomicBool::new(false)),
            scroll_remainder: Arc::new(Mutex::new((0.0, 0.0))),
            pending: Arc::new(Mutex::new(std::collections::HashMap::new())),
            play_clicks: Arc::new(Mutex::new((Instant::now() - Duration::from_secs(10), 0))),
            play_gen: Arc::new(AtomicU32::new(0)),
            dragging: Arc::new(AtomicBool::new(false)),
            mapped_drag: Arc::new(AtomicBool::new(false)),
        }
    }

    fn log(&self, msg: &str) {
        if self.verbose_events.load(Ordering::Relaxed) {
            info!("[Windows] {msg}");
        } else {
            debug!("[Windows] {msg}");
        }
    }

    fn mouse_move(&self, dx: f64, dy: f64) {
        let dist = (dx * dx + dy * dy).sqrt();
        if dist == 0.0 {
            return;
        }
        let speed = f64::from_bits(self.mouse_speed.load(Ordering::Relaxed));
        // Presets use linear AimMac-style gain; legacy acceleration remains for API callers.
        let accel = if !self.mouse_accel.load(Ordering::Relaxed) {
            1.0
        } else if dist < 1.5 {
            1.15
        } else if dist < 5.0 {
            1.15 + (dist - 1.5) * 0.35
        } else {
            2.375 + (dist - 5.0).min(10.0) * 0.22
        };
        let scale = accel * speed;
        let (l, t, r, b) = virtual_screen();
        let mut cur = self.cursor.lock().unwrap();
        cur.0 = (cur.0 + dx * scale).clamp(l, r);
        cur.1 = (cur.1 + dy * scale).clamp(t, b);
        unsafe { SetCursorPos(cur.0.round() as i32, cur.1.round() as i32) };
    }

    fn mouse_click(&self) {
        unsafe {
            mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
            mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        }
    }

    fn fire_clicks(&self, input: &str, count: u8) {
        if count >= 2 && Self::mapping(&format!("{input}.double")).is_some() {
            self.dispatch(&format!("{input}.double"));
        } else {
            for _ in 0..count { self.dispatch(input); }
        }
    }

    /// Single click: play/pause, double: next track, triple: previous track.
    fn handle_play_pause(&self) {
        let count = {
            let mut s = self.play_clicks.lock().unwrap();
            let now = Instant::now();
            s.1 = if now.duration_since(s.0) <= Duration::from_millis(380) {
                s.1 + 1
            } else {
                1
            };
            s.0 = now;
            s.1
        };
        let gen = self.play_gen.fetch_add(1, Ordering::SeqCst) + 1;
        if count >= 3 {
            self.play_clicks.lock().unwrap().1 = 0;
            info!("[Windows] media previous track (triple-click)");
            return press_key(VK_MEDIA_PREV);
        }
        let (clicks, gen_ref) = (self.play_clicks.clone(), self.play_gen.clone());
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            if gen_ref.load(Ordering::SeqCst) != gen {
                return;
            }
            let n = std::mem::take(&mut clicks.lock().unwrap().1);
            match n {
                1 => press_key(VK_MEDIA_PLAY_PAUSE),
                2 => {
                    info!("[Windows] media next track (double-click)");
                    press_key(VK_MEDIA_NEXT)
                }
                _ => {}
            }
        });
    }
}

impl WinDelegate {
    fn mapping(name: &str) -> Option<String> {
        let directory = std::env::var_os("TVREMOTE_APP_SUPPORT_DIR")?;
        let text = std::fs::read_to_string(
            std::path::PathBuf::from(directory).join("button-mappings.txt"),
        )
        .ok()?;
        text.lines()
            .filter_map(|line| line.split_once('='))
            .find(|(key, _)| *key == name)
            .map(|(_, value)| value.trim().to_owned())
            .filter(|value| !value.is_empty() && value != "default")
    }

    fn dispatch(&self, input: &str) {
        let mapped = Self::mapping(input);
        let name = mapped.as_deref().unwrap_or(match input {
            "two_finger_tap" => "right_click",
"motion_left" => "win_shortcut:37:9",
"motion_right" => "win_shortcut:39:9",
"motion_up" => "win_shortcut:9:8",
"motion_down" => "win_shortcut:68:8",
"motion_zoom_in" => "win_shortcut:187:1",
"motion_zoom_out" => "win_shortcut:189:1",
            "three_finger_tap" | "four_finger_tap" => "disabled",
            _ => input,
        });
        match name {
            "disabled" => return,
            "release_drag" => { self.mapped_drag.store(false,Ordering::SeqCst);self.on_drag(false,0.0,0.0);return; }
            "hold_drag" => {
                let active=!self.mapped_drag.fetch_xor(true,Ordering::SeqCst);
                if active { self.scroll_mode.store(false,Ordering::SeqCst); }
                self.on_drag(active,0.0,0.0); return;
            }
            "desktop_previous" => return self.dispatch("win_shortcut:37:9"),
            "desktop_next" => return self.dispatch("win_shortcut:39:9"),
            "voice_input" => return self.dispatch("win_shortcut:72:8"),
            "fn_key" => { warn!("Fn is a hardware-specific key and cannot be synthesized on Windows"); return; }
            "toggle_scroll" => {
                self.mapped_drag.store(false,Ordering::SeqCst);self.on_drag(false,0.0,0.0);
                let enabled = !self.scroll_mode.fetch_xor(true, Ordering::SeqCst);
                if enabled { self.three_finger_mode.store(false,Ordering::SeqCst);self.four_finger_mode.store(false,Ordering::SeqCst); }
                return;
            }
            "toggle_three_finger_drag" => {
                self.mapped_drag.store(false,Ordering::SeqCst);self.on_drag(false,0.0,0.0);
                let enabled = !self.three_finger_mode.fetch_xor(true,Ordering::SeqCst);
                if enabled { self.scroll_mode.store(false,Ordering::SeqCst);self.four_finger_mode.store(false,Ordering::SeqCst); }
                return;
            }
            "toggle_four_finger_desktop" => {
                self.mapped_drag.store(false,Ordering::SeqCst);self.on_drag(false,0.0,0.0);
                let enabled = !self.four_finger_mode.fetch_xor(true,Ordering::SeqCst);
                if enabled { self.scroll_mode.store(false,Ordering::SeqCst);self.three_finger_mode.store(false,Ordering::SeqCst); }
                return;
            }
            "left_click" => return self.mouse_click(),
            "right_click" => {
                unsafe {
                    mouse_event(0x8, 0, 0, 0, 0);
                    mouse_event(0x10, 0, 0, 0, 0);
                }
                return;
            }
            _ => {}
        }
        if let Some(spec) = name.strip_prefix("win_shortcut:") {
            let mut parts = spec.split(':');
            if let (Some(Ok(vk)), Some(Ok(mods))) = (
                parts.next().map(str::parse::<u8>),
                parts.next().map(str::parse::<u8>),
            ) {
                if vk > 0 && mods <= 15 && parts.next().is_none() {
                    let keys: Vec<u8> = [(1, 0x11), (2, 0x12), (4, 0x10), (8, 0x5b)]
                        .into_iter()
                        .filter(|(bit, _)| mods & bit != 0)
                        .map(|(_, key)| key)
                        .collect();
                    unsafe {
                        for key in &keys {
                            keybd_event(*key, 0, if *key == 0x5b { KEYEVENTF_EXTENDEDKEY } else { 0 }, 0);
                        }
                    }
                    press_key(vk);
                    unsafe {
                        for key in keys.iter().rev() {
                            keybd_event(*key, 0, KEYEVENTF_KEYUP | if *key == 0x5b { KEYEVENTF_EXTENDEDKEY } else { 0 }, 0);
                        }
                    }
                }
            }
            return;
        }
        self.log(&format!("button: {name}"));
        if name == "power" || name == "sleep" || name == "wake" {
            let sleep = match name {
                "sleep" => true,
                "wake" => false,
                _ => !self.display_asleep.load(Ordering::SeqCst),
            };
            self.display_asleep.store(sleep, Ordering::SeqCst);
            return set_monitor_power(!sleep);
        }
        if self.display_asleep.swap(false, Ordering::SeqCst) {
            set_monitor_power(true);
        }
        match name {
            "select" if self.mouse_mode.load(Ordering::SeqCst) => self.mouse_click(),
            "select" => press_key(VK_RETURN),
            "play_pause" => self.handle_play_pause(),
            "siri" | "toggle_mode" => {
                let m = !self.mouse_mode.load(Ordering::SeqCst);
                self.mouse_mode.store(m, Ordering::SeqCst);
                info!(
                    "[Windows] input mode -> {}",
                    if m { "mouse" } else { "direction" }
                );
            }
            _ => match vk_for_button(name) {
                Some(vk) => press_key(vk),
                None => warn!("[Windows] no handler for button: {name}"),
            },
        }
    }
}

impl AtvDelegate for WinDelegate {
    fn on_drag(&self, active: bool, dx: f64, dy: f64) {
        let previous = self.dragging.swap(active, Ordering::SeqCst);
        if active && !previous { unsafe { mouse_event(MOUSEEVENTF_LEFTDOWN,0,0,0,0); } }
        if active {
            let (x,y)=cursor_pos(); let (l,t,r,b)=virtual_screen();
            unsafe { SetCursorPos((x+dx).clamp(l,r) as i32,(y+dy).clamp(t,b) as i32); }
            *self.cursor.lock().unwrap()=cursor_pos();
        }
        if !active && previous { unsafe { mouse_event(MOUSEEVENTF_LEFTUP,0,0,0,0); } }
    }

    fn on_gyro(&self, dx: f64, dy: f64) {
        if gyro::enabled() { self.mouse_move(dx, dy); }
    }

    fn on_button(&self, name: &str) {
        if name.ends_with(".double") || name.ends_with(".triple") {
            if Self::mapping(name).is_some() {
                self.dispatch(name);
            }
            return;
        }
        let double = format!("{name}.double");
        let triple = format!("{name}.triple");
        let has_double = Self::mapping(&double).is_some();
        let has_triple = Self::mapping(&triple).is_some();
        if has_double || has_triple {
            let now = Instant::now();
            let old = self.pending.lock().unwrap().remove(name);
            let count = if let Some((old, count)) = old {
                if now.duration_since(old) < Duration::from_millis(380) { count + 1 }
                else { self.fire_clicks(name, count); 1 }
            } else { 1 };
            if count == 3 { self.dispatch(&triple); return; }
            if count == 2 && !has_triple { self.dispatch(&double); return; }
            self.pending.lock().unwrap().insert(name.to_owned(), (now, count));
            let delegate = self.clone();
            let name = name.to_owned();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(380));
                let count = {
                    let mut pending = delegate.pending.lock().unwrap();
                    if pending.get(&name).map(|value| value.0) == Some(now) { pending.remove(&name).map(|value| value.1) } else { None }
                };
                if let Some(count) = count { delegate.fire_clicks(&name, count); }
            });
        } else {
            self.dispatch(name);
        }
    }
    fn is_button_remapped(&self, name: &str) -> bool {
        [name.to_owned(), format!("{name}.double"), format!("{name}.triple")]
            .iter().any(|key| Self::mapping(key).is_some())
    }
    fn is_scroll_mode(&self) -> bool {
        self.scroll_mode.load(Ordering::SeqCst)
    }

    fn gesture_mode(&self) -> &'static str {
        if self.three_finger_mode.load(Ordering::SeqCst) { "three_finger_drag" }
        else if self.four_finger_mode.load(Ordering::SeqCst) { "four_finger_desktop" }
        else if self.scroll_mode.load(Ordering::SeqCst) { "two_finger_scroll" }
        else { "mouse" }
    }

    fn suppress_touch_click(&self) -> bool { self.gesture_mode() != "mouse" }

    fn on_touch(&self, dx: f64, dy: f64, phase: TouchPhase) {
        if !self.mouse_mode.load(Ordering::SeqCst) {
            return;
        }
        match phase {
            // Re-sync with the real cursor in case the user moved the physical mouse.
            TouchPhase::Began => {
                *self.cursor.lock().unwrap() = cursor_pos();
                if self.three_finger_mode.load(Ordering::SeqCst) { self.on_drag(true,0.0,0.0); }
            }
            TouchPhase::Moved => {
                if self.is_scroll_mode() {
                    self.on_scroll(dx, dy);
                } else if self.three_finger_mode.load(Ordering::SeqCst) {
                    self.mouse_move(dx, dy);
                } else if self.four_finger_mode.load(Ordering::SeqCst) {
                    // Desktop changes only after the horizontal swipe completes.
                } else {
                    if !gyro::enabled() { self.mouse_move(dx, dy); }
                }
            }
            TouchPhase::Ended => {
                if self.three_finger_mode.load(Ordering::SeqCst) { self.on_drag(false,0.0,0.0); }
                else if self.four_finger_mode.load(Ordering::SeqCst) && dx.abs() >= 150.0 && dx.abs() > dy.abs() {
                    self.dispatch(if dx > 0.0 { "desktop_next" } else { "desktop_previous" });
                }
            }
        }
    }

    fn on_scroll(&self, dx: f64, dy: f64) {
        if self.display_asleep.swap(false, Ordering::SeqCst) {
            set_monitor_power(true);
        }
        let (horizontal, vertical) = {
            let mut remainder = self.scroll_remainder.lock().unwrap();
            remainder.0 += dx;
            remainder.1 += dy;
            let x = (remainder.0 / 20.0).trunc().clamp(-8.0, 8.0) as i32;
            let y = (remainder.1 / 20.0).trunc().clamp(-8.0, 8.0) as i32;
            remainder.0 -= f64::from(x) * 20.0;
            remainder.1 -= f64::from(y) * 20.0;
            (x * 120, -y * 120)
        };
        unsafe {
            if vertical != 0 {
                mouse_event(MOUSEEVENTF_WHEEL, 0, 0, vertical as u32, 0);
            }
            if horizontal != 0 {
                mouse_event(MOUSEEVENTF_HWHEEL, 0, 0, horizontal as u32, 0);
            }
        }
    }

    fn on_trackpad_mode_changed(&self, mode: TrackpadMode) {
        self.mouse_mode.store(mode.is_mouse(), Ordering::SeqCst);
        info!("[Windows] trackpad mode -> {}", mode.as_str());
    }

    fn on_mode_changed(&self, mouse_mode: bool) {
        self.mouse_mode.store(mouse_mode, Ordering::SeqCst);
    }

    fn on_touchpad_settings_changed(&self, speed: f64, acceleration: bool, verbose_events: bool) {
        let speed = speed.clamp(0.1, 10.0);
        self.mouse_speed.store(speed.to_bits(), Ordering::Relaxed);
        self.mouse_accel.store(acceleration, Ordering::Relaxed);
        self.verbose_events.store(verbose_events, Ordering::Relaxed);
        info!("[Windows] touchpad settings: speed={speed:.2}x accel={acceleration} verbose={verbose_events}");
    }

    fn get_touchpad_settings(&self) -> (f64, bool, bool) {
        (
            f64::from_bits(self.mouse_speed.load(Ordering::Relaxed)),
            self.mouse_accel.load(Ordering::Relaxed),
            self.verbose_events.load(Ordering::Relaxed),
        )
    }

    fn get_screen_size(&self) -> Option<(f64, f64)> {
        let (l, t, r, b) = virtual_screen();
        Some((r - l, b - t))
    }

    fn on_event(&self, kind: EventKind, detail: &str) {
        match kind {
            EventKind::MouseClick => self.on_button("select"),
            EventKind::MouseRightClick => self.on_button("two_finger_tap"),
            EventKind::ClientConnected => info!("[Windows] iPhone connected: {detail}"),
            EventKind::ClientDisconnected => { self.mapped_drag.store(false,Ordering::SeqCst);self.on_drag(false,0.0,0.0);info!("[Windows] iPhone disconnected: {detail}"); },
            _ => self.log(&format!("event: {kind:?} {detail}")),
        }
    }
}
