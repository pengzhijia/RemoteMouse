use crate::gyro;
// Native macOS controller: translates Apple TV remote buttons and touch gestures
// into macOS CoreGraphics keyboard/mouse events, volume adjustments, and display sleep/wake.

use std::ffi::c_void;
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use atv_core::{AtvDelegate, EventKind, TouchPhase, TrackpadMode};
use tracing::{debug, info, warn};

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CGPoint {
    pub x: f64,
    pub y: f64,
}

pub type CGEventRef = *mut c_void;
pub type CGEventSourceRef = *mut c_void;

const K_CGHID_EVENT_TAP: u32 = 0;
const K_CG_EVENT_LEFT_MOUSE_DOWN: u32 = 1;
const K_CG_EVENT_LEFT_MOUSE_UP: u32 = 2;
const K_CG_EVENT_RIGHT_MOUSE_DOWN: u32 = 3;
const K_CG_EVENT_RIGHT_MOUSE_UP: u32 = 4;
const K_CG_MOUSE_BUTTON_RIGHT: u32 = 1;
const K_CG_EVENT_MOUSE_MOVED: u32 = 5;
const K_CG_MOUSE_BUTTON_LEFT: u32 = 0;
const K_CG_SCROLL_EVENT_UNIT_LINE: u32 = 1;

fn send_host_input_command(command: &str) -> bool {
    let Some(socket_path) = std::env::var_os("ATV_MOUSE_SOCKET").map(PathBuf::from) else {
        return false;
    };

    static SOCKET: OnceLock<Option<UnixDatagram>> = OnceLock::new();
    static WARNED: AtomicBool = AtomicBool::new(false);
    let Some(socket) = SOCKET.get_or_init(|| UnixDatagram::unbound().ok()) else {
        if !WARNED.swap(true, Ordering::Relaxed) {
            warn!("[macOS] could not create host input relay socket");
        }
        return false;
    };

    match socket.send_to(command.as_bytes(), socket_path) {
        Ok(_) => true,
        Err(error) => {
            if !WARNED.swap(true, Ordering::Relaxed) {
                warn!("[macOS] host input relay failed: {error}");
            }
            false
        }
    }
}

#[allow(dead_code)]
pub const NX_KEYTYPE_SOUND_UP: i32 = 0;
#[allow(dead_code)]
pub const NX_KEYTYPE_SOUND_DOWN: i32 = 1;
#[allow(dead_code)]
pub const NX_KEYTYPE_BRIGHTNESS_UP: i32 = 2;
#[allow(dead_code)]
pub const NX_KEYTYPE_BRIGHTNESS_DOWN: i32 = 3;
#[allow(dead_code)]
pub const NX_KEYTYPE_MUTE: i32 = 7;
#[allow(dead_code)]
pub const NX_KEYTYPE_PLAY: i32 = 16;
#[allow(dead_code)]
pub const NX_KEYTYPE_NEXT: i32 = 17;
#[allow(dead_code)]
pub const NX_KEYTYPE_PREVIOUS: i32 = 18;
#[allow(dead_code)]
pub const NX_KEYTYPE_FAST: i32 = 19;
#[allow(dead_code)]
pub const NX_KEYTYPE_REWIND: i32 = 20;

const RTLD_DEFAULT: *mut c_void = -2isize as *mut c_void;

#[link(name = "AppKit", kind = "framework")]
#[link(name = "CoreGraphics", kind = "framework")]
#[link(name = "ApplicationServices", kind = "framework")]
#[link(name = "CoreFoundation", kind = "framework")]
#[link(name = "objc")]
extern "C" {
    fn CGEventCreate(source: CGEventSourceRef) -> CGEventRef;
    fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
    fn CGEventCreateKeyboardEvent(
        source: CGEventSourceRef,
        virtual_key: u16,
        key_down: bool,
    ) -> CGEventRef;
    fn CGEventCreateMouseEvent(
        source: CGEventSourceRef,
        mouse_type: u32,
        mouse_cursor_position: CGPoint,
        mouse_button: u32,
    ) -> CGEventRef;
    fn CGEventCreateScrollWheelEvent(
        source: CGEventSourceRef,
        units: u32,
        wheel_count: u32,
        wheel1: i32,
        wheel2: i32,
    ) -> CGEventRef;
    fn CGEventPost(tap: u32, event: CGEventRef);
    fn CGEventSetFlags(event: CGEventRef, flags: u64);
    fn CFRelease(cf: *const c_void);
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: *const c_void) -> bool;
    static kAXTrustedCheckOptionPrompt: *const c_void;
    static kCFBooleanTrue: *const c_void;
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
    fn CFDictionaryCreate(
        allocator: *const c_void,
        keys: *const *const c_void,
        values: *const *const c_void,
        num_values: isize,
        key_callbacks: *const c_void,
        value_callbacks: *const c_void,
    ) -> *const c_void;
    fn objc_getClass(name: *const u8) -> *mut c_void;
    fn sel_registerName(name: *const u8) -> *mut c_void;
    fn objc_autoreleasePoolPush() -> *mut c_void;
    fn objc_autoreleasePoolPop(pool: *mut c_void);
    fn dlsym(handle: *mut c_void, symbol: *const u8) -> *mut c_void;
    fn CGMainDisplayID() -> u32;
    fn CGDisplayPixelsWide(display: u32) -> usize;
    fn CGDisplayPixelsHigh(display: u32) -> usize;
}

/// Send macOS system-defined media key (Play/Pause, Vol+/-, Mute, Next/Prev)
/// which triggers the native macOS Now Playing daemon and HUD volume bezel.
pub fn send_system_media_key(key: i32) {
    if send_host_input_command(&format!("media|{key}")) {
        return;
    }
    unsafe {
        let pool = objc_autoreleasePoolPush();
        let cls_name = b"NSEvent\0";
        let sel_name = b"otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:\0";
        let cg_event_sel_name = b"CGEvent\0";

        let nsevent_class = objc_getClass(cls_name.as_ptr());
        let other_event_sel = sel_registerName(sel_name.as_ptr());
        let cg_event_sel = sel_registerName(cg_event_sel_name.as_ptr());

        if nsevent_class.is_null() || other_event_sel.is_null() || cg_event_sel.is_null() {
            warn!("[macOS] Failed to get NSEvent class or selectors for media key");
            objc_autoreleasePoolPop(pool);
            return;
        }

        type OtherEventFn = unsafe extern "C" fn(
            *mut c_void,
            *mut c_void,
            usize,
            CGPoint,
            usize,
            f64,
            isize,
            *mut c_void,
            i16,
            isize,
            isize,
        ) -> *mut c_void;

        type CgEventFn = unsafe extern "C" fn(*mut c_void, *mut c_void) -> CGEventRef;

        let msg_send = dlsym(RTLD_DEFAULT, b"objc_msgSend\0".as_ptr());
        if msg_send.is_null() {
            warn!("[macOS] Failed to locate objc_msgSend");
            objc_autoreleasePoolPop(pool);
            return;
        }
        let other_event_fn: OtherEventFn = std::mem::transmute(msg_send);
        let cg_event_fn: CgEventFn = std::mem::transmute(msg_send);

        for down in [true, false] {
            let state: i32 = if down { 0xa } else { 0xb };
            let flags: usize = (state as usize) << 8;
            let data1: isize = ((key as isize) << 16) | ((state as isize) << 8);

            let event = other_event_fn(
                nsevent_class,
                other_event_sel,
                14, // NSSystemDefined
                CGPoint { x: 0.0, y: 0.0 },
                flags,
                0.0,
                0,
                std::ptr::null_mut(),
                8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1,
                -1,
            );

            if !event.is_null() {
                let cg_event = cg_event_fn(event, cg_event_sel);
                if !cg_event.is_null() {
                    CGEventPost(K_CGHID_EVENT_TAP, cg_event);
                }
            }
        }
        objc_autoreleasePoolPop(pool);
    }
}

/// Query actual system audio settings from macOS via AppleScript.
pub fn get_mac_audio_settings() -> (f64, bool) {
    if let Ok(output) = Command::new("/usr/bin/osascript")
        .args(["-e", "get {output volume of (get volume settings), output muted of (get volume settings)}"])
        .output()
    {
        if output.status.success() {
            let s = String::from_utf8_lossy(&output.stdout);
            let parts: Vec<&str> = s.trim().split(',').map(str::trim).collect();
            if parts.len() == 2 {
                let vol_pct: f64 = parts[0].parse().unwrap_or(50.0);
                let muted: bool = parts[1].parse().unwrap_or(false);
                return (vol_pct / 100.0, muted);
            }
        }
    }
    (0.5, false)
}

/// Check if the process has macOS Accessibility permission.
pub fn is_accessibility_trusted() -> bool {
    unsafe { AXIsProcessTrusted() }
}

/// Request macOS Accessibility permission: triggers system modal dialog and opens System Settings.
pub fn request_accessibility_permission() -> bool {
    unsafe {
        if AXIsProcessTrusted() {
            return true;
        }

        let keys = [kAXTrustedCheckOptionPrompt];
        let values = [kCFBooleanTrue];
        let dict = CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        );

        let trusted = AXIsProcessTrustedWithOptions(dict);
        if !dict.is_null() {
            CFRelease(dict);
        }

        let _ = Command::new("/usr/bin/open")
            .arg("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
            .spawn();

        trusted
    }
}

/// Virtual keycodes on macOS.
fn key_code_for_button(name: &str) -> Option<u16> {
    match name {
        "up" => Some(126),       // Arrow Up
        "down" => Some(125),     // Arrow Down
        "left" => Some(123),     // Arrow Left
        "right" => Some(124),    // Arrow Right
        "menu" => Some(53),      // Escape
        "home" => Some(115),     // Home
        "channel_up" | "page_up" => Some(116), // Page Up
        "channel_down" | "page_down" => Some(121), // Page Down
        "guide" => Some(48),     // Tab
        _ => None,
    }
}

struct PlayPauseState {
    last_click: Instant,
    click_count: u32,
    timer_generation: u32,
}

#[derive(Clone)]
pub struct MacDelegate {
    mouse_mode: Arc<AtomicBool>,
    mouse_speed: Arc<AtomicU64>,
    scroll_mode: Arc<AtomicBool>,
    three_finger_mode: Arc<AtomicBool>,
    four_finger_mode: Arc<AtomicBool>,
    mapped_drag: Arc<std::sync::Mutex<bool>>,
    mouse_accel: Arc<AtomicBool>,
    verbose_events: Arc<AtomicBool>,
    display_asleep: Arc<AtomicBool>,
    cached_audio: Arc<std::sync::Mutex<Option<(f64, bool)>>>,
    cursor_pos: Arc<std::sync::Mutex<Option<CGPoint>>>,
    scroll_remainder: Arc<std::sync::Mutex<(f64, f64)>>,
    pending_clicks: Arc<std::sync::Mutex<std::collections::HashMap<String, (Instant, u8)>>>,
    fn_held_buttons: Arc<std::sync::Mutex<std::collections::HashSet<String>>>,
    play_pause_state: Arc<std::sync::Mutex<PlayPauseState>>,
    host_input_relay: bool,
}

impl MacDelegate {
    #[allow(dead_code)]
    pub fn new(mouse_mode: Arc<AtomicBool>) -> Self {
        Self::new_with_full_settings(mouse_mode, 1.0, true, false, true)
    }

    #[allow(dead_code)]
    pub fn new_with_settings(
        mouse_mode: Arc<AtomicBool>,
        initial_speed: f64,
        initial_accel: bool,
    ) -> Self {
        Self::new_with_full_settings(mouse_mode, initial_speed, initial_accel, false, true)
    }

    pub fn new_with_full_settings(
        mouse_mode: Arc<AtomicBool>,
        initial_speed: f64,
        initial_accel: bool,
        verbose_events: bool,
        prompt_accessibility: bool,
    ) -> Self {
        let host_input_relay = std::env::var_os("ATV_MOUSE_SOCKET").is_some();
        if !is_accessibility_trusted() && host_input_relay {
            info!("[macOS] helper Accessibility is not required; routing input events through the Swift host");
        } else if !is_accessibility_trusted() {
            if prompt_accessibility {
                eprintln!(
                    "\n================================================================================\n\
                     ⚠️  [macOS Accessibility Permission Required / 需要辅助功能权限]\n\
                     atv-cli requires Accessibility permission to simulate keyboard and mouse controls.\n\
                     \n\
                     👉 Note: In modern macOS, the settings pane is displayed as:\n\
                     \"Device Control and Data Access\" (设备控制与数据访问) > \"Accessibility\" (辅助功能).\n\
                     👉 Enable the current TVRemoteMouse app in Accessibility.\n\
                     Permission for the separately signed original app does not authorize this build.\n\
                     ================================================================================\n"
                );
                request_accessibility_permission();
            } else {
                warn!("[macOS] Child process started without direct Accessibility trust; relying on host application bundle.");
            }
        } else {
            info!("macOS Accessibility permission confirmed");
        }

        let initial_audio = get_mac_audio_settings();
        let speed = initial_speed.clamp(0.1, 10.0);

        Self {
            mouse_mode,
            mouse_speed: Arc::new(AtomicU64::new(speed.to_bits())),
            scroll_mode: Arc::new(AtomicBool::new(false)),
            three_finger_mode: Arc::new(AtomicBool::new(false)),
            four_finger_mode: Arc::new(AtomicBool::new(false)),
            mapped_drag: Arc::new(std::sync::Mutex::new(false)),
            mouse_accel: Arc::new(AtomicBool::new(initial_accel)),
            verbose_events: Arc::new(AtomicBool::new(verbose_events)),
            display_asleep: Arc::new(AtomicBool::new(false)),
            cached_audio: Arc::new(std::sync::Mutex::new(Some(initial_audio))),
            cursor_pos: Arc::new(std::sync::Mutex::new(None)),
            scroll_remainder: Arc::new(std::sync::Mutex::new((0.0, 0.0))),
            pending_clicks: Arc::new(std::sync::Mutex::new(std::collections::HashMap::new())),
            fn_held_buttons: Arc::new(std::sync::Mutex::new(std::collections::HashSet::new())),
            play_pause_state: Arc::new(std::sync::Mutex::new(PlayPauseState {
                last_click: Instant::now() - Duration::from_secs(10),
                click_count: 0,
                timer_generation: 0,
            })),
            host_input_relay,
        }
    }

    pub fn is_mouse_mode(&self) -> bool {
        self.mouse_mode.load(Ordering::SeqCst)
    }

    pub fn set_mouse_mode(&self, enabled: bool) {
        self.mouse_mode.store(enabled, Ordering::SeqCst);
        self.notify_mode_changed(enabled);
    }

    pub fn toggle_mouse_mode(&self) -> bool {
        let current = self.is_mouse_mode();
        let new_mode = !current;
        self.set_mouse_mode(new_mode);
        new_mode
    }

    pub fn notify_trackpad_mode_changed(&self, mode: TrackpadMode) {
        let title = "TVRemoteMouse";
        let message = match mode {
            TrackpadMode::Mouse => "已切换为: 🖱️ 鼠标光标模式 (Mouse Mode)",
            TrackpadMode::Direction => "已切换为: ◀▲▼▶ 方向键模式 (Arrow Keys 上下左右)",
            TrackpadMode::Idle => "已切换为: 👁️ 触控板空置模式 (仅看轨迹实时预览)",
        };
        info!("[macOS] {message}");
        let script = format!("display notification \"{message}\" with title \"{title}\"");
        let _ = Command::new("/usr/bin/osascript").args(["-e", &script]).spawn();
    }

    pub fn notify_mode_changed(&self, mouse_mode: bool) {
        self.notify_trackpad_mode_changed(if mouse_mode {
            TrackpadMode::Mouse
        } else {
            TrackpadMode::Direction
        });
    }

    pub fn notify_media_action(&self, message: &str) {
        let title = "TVRemoteMouse";
        info!("[macOS] {message}");
        let script = format!("display notification \"{message}\" with title \"{title}\"");
        let _ = Command::new("/usr/bin/osascript").args(["-e", &script]).spawn();
    }

    fn refresh_cached_audio(&self) {
        std::thread::spawn(|| {
            let _ = get_mac_audio_settings();
        });
    }

    fn display_size() -> (f64, f64) {
        unsafe {
            let main_disp = CGMainDisplayID();
            let w = CGDisplayPixelsWide(main_disp);
            let h = CGDisplayPixelsHigh(main_disp);
            if w > 0 && h > 0 {
                (w as f64 - 1.0, h as f64 - 1.0)
            } else {
                (3840.0, 2160.0)
            }
        }
    }

    fn send_key_press(virtual_key: u16) {
        if send_host_input_command(&format!("key|{virtual_key}")) {
            return;
        }
        unsafe {
            let event_down = CGEventCreateKeyboardEvent(std::ptr::null_mut(), virtual_key, true);
            if !event_down.is_null() {
                CGEventPost(K_CGHID_EVENT_TAP, event_down);
                CFRelease(event_down as *const c_void);
            }
            let event_up = CGEventCreateKeyboardEvent(std::ptr::null_mut(), virtual_key, false);
            if !event_up.is_null() {
                CGEventPost(K_CGHID_EVENT_TAP, event_up);
                CFRelease(event_up as *const c_void);
            }
        }
    }

    fn current_mouse_location() -> CGPoint {
        unsafe {
            let event = CGEventCreate(std::ptr::null_mut());
            if !event.is_null() {
                let loc = CGEventGetLocation(event);
                CFRelease(event as *const c_void);
                loc
            } else {
                CGPoint { x: 0.0, y: 0.0 }
            }
        }
    }

    fn mouse_move(&self, dx: f64, dy: f64) {
        let speed=f64::from_bits(self.mouse_speed.load(Ordering::Relaxed));
        let command = if self.three_finger_mode.load(Ordering::SeqCst) {
            "aim_drag_move"
        } else {
            "aim_move"
        };
        if send_host_input_command(&format!("{command}|{dx}|{dy}|{speed}")) { return; }

        let mut guard = match self.cursor_pos.lock() {
            Ok(g) => g,
            Err(_) => return,
        };

        let cur = match *guard {
            Some(pos) => pos,
            None => {
                let pos = Self::current_mouse_location();
                *guard = Some(pos);
                pos
            }
        };

        let dist = (dx * dx + dy * dy).sqrt();
        if dist == 0.0 {
            return;
        }

        let speed = f64::from_bits(self.mouse_speed.load(Ordering::Relaxed));
        let use_accel = self.mouse_accel.load(Ordering::Relaxed);

        // Non-linear trackpad acceleration (ballistics):
        // - Tiny movements (< 1.5 units): 1.15x precision mode
        // - Moderate motion (1.5 - 5.0 units): smooth 1.15x -> 2.375x
        // - Fast flick (> 5.0 units): accelerates up to 4.5x for effortless travel
        let accel = if use_accel {
            if dist < 1.5 {
                1.15
            } else if dist < 5.0 {
                1.15 + (dist - 1.5) * 0.35
            } else {
                2.375 + (dist - 5.0).min(10.0) * 0.22
            }
        } else {
            1.6 // Pure linear 1:1 mode
        };

        let base_scale = 1.6;
        let scale = base_scale * speed;
        let move_x = dx * accel * scale;
        let move_y = dy * accel * scale;

        let (screen_w, screen_h) = Self::display_size();
        let target = CGPoint {
            x: (cur.x + move_x).clamp(0.0, screen_w),
            y: (cur.y + move_y).clamp(0.0, screen_h),
        };

        *guard = Some(target);
        drop(guard);

        if send_host_input_command(&format!("move|{:.2}|{:.2}", target.x, target.y)) {
            return;
        }

        unsafe {
            let event = CGEventCreateMouseEvent(
                std::ptr::null_mut(),
                K_CG_EVENT_MOUSE_MOVED,
                target,
                K_CG_MOUSE_BUTTON_LEFT,
            );
            if !event.is_null() {
                CGEventPost(K_CGHID_EVENT_TAP, event);
                CFRelease(event as *const c_void);
            }
        }
    }

    fn mouse_click(&self) {
        let cur = if let Ok(guard) = self.cursor_pos.lock() {
            guard.unwrap_or_else(Self::current_mouse_location)
        } else {
            Self::current_mouse_location()
        };
        if send_host_input_command(&format!("click|{:.2}|{:.2}", cur.x, cur.y)) {
            return;
        }
        unsafe {
            let down = CGEventCreateMouseEvent(
                std::ptr::null_mut(),
                K_CG_EVENT_LEFT_MOUSE_DOWN,
                cur,
                K_CG_MOUSE_BUTTON_LEFT,
            );
            if !down.is_null() {
                CGEventPost(K_CGHID_EVENT_TAP, down);
                CFRelease(down as *const c_void);
            }
            let up = CGEventCreateMouseEvent(
                std::ptr::null_mut(),
                K_CG_EVENT_LEFT_MOUSE_UP,
                cur,
                K_CG_MOUSE_BUTTON_LEFT,
            );
            if !up.is_null() {
                CGEventPost(K_CGHID_EVENT_TAP, up);
                CFRelease(up as *const c_void);
            }
        }
    }

    fn mouse_right_click(&self) {
        let cur = Self::current_mouse_location();
        if send_host_input_command(&format!("right_click|{:.2}|{:.2}", cur.x, cur.y)) { return; }
        unsafe {
            for event_type in [K_CG_EVENT_RIGHT_MOUSE_DOWN, K_CG_EVENT_RIGHT_MOUSE_UP] {
                let event = CGEventCreateMouseEvent(std::ptr::null_mut(), event_type, cur, K_CG_MOUSE_BUTTON_RIGHT);
                if !event.is_null() {
                    CGEventPost(K_CGHID_EVENT_TAP, event);
                    CFRelease(event as *const c_void);
                }
            }
        }
    }

    fn parse_configured_action(text: &str, name: &str) -> Option<String> {
        text.lines().filter_map(|line| line.split_once('='))
            .find(|(key, _)| *key == name)
            .map(|(_, value)| value.trim().to_string())
            .filter(|value| !value.is_empty() && value != "default")
    }

    fn configured_action(name: &str) -> Option<String> {
        let dir = std::env::var_os("TVREMOTE_APP_SUPPORT_DIR")?;
        let text = std::fs::read_to_string(PathBuf::from(dir).join("button-mappings.txt")).ok()?;
        Self::parse_configured_action(&text, name)
    }

    fn send_shortcut(spec: &str) -> bool {
        let mut parts = spec.split(':');
        let (Some(Ok(key)), Some(Ok(flags))) = (parts.next().map(str::parse::<u16>), parts.next().map(str::parse::<u64>)) else { return false };
        if parts.next().is_some() || key > 127 || flags & !0x1f0000 != 0 { return false; }
        if send_host_input_command(&format!("shortcut|{key}|{flags}")) { return true; }
        unsafe {
            for down in [true, false] {
                let event = CGEventCreateKeyboardEvent(std::ptr::null_mut(), key, down);
                if !event.is_null() { CGEventSetFlags(event, flags); CGEventPost(K_CGHID_EVENT_TAP, event); CFRelease(event as *const c_void); }
            }
        }
        true
    }

    fn fire_clicks(&self, input: &str, count: u8) {
        if count >= 2 && Self::configured_action(&format!("{input}.double")).is_some() {
            self.dispatch_button(&format!("{input}.double"));
        } else {
            for _ in 0..count { self.dispatch_button(input); }
        }
    }

    fn handle_play_pause_click(&self) {
        let mut state = self.play_pause_state.lock().unwrap();
        let now = Instant::now();
        let elapsed = now.duration_since(state.last_click);

        state.last_click = now;
        state.timer_generation = state.timer_generation.wrapping_add(1);
        let current_gen = state.timer_generation;

        if elapsed <= Duration::from_millis(380) {
            state.click_count += 1;
        } else {
            state.click_count = 1;
        }

        let count = state.click_count;
        drop(state);

        // Triple click: instant Previous track
        if count >= 3 {
            info!("[macOS] media previous track (triple-click)");
            send_system_media_key(NX_KEYTYPE_PREVIOUS);
            self.notify_media_action("⏮ 上一曲 (Previous Track)");
            if let Ok(mut s) = self.play_pause_state.lock() {
                s.click_count = 0;
            }
            return;
        }

        // Wait to see if user clicks again (double click window)
        let state_arc = self.play_pause_state.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            let mut s = state_arc.lock().unwrap();
            if s.timer_generation == current_gen {
                let final_count = s.click_count;
                s.click_count = 0;
                drop(s);
                match final_count {
                    1 => {
                        info!("[macOS] media play/pause (single-click)");
                        send_system_media_key(NX_KEYTYPE_PLAY);
                    }
                    2 => {
                        info!("[macOS] media next track (double-click)");
                        send_system_media_key(NX_KEYTYPE_NEXT);
                        let title = "TVRemoteMouse";
                        let message = "⏭ 下一曲 (Next Track)";
                        info!("[macOS] {message}");
                        let script = format!("display notification \"{message}\" with title \"{title}\"");
                        let _ = Command::new("/usr/bin/osascript").args(["-e", &script]).spawn();
                    }
                    _ => {}
                }
            }
        });
    }

    fn wake_display(&self) {
        if self.display_asleep.swap(false, Ordering::SeqCst) {
            let _ = Command::new("/usr/bin/caffeinate")
                .args(["-u", "-t", "1"])
                .spawn();
        }
    }

    fn release_mapped_drag(&self) {
        if let Ok(mut held)=self.mapped_drag.lock() { if *held { *held=false; send_host_input_command("mapped_drag|0"); } }
    }

    fn toggle_mapped_drag(&self) {
        let enabled={let Ok(mut held)=self.mapped_drag.lock() else{return};*held=!*held;send_host_input_command(if *held{"mapped_drag|1"}else{"mapped_drag|0"});*held};
        if enabled {
            self.scroll_mode.store(false,Ordering::SeqCst);
            let weak=Arc::downgrade(&self.mapped_drag);
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_millis(300));
                let Some(state)=weak.upgrade() else{break};
                let Ok(held)=state.lock() else{break};
                if !*held {break;}
                send_host_input_command("mapped_drag|1");
            });
        }
    }

    fn dispatch_button(&self, input_name: &str) {
        let mapping = Self::configured_action(input_name);
        let name = mapping.as_deref().unwrap_or(match input_name {
            "two_finger_tap" => "right_click",
"motion_left" => "shortcut:123:262144",
"motion_right" => "shortcut:124:262144",
"motion_up" => "shortcut:126:262144",
"motion_down" => "shortcut:125:262144",
"motion_zoom_in" => "shortcut:24:1048576",
"motion_zoom_out" => "shortcut:27:1048576",
            "three_finger_tap" | "four_finger_tap" => "disabled",
            _ => input_name,
        });
        if name == "disabled" { return; }
        if name == "release_drag" { self.release_mapped_drag(); return; }
        if name == "hold_drag" { self.toggle_mapped_drag(); return; }
        if name == "desktop_previous" { Self::send_shortcut("123:262144"); return; }
        if name == "desktop_next" { Self::send_shortcut("124:262144"); return; }
        if name == "fn_key" { if !send_host_input_command("fn_tap") { warn!("Fn mapping requires the trusted Swift host"); } return; }
        if name == "voice_input" { if !send_host_input_command("dictation") { warn!("Dictation mapping requires the trusted Swift host"); } return; }
        if name == "toggle_scroll" {
            self.release_mapped_drag();
            let enabled = !self.scroll_mode.fetch_xor(true, Ordering::SeqCst);
            if enabled {
                self.three_finger_mode.store(false, Ordering::SeqCst);
                self.four_finger_mode.store(false, Ordering::SeqCst);
            }
            info!("[macOS] scroll mode {}", if enabled { "enabled" } else { "disabled" });
            return;
        }
        if name == "toggle_three_finger_drag" {
            self.release_mapped_drag();
            let enabled = !self.three_finger_mode.fetch_xor(true, Ordering::SeqCst);
            if enabled {
                self.scroll_mode.store(false, Ordering::SeqCst);
                self.four_finger_mode.store(false, Ordering::SeqCst);
            }
            info!("[macOS] three-finger drag emulation {}", if enabled { "enabled" } else { "disabled" });
            return;
        }
        if name == "toggle_four_finger_desktop" {
            self.release_mapped_drag();
            let enabled = !self.four_finger_mode.fetch_xor(true, Ordering::SeqCst);
            if enabled {
                self.scroll_mode.store(false, Ordering::SeqCst);
                self.three_finger_mode.store(false, Ordering::SeqCst);
            }
            info!("[macOS] four-finger desktop emulation {}", if enabled { "enabled" } else { "disabled" });
            return;
        }
        if name == "right_click" { self.mouse_right_click(); return; }
        if name == "left_click" { self.mouse_click(); return; }
        if let Some(spec) = name.strip_prefix("shortcut:") { if !Self::send_shortcut(spec) { warn!("Invalid shortcut mapping"); } return; }
        let verbose = self.verbose_events.load(Ordering::Relaxed);
        if verbose {
            info!("[macOS] button: {name}");
        } else {
            debug!("[macOS] button: {name}");
        }
        if name == "power" {
            if self.display_asleep.load(Ordering::SeqCst) {
                self.wake_display();
            } else {
                self.sleep_display();
            }
            return;
        }

        self.wake_display();

        if let Some(vk) = key_code_for_button(name) {
            Self::send_key_press(vk);
        } else {
            match name {
                "select" => {
                    if self.mouse_mode.load(Ordering::SeqCst) {
                        if verbose {
                            info!("[macOS] select in mouse mode -> simulating mouse click");
                        } else {
                            debug!("[macOS] select in mouse mode -> simulating mouse click");
                        }
                        self.mouse_click();
                    } else {
                        if verbose {
                            info!("[macOS] select in direction mode -> simulating Return key");
                        } else {
                            debug!("[macOS] select in direction mode -> simulating Return key");
                        }
                        Self::send_key_press(36);
                    }
                }
                "play_pause" => {
                    self.handle_play_pause_click();
                }
                "play" => {
                    if verbose { info!("[macOS] media play"); } else { debug!("[macOS] media play"); }
                    send_system_media_key(NX_KEYTYPE_PLAY);
                }
                "pause" => {
                    if verbose { info!("[macOS] media pause"); } else { debug!("[macOS] media pause"); }
                    send_system_media_key(NX_KEYTYPE_PLAY);
                }
                "next" | "next_track" => {
                    if verbose { info!("[macOS] media next track"); } else { debug!("[macOS] media next track"); }
                    send_system_media_key(NX_KEYTYPE_NEXT);
                }
                "prev" | "previous" | "prev_track" | "previous_track" => {
                    if verbose { info!("[macOS] media previous track"); } else { debug!("[macOS] media previous track"); }
                    send_system_media_key(NX_KEYTYPE_PREVIOUS);
                }
                "fast_forward" => {
                    if verbose { info!("[macOS] media fast forward"); } else { debug!("[macOS] media fast forward"); }
                    send_system_media_key(NX_KEYTYPE_FAST);
                }
                "rewind" => {
                    if verbose { info!("[macOS] media rewind"); } else { debug!("[macOS] media rewind"); }
                    send_system_media_key(NX_KEYTYPE_REWIND);
                }
                "volume_up" => {
                    if verbose { info!("[macOS] volume up"); } else { debug!("[macOS] volume up"); }
                    send_system_media_key(NX_KEYTYPE_SOUND_UP);
                    self.refresh_cached_audio();
                }
                "volume_down" => {
                    if verbose { info!("[macOS] volume down"); } else { debug!("[macOS] volume down"); }
                    send_system_media_key(NX_KEYTYPE_SOUND_DOWN);
                    self.refresh_cached_audio();
                }
                "mute" => {
                    if verbose { info!("[macOS] mute toggle"); } else { debug!("[macOS] mute toggle"); }
                    send_system_media_key(NX_KEYTYPE_MUTE);
                    self.refresh_cached_audio();
                }
                "siri" | "toggle_mode" => {
                    info!("[macOS] toggling input mode via remote button");
                    self.toggle_mouse_mode();
                }
                "screensaver" => {
                    let _ = Command::new("/usr/bin/open")
                        .args(["-a", "ScreenSaverEngine"])
                        .spawn();
                }
                "sleep" => self.sleep_display(),
                "wake" => self.wake_display(),
                _ => warn!("[macOS] no handler for button: {name}"),
            }
        }
    }

    fn sleep_display(&self) {
        self.display_asleep.store(true, Ordering::SeqCst);
        let _ = Command::new("/usr/bin/pmset")
            .arg("displaysleepnow")
            .spawn();
    }
}

impl AtvDelegate for MacDelegate {
    fn on_drag(&self, active: bool, dx: f64, dy: f64) {
        send_host_input_command(&format!("drag|{}|{dx}|{dy}", u8::from(active)));
    }

    fn on_gyro(&self, dx: f64, dy: f64) {
        if gyro::enabled() { send_host_input_command(&format!("gyro|{dx}|{dy}")); }
    }

    fn on_button_state(&self, name: &str, pressed: bool) -> bool {
        let Ok(mut held) = self.fn_held_buttons.lock() else { return false };
        if !pressed {
            if held.remove(name) {
                if held.is_empty() { send_host_input_command("fn_up"); }
                return true;
            }
            return false;
        }
        let Ok(mut pending) = self.pending_clicks.lock() else { return false };
        let prior = pending.get(name)
            .filter(|(started, _)| started.elapsed() < Duration::from_millis(380))
            .map(|(_, count)| *count).unwrap_or(0);
        let target = match prior { 1 => format!("{name}.double"), 2 => format!("{name}.triple"), _ => name.to_owned() };
        let has_higher = match prior {
            0 => Self::configured_action(&format!("{name}.double")).is_some()
                || Self::configured_action(&format!("{name}.triple")).is_some(),
            1 => Self::configured_action(&format!("{name}.triple")).is_some(),
            _ => false,
        };
        if has_higher || Self::configured_action(&target).as_deref() != Some("fn_key") { return false; }
        if held.insert(name.to_owned()) && held.len() == 1 {
            if !send_host_input_command("fn_down") { held.remove(name); return false; }
        }
        if prior > 0 { pending.remove(name); }
        true
    }

    fn on_button(&self, input_name: &str) {
        if input_name.ends_with(".double") || input_name.ends_with(".triple") {
            if Self::configured_action(input_name).is_some() { self.dispatch_button(input_name); }
            return;
        }
        let double = format!("{input_name}.double");
        let triple = format!("{input_name}.triple");
        let has_double = Self::configured_action(&double).is_some();
        let has_triple = Self::configured_action(&triple).is_some();
        if has_double || has_triple {
            let now = Instant::now();
            let previous = self.pending_clicks.lock().ok().and_then(|mut pending| pending.remove(input_name));
            let count = if let Some((started, count)) = previous {
                if now.duration_since(started) < Duration::from_millis(380) { count + 1 }
                else { self.fire_clicks(input_name, count); 1 }
            } else { 1 };
            if count == 3 {
                self.dispatch_button(&triple);
                return;
            }
            if count == 2 && !has_triple {
                self.dispatch_button(&double);
                return;
            }
            if let Ok(mut pending) = self.pending_clicks.lock() { pending.insert(input_name.to_owned(), (now, count)); } else { self.fire_clicks(input_name, count); return; }
            let delegate = self.clone();
            let input = input_name.to_owned();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(380));
                let count = if let Ok(mut pending) = delegate.pending_clicks.lock() {
                    if pending.get(&input).map(|value| value.0) == Some(now) { pending.remove(&input).map(|value| value.1) } else { None }
                } else { None };
                if let Some(count) = count { delegate.fire_clicks(&input, count); }
            });
            return;
        }
        self.dispatch_button(input_name);
    }

    fn is_button_remapped(&self, name: &str) -> bool {
        [name.to_owned(), format!("{name}.double"), format!("{name}.triple")]
            .iter().any(|key| Self::configured_action(key).is_some())
    }

    fn is_scroll_mode(&self) -> bool { self.scroll_mode.load(Ordering::SeqCst) }

    fn gesture_mode(&self) -> &'static str {
        if self.three_finger_mode.load(Ordering::SeqCst) { "three_finger_drag" }
        else if self.four_finger_mode.load(Ordering::SeqCst) { "four_finger_desktop" }
        else if self.scroll_mode.load(Ordering::SeqCst) { "two_finger_scroll" }
        else { "mouse" }
    }

    fn suppress_touch_click(&self) -> bool { self.gesture_mode() != "mouse" }

    fn on_touch(&self, dx: f64, dy: f64, phase: TouchPhase) {
        let mouse_mode = self.mouse_mode.load(Ordering::SeqCst);
        if self.verbose_events.load(Ordering::Relaxed) {
            info!(
                "[macOS] touch callback: phase={phase:?} dx={dx:.1} dy={dy:.1} mouse_mode={mouse_mode} helper_accessibility_trusted={} host_relay={}",
                is_accessibility_trusted(),
                self.host_input_relay
            );
        }
        if !mouse_mode {
            return;
        }
        match phase {
            TouchPhase::Began => {
                // When a new touch begins, sync with the latest OS mouse location
                if let Ok(mut guard) = self.cursor_pos.lock() {
                    *guard = Some(Self::current_mouse_location());
                }
                if self.three_finger_mode.load(Ordering::SeqCst) {
                    self.release_mapped_drag();
                    self.toggle_mapped_drag();
                }
            }
            TouchPhase::Moved => {
                if self.scroll_mode.load(Ordering::SeqCst) { self.on_scroll(dx, dy); }
                else if self.three_finger_mode.load(Ordering::SeqCst) { self.mouse_move(dx, dy); }
                else if self.four_finger_mode.load(Ordering::SeqCst) { /* wait for completed horizontal swipe */ }
                else { if !gyro::enabled() { self.mouse_move(dx, dy); } }
            }
            TouchPhase::Ended => {
                if self.three_finger_mode.load(Ordering::SeqCst) { self.release_mapped_drag(); }
                else if self.four_finger_mode.load(Ordering::SeqCst) && dx.abs() >= 150.0 && dx.abs() > dy.abs() {
                    Self::send_shortcut(if dx > 0.0 { "124:262144" } else { "123:262144" });
                }
            }
        }
    }

    fn on_scroll(&self, dx: f64, dy: f64) {
        if self.verbose_events.load(Ordering::Relaxed) {
            info!("[macOS] scroll callback: dx={dx:.1} dy={dy:.1}");
        }
        self.wake_display();
        // Preserve sub-line movement between packets so slow two-finger
        // scrolling is not lost to integer rounding.
        let (vertical, horizontal) = {
            let Ok(mut remainder) = self.scroll_remainder.lock() else { return };
            remainder.0 += dx;
            remainder.1 += dy;
            let horizontal = (remainder.0 / 20.0).trunc().clamp(-8.0, 8.0) as i32;
            let vertical = (remainder.1 / 20.0).trunc().clamp(-8.0, 8.0) as i32;
            remainder.0 -= f64::from(horizontal) * 20.0;
            remainder.1 -= f64::from(vertical) * 20.0;
            (vertical, horizontal)
        };
        if vertical == 0 && horizontal == 0 {
            return;
        }
        if send_host_input_command(&format!("scroll|{vertical}|{horizontal}")) {
            return;
        }
        unsafe {
            let event = CGEventCreateScrollWheelEvent(
                std::ptr::null_mut(),
                K_CG_SCROLL_EVENT_UNIT_LINE,
                2,
                vertical,
                horizontal,
            );
            if !event.is_null() {
                CGEventPost(K_CGHID_EVENT_TAP, event);
                CFRelease(event as *const c_void);
            }
        }
    }

    fn on_audio(&self, volume: f64, muted: bool) {
        info!("[macOS] audio sync: vol={volume:.2} muted={muted}");
        if let Ok(mut guard) = self.cached_audio.lock() {
            *guard = Some((volume, muted));
        }
        let percent = (volume * 100.0).round() as u32;
        let script = format!("set volume output volume {percent} with output muted {muted}");
        std::thread::spawn(move || {
            let _ = Command::new("/usr/bin/osascript")
                .args(["-e", &script])
                .status();
        });
    }

    fn on_trackpad_mode_changed(&self, mode: TrackpadMode) {
        self.mouse_mode.store(mode == TrackpadMode::Mouse, Ordering::SeqCst);
        self.notify_trackpad_mode_changed(mode);
    }

    fn on_mode_changed(&self, mouse_mode: bool) {
        self.mouse_mode.store(mouse_mode, Ordering::SeqCst);
        self.notify_mode_changed(mouse_mode);
    }

    fn on_touchpad_settings_changed(&self, speed: f64, acceleration: bool, verbose_events: bool) {
        let clamped = speed.clamp(0.1, 10.0);
        self.mouse_speed.store(clamped.to_bits(), Ordering::Relaxed);
        self.mouse_accel.store(acceleration, Ordering::Relaxed);
        self.verbose_events.store(verbose_events, Ordering::Relaxed);
        info!(
            "[macOS] touchpad settings updated: speed={clamped:.2}x, accel={acceleration}, verbose_events={verbose_events}"
        );
    }

    fn get_touchpad_settings(&self) -> (f64, bool, bool) {
        let speed = f64::from_bits(self.mouse_speed.load(Ordering::Relaxed));
        let accel = self.mouse_accel.load(Ordering::Relaxed);
        let verbose = self.verbose_events.load(Ordering::Relaxed);
        (speed, accel, verbose)
    }

    fn get_screen_size(&self) -> Option<(f64, f64)> {
        Some(Self::display_size())
    }

    fn get_audio_state(&self) -> Option<(f64, bool)> {
        if let Ok(guard) = self.cached_audio.lock() {
            if let Some(state) = *guard {
                return Some(state);
            }
        }
        Some(get_mac_audio_settings())
    }

    fn on_event(&self, kind: EventKind, detail: &str) {
        let verbose = self.verbose_events.load(Ordering::Relaxed);
        match kind {
            EventKind::MouseClick => {
                if verbose {
                    info!("[macOS] mouse click");
                } else {
                    debug!("[macOS] mouse click");
                }
                self.mouse_click();
            }
            EventKind::MouseRightClick => {
                info!("[macOS] two-finger tap received");
                self.on_button("two_finger_tap");
            }
            EventKind::ClientConnected => {
                info!("[macOS] iPhone connected: {detail}");
            }
            EventKind::ClientDisconnected => {
                self.release_mapped_drag();
                if let Ok(mut held) = self.fn_held_buttons.lock() {
                    if !held.is_empty() { held.clear(); send_host_input_command("fn_up"); }
                }
                info!("[macOS] iPhone disconnected: {detail}");
            }
            _ => {
                if verbose {
                    info!("[macOS] event: {kind:?} {detail}");
                } else {
                    debug!("[macOS] event: {kind:?} {detail}");
                }
            }
        }
    }
}

#[cfg(test)]
mod mapping_tests {
    use super::MacDelegate;
    #[test]
    fn mapping_selects_exact_input_and_preserves_default() {
        let text = "menu=toggle_scroll\ntwo_finger_tap=shortcut:8:1048576\nhome=default\n";
        assert_eq!(MacDelegate::parse_configured_action(text, "menu").as_deref(), Some("toggle_scroll"));
        assert_eq!(MacDelegate::parse_configured_action(text, "two_finger_tap").as_deref(), Some("shortcut:8:1048576"));
        assert_eq!(MacDelegate::parse_configured_action(text, "home"), None);
        assert_eq!(MacDelegate::parse_configured_action(text, "men"), None);
    }

    #[test]
    fn mapped_buttons_toggle_scroll_and_send_expected_events() {
        use super::{TouchPhase, AtvDelegate};
        use std::sync::{Arc, atomic::AtomicBool};
        use std::os::unix::net::UnixDatagram;
        use std::time::Duration;
        let directory = std::env::temp_dir().join(format!("tvr-map-test-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let socket_path = directory.join("input.sock");
        let socket = UnixDatagram::bind(&socket_path).unwrap();
        socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        std::fs::write(directory.join("button-mappings.txt"), "menu=toggle_scroll\nhome=shortcut:8:1048576\nthree_finger_tap=left_click\nfour_finger_tap=right_click\n").unwrap();
        let previous_dir = std::env::var_os("TVREMOTE_APP_SUPPORT_DIR");
        let previous_socket = std::env::var_os("ATV_MOUSE_SOCKET");
        std::env::set_var("TVREMOTE_APP_SUPPORT_DIR", &directory);
        std::env::set_var("ATV_MOUSE_SOCKET", &socket_path);
        let delegate = MacDelegate::new_with_full_settings(Arc::new(AtomicBool::new(true)), 0.5, true, false, false);
        assert!(delegate.is_button_remapped("menu"));
        assert!(!delegate.is_scroll_mode());
        delegate.on_button("menu");
        assert!(delegate.is_scroll_mode());
        delegate.on_touch(0.0, 80.0, TouchPhase::Moved);
        let mut buffer = [0u8; 256];
        let n = socket.recv(&mut buffer).unwrap();
        assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(), "scroll|4|0");
        delegate.on_button("menu");
        assert!(!delegate.is_scroll_mode());
        delegate.on_button("home");
        let n = socket.recv(&mut buffer).unwrap();
        assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(), "shortcut|8|1048576");
        delegate.on_button("two_finger_tap");
        let n = socket.recv(&mut buffer).unwrap();
        assert!(std::str::from_utf8(&buffer[..n]).unwrap().starts_with("right_click|"));
        delegate.on_button("three_finger_tap");
        let n = socket.recv(&mut buffer).unwrap();
        assert!(std::str::from_utf8(&buffer[..n]).unwrap().starts_with("click|"));
        delegate.on_button("four_finger_tap");
        let n = socket.recv(&mut buffer).unwrap();
        assert!(std::str::from_utf8(&buffer[..n]).unwrap().starts_with("right_click|"));
        std::fs::write(directory.join("button-mappings.txt"), "menu=left_click\nmenu.double=toggle_scroll\n").unwrap();
        delegate.on_button("menu");
        delegate.on_button("menu");
        assert!(delegate.is_scroll_mode());
        std::thread::sleep(Duration::from_millis(430));
        socket.set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        assert!(socket.recv(&mut buffer).is_err(), "double press must not emit the single action");
        delegate.on_button("menu");
        std::thread::sleep(Duration::from_millis(430));
        let n = socket.recv(&mut buffer).unwrap();
        assert!(std::str::from_utf8(&buffer[..n]).unwrap().starts_with("click|"));
        std::fs::write(directory.join("button-mappings.txt"), "power=left_click\npower.double=right_click\npower.triple=toggle_scroll\n").unwrap();
        let scroll_before = delegate.is_scroll_mode();
        delegate.on_button("power");
        delegate.on_button("power");
        delegate.on_button("power");
        assert_ne!(delegate.is_scroll_mode(), scroll_before, "triple click should select the third mapping for any button");
        socket.set_read_timeout(Some(Duration::from_millis(420))).unwrap();
        assert!(socket.recv(&mut buffer).is_err(), "triple click must not fire earlier mappings");
        delegate.on_button("power");
        delegate.on_button("power");
        std::thread::sleep(Duration::from_millis(410));
        let n = socket.recv(&mut buffer).unwrap();
        assert!(std::str::from_utf8(&buffer[..n]).unwrap().starts_with("right_click|"));
        delegate.on_button("power");
        std::thread::sleep(Duration::from_millis(410));
        let n = socket.recv(&mut buffer).unwrap();
        assert!(std::str::from_utf8(&buffer[..n]).unwrap().starts_with("click|"));
        socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        std::fs::write(directory.join("button-mappings.txt"),"guide=hold_drag\nchannel_up=desktop_previous\nchannel_down=desktop_next\n").unwrap();
        delegate.on_button("guide");
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"mapped_drag|1");
        assert!(*delegate.mapped_drag.lock().unwrap());
        assert!(!delegate.is_scroll_mode(),"dragging must leave scroll mode");
        delegate.on_button("guide");
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"mapped_drag|0");
        assert!(!*delegate.mapped_drag.lock().unwrap());
        delegate.on_button("channel_up");
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"shortcut|123|262144");
        delegate.on_button("channel_down");
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"shortcut|124|262144");
        std::fs::write(directory.join("button-mappings.txt"), "guide=toggle_three_finger_drag\nchannel_up=toggle_four_finger_desktop\n").unwrap();
        delegate.on_button("guide");
        assert_eq!(delegate.gesture_mode(), "three_finger_drag");
        assert!(delegate.suppress_touch_click());
        delegate.on_touch(0.0, 0.0, TouchPhase::Began);
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"mapped_drag|1");
        delegate.on_touch(12.0, 0.0, TouchPhase::Moved);
        let n=socket.recv(&mut buffer).unwrap();assert!(std::str::from_utf8(&buffer[..n]).unwrap().starts_with("aim_drag_move|12|0|"));
        delegate.on_touch(12.0, 0.0, TouchPhase::Ended);
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"mapped_drag|0");
        delegate.on_button("channel_up");
        assert_eq!(delegate.gesture_mode(), "four_finger_desktop");
        delegate.on_touch(0.0, 0.0, TouchPhase::Began);
        delegate.on_touch(160.0, 0.0, TouchPhase::Ended);
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"shortcut|124|262144");
        delegate.on_button("channel_up");
        assert_eq!(delegate.gesture_mode(), "mouse");
        std::fs::write(directory.join("button-mappings.txt"), "guide=fn_key\nmenu=voice_input\n").unwrap();
        assert!(delegate.on_button_state("guide", true));
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"fn_down");
        socket.set_read_timeout(Some(Duration::from_millis(80))).unwrap();
        assert!(socket.recv(&mut buffer).is_err(), "Fn must stay pressed until the HID release");
        assert!(delegate.on_button_state("guide", false));
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"fn_up");
        socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        delegate.on_button("guide");
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"fn_tap");
        std::fs::write(directory.join("button-mappings.txt"), "guide=left_click\nguide.double=fn_key\n").unwrap();
        delegate.on_button("guide");
        assert!(delegate.on_button_state("guide", true));
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"fn_down");
        assert!(delegate.on_button_state("guide", false));
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"fn_up");
        socket.set_read_timeout(Some(Duration::from_millis(430))).unwrap();
        assert!(socket.recv(&mut buffer).is_err(), "holding the second click must not emit the first click");
        socket.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        std::fs::write(directory.join("button-mappings.txt"), "menu=voice_input\n").unwrap();
        delegate.on_button("menu");
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"dictation");
        std::fs::write(directory.join("button-mappings.txt"), "guide=hold_drag\n").unwrap();
        delegate.on_button("guide");socket.recv(&mut buffer).unwrap();
        delegate.on_event(super::EventKind::ClientDisconnected,"test");
        let n=socket.recv(&mut buffer).unwrap();assert_eq!(std::str::from_utf8(&buffer[..n]).unwrap(),"mapped_drag|0");
        assert!(!*delegate.mapped_drag.lock().unwrap());
        if let Some(value) = previous_dir { std::env::set_var("TVREMOTE_APP_SUPPORT_DIR", value); } else { std::env::remove_var("TVREMOTE_APP_SUPPORT_DIR"); }
        if let Some(value) = previous_socket { std::env::set_var("ATV_MOUSE_SOCKET", value); } else { std::env::remove_var("ATV_MOUSE_SOCKET"); }
        drop(socket);
        let _ = std::fs::remove_dir_all(directory);
    }

}
