fn main() {
    #[cfg(windows)]
    {
        let mut res = winres::WindowsResource::new();
        res.set_icon("app_icon.ico");
        res.set("FileDescription", "TVRemoteMouse");
        res.set("ProductName", "TVRemoteMouse");
        res.set("OriginalFilename", "TVRemoteMouse.Core.exe");
        if let Err(e) = res.compile() {
            eprintln!("Warning: failed to compile windows resources: {e}");
        }
    }
}
