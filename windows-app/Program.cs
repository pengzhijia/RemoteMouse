using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace TVRemoteMouse;

public sealed class App : System.Windows.Application
{
    static Mutex? singleton;
    [STAThread]
    public static void Main()
    {
        singleton = new Mutex(true, "Local\\TVRemoteMouse.Desktop", out bool created);
        if (!created) return;
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Run();
    }
    readonly string support = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TVRemoteMouse");
    readonly HttpClient http = new() { BaseAddress = new Uri("http://127.0.0.1:18765"), Timeout = TimeSpan.FromSeconds(3) };
    Forms.NotifyIcon tray = new();
    Process? core;
    Window? panel, console;
    StackPanel? panelBody;
    JsonElement status;
    string pin = "1111", appearance = "auto", surface = "auto";
    bool busy, stopping, refreshing, editingPin;
    TextBox? pinEdit;
    TextBlock? pinError;
    bool Online => core != null && !core.HasExited && status.ValueKind == JsonValueKind.Object;
    bool editingShortcut;
    string selected = "select";
    string trigger = "single";
    string MappingKey => trigger == "single" ? selected : selected + "." + trigger;
    Dictionary<string, string> mappings = new();
    CancellationTokenSource eventsCancel = new();
    TextBlock? history, stateLabel, keyHistory;
    readonly List<string> buttonHistory=new();
    Canvas? trajectory;
    StackPanel? remoteArea, mappingArea;
    readonly Dictionary<int, Polyline> trails = new();
    readonly List<string> eventLines = new();
    readonly Dictionary<int, Point> positions = new();
    string SettingPath => System.IO.Path.Combine(support, "desktop.json");
    string MappingPath => System.IO.Path.Combine(support, "button-mappings.txt");
    string LogPath => System.IO.Path.Combine(support, "config", "atv", "atv-cli.log");
    string S(string key, string fallback = "") => status.ValueKind == JsonValueKind.Object && status.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;
    bool B(string key) => status.ValueKind == JsonValueKind.Object && status.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
    double N(string key, double fallback) => status.ValueKind == JsonValueKind.Object && status.TryGetProperty(key, out var v) && v.TryGetDouble(out double n) ? n : fallback;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e); Directory.CreateDirectory(support); File.WriteAllText(System.IO.Path.Combine(support,"pointer-source.txt"),"mouse");
        Resources.Add(typeof(Button), System.Windows.Markup.XamlReader.Parse("""
        <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
          <Setter Property="Background" Value="#EEF1F5"/><Setter Property="Foreground" Value="#20232A"/>
          <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="10"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.8"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
        </Style>
        """));
        try { var saved = JsonDocument.Parse(File.ReadAllText(SettingPath)).RootElement; pin = saved.GetProperty("pin").GetString() ?? "1111"; appearance = saved.GetProperty("appearance").GetString() ?? "auto"; surface = saved.GetProperty("surface").GetString() ?? "auto"; } catch { }
        if (!ValidPin(pin)) pin = "1111";
        if (File.Exists(MappingPath)) foreach (var line in File.ReadAllLines(MappingPath)) { var pair = line.Split('=', 2); if (pair.Length == 2) mappings[pair[0]] = pair[1]; }
        tray.Visible = true; tray.Text = "TVRemoteMouse";
        tray.MouseClick += (_, _) => Dispatcher.Invoke(ShowPanel);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) }; timer.Tick += async (_, _) => await Refresh(); timer.Start();
        _ = Start();
    }
    void SaveSettings() { var tmp = SettingPath + ".tmp"; File.WriteAllText(tmp, JsonSerializer.Serialize(new { pin, appearance, surface })); File.Move(tmp, SettingPath, true); }
    static bool ValidPin(string value) => value.Length == 4 && value.All(c => c >= '0' && c <= '9');
    async Task Start()
    {
        if (busy) return; busy = true; UpdateTray();
        try
        {
            if (core != null && !core.HasExited) return;
            var info = new ProcessStartInfo(System.IO.Path.Combine(AppContext.BaseDirectory, "TVRemoteMouse.Core.exe")) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = support };
            foreach (var arg in new[] { "--target", "windows", "--name", Environment.MachineName, "--pin", pin, "--ui-port", "18765", "--no-open" }) info.ArgumentList.Add(arg);
            info.Environment["TVREMOTE_NATIVE_HOST"] = "1"; info.Environment["TVREMOTE_APP_SUPPORT_DIR"] = support; info.Environment["XDG_CONFIG_HOME"] = System.IO.Path.Combine(support, "config");
            core = Process.Start(info) ?? throw new IOException("无法启动服务");
            for (int i = 0; i < 20; i++) { await Task.Delay(250); try { status = JsonDocument.Parse(await http.GetStringAsync("/api/status")).RootElement.Clone(); break; } catch { if (core.HasExited) throw new IOException("服务启动失败，请查看日志。"); } }
            if (status.ValueKind != JsonValueKind.Object) throw new IOException("服务未响应，请检查端口 18765。");
            eventsCancel.Cancel(); eventsCancel = new(); _ = ReadEvents(eventsCancel.Token);
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "TVRemoteMouse"); }
        finally { busy = false; await Refresh(); }
    }
    async Task Stop() { if (busy) return; busy = true; UpdateTray(); eventsCancel.Cancel(); if (core != null) { if (!core.HasExited) { core.Kill(true); await core.WaitForExitAsync(); } core.Dispose(); core = null; } status = default; busy = false; UpdateTray(); if (panel?.IsVisible == true && !editingPin) BuildPanel(); }
    async Task Restart() { await Stop(); await Start(); }
    async Task Refresh() { if (refreshing || busy) return; refreshing = true; string oldSurface = S("remote_surface"), oldOs = S("client_os_version"); try { if (core != null && !core.HasExited) status = JsonDocument.Parse(await http.GetStringAsync("/api/status")).RootElement.Clone(); else status = default; } catch { status = default; } finally { refreshing = false; UpdateTray(); if (panel?.IsVisible == true && !editingPin) BuildPanel(); if (console?.IsVisible == true) { stateLabel!.Text = Connection() + " · " + S("client_name", "等待 iPhone") + " · " + GestureModeLabel(); if (oldSurface != S("remote_surface") || oldOs != S("client_os_version")) BuildRemote(); } } }
    string GestureModeLabel() => S("gesture_mode") switch { "two_finger_scroll" => "双指滚动", "three_finger_drag" => "三指按住拖移", "four_finger_desktop" => "四指切换桌面", _ => "鼠标移动" };
    string Connection() => busy ? "处理中" : !Online ? "服务已停止" : B("session_ready") ? "已连接" : B("client_connected") ? "连接中" : "等待连接";
    void UpdateTray()
    {
        var color = busy ? Drawing.Color.Orange : !Online ? Drawing.Color.IndianRed : B("session_ready") ? Drawing.Color.MediumSeaGreen : B("client_connected") ? Drawing.Color.Orange : Drawing.Color.DodgerBlue;
        using var bmp = new Drawing.Bitmap(32, 32); using (var g = Drawing.Graphics.FromImage(bmp)) { g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias; using var pen = new Drawing.Pen(color, 1.8f); g.DrawRectangle(pen, 7, 3, 12, 20); var points = new[] { new Drawing.Point(13, 15), new Drawing.Point(13, 29), new Drawing.Point(18, 24), new Drawing.Point(21, 31), new Drawing.Point(24, 29), new Drawing.Point(21, 23), new Drawing.Point(28, 23) }; g.FillPolygon(Drawing.Brushes.White, points); g.DrawPolygon(pen, points); }
        var handle = bmp.GetHicon(); using var icon = Drawing.Icon.FromHandle(handle); var copy = (Drawing.Icon)icon.Clone(); var old = tray.Icon; tray.Icon = copy; old?.Dispose(); DestroyIcon(handle); tray.Text = "TVRemoteMouse · " + Connection();
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    static TextBlock Text(string text, double size = 13) => new() { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) };
    static Button Button(string label, Action action) => MakeButton(label, (_, _) => action());
    static Button MakeButton(string label, RoutedEventHandler action) { var b = new Button { Content = label, Padding = new Thickness(10, 7, 10, 7), Margin = new Thickness(2), MinHeight = 30 }; b.Click += action; return b; }
    Window Window(string title, double width) => new() { Title = title, Width = width, SizeToContent = SizeToContent.Height, Background = new SolidColorBrush(Color.FromRgb(248, 249, 251)), Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(System.IO.Path.Combine(AppContext.BaseDirectory, "AppIcon.ico"))), ResizeMode = ResizeMode.NoResize };
    void ShowPanel() { if (panel == null) { panel = Window("TVRemoteMouse", 330); panel.ShowInTaskbar = false; panel.Topmost = true; panel.WindowStyle = WindowStyle.None; panel.Deactivated += (_, _) => { if (!editingPin) panel.Hide(); }; panel.SizeChanged += (_, _) => PositionPanel(); } BuildPanel(); panel.Show(); PositionPanel(); panel.Activate(); }
    void PositionPanel() { if (panel == null) return; var area = SystemParameters.WorkArea; panel.Left = area.Right - panel.ActualWidth - 12; panel.Top = area.Bottom - panel.ActualHeight - 12; }
    string PointerSource()=>File.Exists(System.IO.Path.Combine(support,"pointer-source.txt"))?File.ReadAllText(System.IO.Path.Combine(support,"pointer-source.txt")).Trim():"mouse";
    void SetPointer(string mode){File.WriteAllText(System.IO.Path.Combine(support,"pointer-source.txt"),mode);_=Settings(new{mode="mouse"});}
    void MotionSetup(){var file=System.IO.Path.Combine(support,"motion-url.txt");if(File.Exists(file)){string url=File.ReadAllText(file);System.Windows.Clipboard.SetText(url);MessageBox.Show("地址已复制，请用 iPhone Safari 打开并开启运动权限。需要确认本地 HTTPS 证书。采集页需保持前台。\n"+url);}else MessageBox.Show("请先启动服务");}
    void BuildPanel()
    {
        if (panel == null) return; panelBody = new StackPanel { Margin = new Thickness(18) }; panel.Content = panelBody;
        panelBody.Children.Add(Text("TVRemoteMouse                 " + Connection(), 14)); panelBody.Children.Add(Text(S("client_name", Online ? "等待 iPhone 连接" : "服务已暂停"), 15));
        var modes = new StackPanel { Orientation = Orientation.Horizontal }; foreach (var pair in new[] { ("鼠标", "mouse"), ("陀螺仪", "gyro") }) { var b = Button((PointerSource() == pair.Item2 ? "✓ " : "") + pair.Item1, () => SetPointer(pair.Item2)); b.IsEnabled = Online && pair.Item2 != "gyro"; modes.Children.Add(b); }
        panelBody.Children.Add(modes);panelBody.Children.Add(Text("仅系统遥控器 · 陀螺仪尚未收到数据",11));
        var row = new StackPanel { Orientation = Orientation.Horizontal }; row.Children.Add(Text("配对 PIN   ")); if (editingPin) { pinEdit = new TextBox { Text = pin, Width = 60, VerticalContentAlignment = VerticalAlignment.Center }; row.Children.Add(pinEdit); row.Children.Add(Button("保存", () => _ = SavePin())); row.Children.Add(Button("取消", () => { editingPin = false; BuildPanel(); })); } else { row.Children.Add(Text(pin, 15)); row.Children.Add(Button("修改", () => { editingPin = true; BuildPanel(); pinEdit!.Focus(); pinEdit.SelectAll(); })); }
        panelBody.Children.Add(row);
        if (editingPin) panelBody.Children.Add(Text("保存后重启服务，当前连接会断开。", 11)); pinError = Text("", 11); pinError.Foreground = Brushes.IndianRed; pinError.Visibility = Visibility.Collapsed; panelBody.Children.Add(pinError);
        panelBody.Children.Add(Button("运行权限：" + Privilege() + " · 检查", CheckInputAccess)); panelBody.Children.Add(Button("遥控控制台 ↗", ShowConsole));
        var footer = new StackPanel { Orientation = Orientation.Horizontal }; footer.Children.Add(Button(Online ? "暂停服务" : "启动服务", () => { if (Online) _ = Stop(); else _ = Start(); })); var more = Button("•••", () => { }); var menu = new ContextMenu(); foreach (var item in new[] { ("系统日志", (Action)ShowLogs), ("重启服务", () => _ = Restart()), ("开机启动", ToggleStartup), ("退出应用", Quit) }) { var entry = new MenuItem { Header = item.Item1 }; entry.Click += (_, _) => item.Item2(); menu.Items.Add(entry); }
        more.Click += (_, _) => { menu.PlacementTarget = more; menu.IsOpen = true; }; footer.Children.Add(more); panelBody.Children.Add(footer);
    }
    async Task SavePin() { string value = pinEdit!.Text; if (!ValidPin(value)) { pinError!.Text = "请输入四位数字（0000–9999）"; pinError.Visibility = Visibility.Visible; return; } string old = pin; pin = value; try { SaveSettings(); } catch (Exception ex) { pin = old; pinError!.Text = ex.Message; pinError.Visibility = Visibility.Visible; return; } editingPin = false; bool active = core != null && !core.HasExited; BuildPanel(); if (active) await Restart(); }
    string Privilege() { using var identity = System.Security.Principal.WindowsIdentity.GetCurrent(); return new System.Security.Principal.WindowsPrincipal(identity).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator) ? "管理员" : "普通用户"; }
    void CheckInputAccess() { if (MessageBox.Show("当前权限：" + Privilege() + "。\nWindows 普通桌面不需要辅助功能授权。要控制管理员窗口，本工具也需同等权限。\n首次连接请允许核心程序在专用网络中通过防火墙。\n\n是否打开 Windows 防火墙设置？", "运行权限", MessageBoxButton.YesNo) == MessageBoxResult.Yes) Open("windowsdefender://network"); }
    void Open(string path) { try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch (Exception ex) { MessageBox.Show(ex.Message); } }
    void ToggleStartup() { using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (key.GetValue("TVRemoteMouse") != null) key.DeleteValue("TVRemoteMouse", false); else key.SetValue("TVRemoteMouse", "\"" + Environment.ProcessPath + "\""); }
    void ShowLogs()
    {
        var window=Window("TVRemoteMouse 系统日志",900);window.SizeToContent=SizeToContent.Manual;window.Height=640;window.ResizeMode=ResizeMode.CanResize;
        var layout=new DockPanel { Margin=new Thickness(16) };window.Content=layout;
        var toolbar=new WrapPanel();DockPanel.SetDock(toolbar,Dock.Top);layout.Children.Add(toolbar);
        var search=new TextBox { Width=220,Margin=new Thickness(3),ToolTip="搜索日志" };toolbar.Children.Add(search);
        var level=new ComboBox { Width=100,Margin=new Thickness(3),ItemsSource=new[]{"全部","INFO","WARN","ERROR","DEBUG"},SelectedIndex=0 };toolbar.Children.Add(level);
        var live=new CheckBox { Content="自动刷新",IsChecked=true,Margin=new Thickness(8) };toolbar.Children.Add(live);
        var text=new TextBox { IsReadOnly=true,TextWrapping=TextWrapping.NoWrap,FontFamily=new FontFamily("Consolas"),FontSize=12,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Auto };layout.Children.Add(text);
        string current="";
        void Filter() { text.Text=string.Join("\n",current.Split('\n').Where(line=>(search.Text.Length==0||line.Contains(search.Text,StringComparison.OrdinalIgnoreCase))&&(level.SelectedIndex==0||line.Contains((string)level.SelectedItem)))); }
        void Read() { try { using var file=new FileStream(LogPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);if(file.Length>300000)file.Seek(-300000,SeekOrigin.End);using var reader=new StreamReader(file);current=reader.ReadToEnd();Filter(); } catch(IOException ex) { text.Text="暂无可读日志："+ex.Message; } }
        toolbar.Children.Add(Button("刷新",Read));toolbar.Children.Add(Button("导出",()=>{var dialog=new Microsoft.Win32.SaveFileDialog{FileName="TVRemoteMouse.log",Filter="日志|*.log"};if(dialog.ShowDialog(window)==true)try{File.WriteAllText(dialog.FileName,text.Text);}catch(Exception ex){MessageBox.Show(ex.Message);}}));toolbar.Children.Add(Button("打开文件",()=>Open(LogPath)));
        search.TextChanged+=(_,_)=>Filter();level.SelectionChanged+=(_,_)=>Filter();var timer=new DispatcherTimer{Interval=TimeSpan.FromSeconds(2)};timer.Tick+=(_,_)=>{if(live.IsChecked==true)Read();};window.Closed+=(_,_)=>timer.Stop();timer.Start();Read();window.Show();
    }
    async Task Settings(object data) { try { var response = await http.PostAsync("/api/touchpad_settings", new StringContent(JsonSerializer.Serialize(data), Encoding.UTF8, "application/json")); response.EnsureSuccessStatusCode(); await Refresh(); } catch (Exception ex) { MessageBox.Show(ex.Message, "设置失败"); } }
    async Task Action(string name) { try { var response = await http.PostAsync("/api/action", new StringContent(JsonSerializer.Serialize(new { button = name }), Encoding.UTF8, "application/json")); response.EnsureSuccessStatusCode(); } catch (Exception ex) { MessageBox.Show(ex.Message); } }
    static readonly (string Key, string Label)[] Inputs = { ("select", "触控区轻点"), ("two_finger_tap", "双指轻点"), ("three_finger_tap", "三指轻点"), ("four_finger_tap", "四指轻点"), ("menu", "返回"), ("home", "电视 / 主页"), ("guide", "列表"), ("power", "电源"), ("play_pause", "播放 / 暂停"), ("mute", "静音"), ("channel_up", "频道加"), ("channel_down", "频道减"), ("volume_up", "音量加"), ("volume_down", "音量减") };
    static readonly (string Key, string Label)[] Actions = { ("default", "默认功能"), ("disabled", "禁用"), ("left_click", "鼠标左键"), ("right_click", "鼠标右键"), ("toggle_scroll", "切换鼠标 / 双指滚动"), ("toggle_three_finger_drag", "切换鼠标 / 三指按住拖移"), ("toggle_four_finger_desktop", "切换鼠标 / 四指切换桌面"), ("hold_drag", "按住拖移"), ("desktop_previous", "切换桌面：上一个"), ("desktop_next", "切换桌面：下一个"), ("voice_input", "语音输入（Windows）"), ("up", "方向上"), ("down", "方向下"), ("left", "方向左"), ("right", "方向右"), ("select", "确认"), ("menu", "Escape"), ("home", "Home"), ("play_pause", "播放 / 暂停"), ("next_track", "下一曲"), ("prev_track", "上一曲"), ("volume_up", "音量加"), ("volume_down", "音量减"), ("mute", "静音"), ("power", "屏幕休眠 / 唤醒") };
    void ShowConsole()
    {
        panel?.Hide(); if (console != null) { console.Show(); console.Activate(); return; }
        console = Window("TVRemoteMouse 遥控控制台", 1100); console.SizeToContent = SizeToContent.Manual; console.Height = 780; console.ResizeMode = ResizeMode.CanResize; console.Closing += (_, e) => { if (!stopping) { e.Cancel = true; console.Hide(); } };
        var stack = new StackPanel { Margin = new Thickness(20) }; console.Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; stateLabel = Text(Connection() + " · " + S("client_name", "等待 iPhone"), 20); stack.Children.Add(stateLabel);
        var motionPanel = new StackPanel { Background = new SolidColorBrush(Color.FromRgb(235, 240, 247)), Margin = new Thickness(0, 12, 0, 8) };
        motionPanel.Children.Add(Text("鼠标与陀螺仪", 18));
        motionPanel.Children.Add(Text("鼠标：已接入系统遥控器触摸和按键。陀螺仪：系统遥控器尚未发送运动数据，当前不可启用。", 13));
        var tools = new WrapPanel(); tools.Children.Add(Button("鼠标光标", () => SetPointer("mouse"))); tools.Children.Add(Button("陀螺仪 · 未收到数据", () => MessageBox.Show("系统遥控器尚未收到陀螺仪数据"))); tools.Children.Add(Button("系统日志", ShowLogs)); tools.Children.Add(Button("检查权限", CheckInputAccess)); motionPanel.Children.Add(tools); stack.Children.Add(motionPanel);
        var sensitivity=new StackPanel{Orientation=Orientation.Horizontal}; sensitivity.Children.Add(Text("灵敏度")); foreach(var preset in new[]{("低",.7),("中",1.0),("高",1.5)}) sensitivity.Children.Add(Button(preset.Item1,()=>_=Settings(new{speed=preset.Item2,accel=false})));stack.Children.Add(sensitivity);
        foreach (var pair in new[] { ("动态加速度", "accel", B("mouse_accel")), ("详细事件日志", "verbose_events", B("verbose_events")) }) { var c = new CheckBox { Content = pair.Item1, IsChecked = pair.Item3, Margin = new Thickness(4) }; c.Click += (_, _) => _ = Settings(new Dictionary<string, object> { { pair.Item2, c.IsChecked == true } }); stack.Children.Add(c); }
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(360) }); grid.ColumnDefinitions.Add(new ColumnDefinition()); stack.Children.Add(grid); var left = new StackPanel { Margin = new Thickness(0, 15, 12, 0) }; grid.Children.Add(left); remoteArea = new StackPanel(); left.Children.Add(remoteArea); mappingArea = new StackPanel();
        var right = new StackPanel { Margin = new Thickness(0, 15, 0, 0) }; Grid.SetColumn(right, 1); grid.Children.Add(right); right.Children.Add(mappingArea);
        var diagnostics=new WrapPanel();stack.Children.Add(diagnostics);
        var trackBox=new StackPanel{Visibility=Visibility.Collapsed};trackBox.Children.Add(Text("触控轨迹",16));trajectory=new Canvas{Height=260,Background=Brushes.White,ClipToBounds=true};trackBox.Children.Add(trajectory);trackBox.Children.Add(Button("清空轨迹",()=>{trajectory.Children.Clear();trails.Clear();positions.Clear();}));stack.Children.Add(trackBox);
        var eventBox=new StackPanel{Visibility=Visibility.Collapsed};eventBox.Children.Add(Text("事件记录",16));history=Text("等待协议事件",11);eventBox.Children.Add(history);stack.Children.Add(eventBox);
        var historyBox=new StackPanel{Visibility=Visibility.Collapsed};historyBox.Children.Add(Text("最近按键",16));keyHistory=Text("等待遥控器输入",11);historyBox.Children.Add(keyHistory);stack.Children.Add(historyBox);
        foreach(var pair in new[]{("轨迹",trackBox),("事件记录",eventBox),("最近按键",historyBox)}) {var toggle=MakeButton("显示"+pair.Item1,(sender,_)=>{bool visible=pair.Item2.Visibility==Visibility.Visible;pair.Item2.Visibility=visible?Visibility.Collapsed:Visibility.Visible;((Button)sender).Content=(visible?"显示":"隐藏")+pair.Item1;});diagnostics.Children.Add(toggle);}
        BuildRemote(); BuildMapping(); console.PreviewKeyDown += RecordShortcut; console.Show();
    }
    ComboBox Choice((string, string)[] choices, string value, Action<string> changed) { var box = new ComboBox { Margin = new Thickness(2), MinWidth = 120 }; foreach (var pair in choices) box.Items.Add(new ComboBoxItem { Content = pair.Item2, Tag = pair.Item1 }); int index = Array.FindIndex(choices, x => x.Item1 == value); if (index < 0 && value.StartsWith("win_shortcut:")) { box.Items.Add(new ComboBoxItem { Content = "已录制 Windows 快捷键", Tag = value }); index = box.Items.Count - 1; } box.SelectedIndex = Math.Max(0, index); box.SelectionChanged += (_, _) => changed((string)((ComboBoxItem)box.SelectedItem).Tag); return box; }
    void BuildRemote()
    {
        if (remoteArea == null) return; remoteArea.Children.Clear();
        var remote = new StackPanel { Background = Brushes.Black, Margin = new Thickness(5) }; remote.Children.Add(new TextBlock { Text = S("client_name", "Apple TV Remote"), Foreground = Brushes.White, FontSize = 17, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(15) });
        var top = new UniformGridCompat(3); foreach (var pair in new[] { ("mute", "静音"), ("guide", "☷"), ("power", "⏻") }) top.Children.Add(RemoteButton(pair.Item1, pair.Item2)); remote.Children.Add(top);
        var touch = RemoteButton("select", ""); touch.Height = 235; touch.Margin = new Thickness(12); remote.Children.Add(touch);
        if (S("remote_surface") == "direction") remote.Children.Add(Text("检测到方向按钮：请在 iPhone 的 Apple TV 遥控器设置中关闭方向按钮，改用触摸板。", 12));
        var bottom = new UniformGridCompat(3); foreach (var pair in new[] { ("home", "▣"), ("menu", "❮"), ("channel_up", "CH ↑"), ("play_pause", "▶Ⅱ"), ("volume_down", "音量 −"), ("channel_down", "CH ↓") }) bottom.Children.Add(RemoteButton(pair.Item1, pair.Item2)); remote.Children.Add(bottom); remoteArea.Children.Add(remote);
    }
    Button RemoteButton(string key, string label) { var b = Button(label, () => { selected = key; BuildRemote(); BuildMapping(); }); b.Background = selected==key?Brushes.DodgerBlue:new SolidColorBrush(Color.FromRgb(32, 32, 33)); b.Foreground = Brushes.White; b.BorderBrush=Brushes.Cyan;b.BorderThickness = new Thickness(selected==key?2:0); b.MinHeight = 44; return b; }
    void BuildMapping()
    {
        if (mappingArea == null) return;
        editingShortcut = false;
        mappingArea.Children.Clear();
        mappingArea.Children.Add(Text("按键与手势映射", 16));
        var chosen = Text("已选择：" + Inputs.FirstOrDefault(x => x.Key == selected).Label, 18);
        chosen.Background = Brushes.DodgerBlue; chosen.Foreground = Brushes.White; chosen.Padding = new Thickness(12);
        mappingArea.Children.Add(chosen);
        mappingArea.Children.Add(Choice(Inputs.Select(x => (x.Key, x.Label)).ToArray(), selected, v => { selected = v; BuildRemote(); BuildMapping(); }));
        mappingArea.Children.Add(Choice(new[] { ("single", "单击"), ("double", "双击"), ("triple", "三击") }, trigger, v => { trigger = v; BuildMapping(); }));
        if (trigger != "single") mappingArea.Children.Add(Text("多击间隔最多 380 毫秒；单击执行会稍等片刻。", 11));
        string action = mappings.GetValueOrDefault(MappingKey, "default");
        var actions = trigger == "single" ? Actions : Actions.Select(x => (x.Key, x.Key == "default" ? "未设置" : x.Label)).ToArray();
        mappingArea.Children.Add(Choice(actions, action, v => SaveMapping(v)));
        if (action.StartsWith("win_shortcut:")) mappingArea.Children.Add(Text("已设置 Windows 快捷键：" + action));
        mappingArea.Children.Add(Button("录制 Windows 快捷键", () => { editingShortcut = true; mappingArea.Children.Add(Text("请按组合键；Esc 取消。")); console!.Focus(); }));
        mappingArea.Children.Add(Button("测试当前映射", () => _ = Action(MappingKey)));
        mappingArea.Children.Add(Button("释放拖移", () => _ = Action("release_drag")));
        mappingArea.Children.Add(Text("按住拖移：触发一次保持左键，滑动拖移，再次触发释放。", 11));
        mappingArea.Children.Add(Button(trigger == "single" ? "恢复此键默认" : "清除此映射", () => { SaveMapping("default"); BuildMapping(); }));
        mappingArea.Children.Add(Button("重置全部映射", () => { if (MessageBox.Show("恢复全部按键默认功能？", "映射", MessageBoxButton.OKCancel) == MessageBoxResult.OK) { mappings.Clear(); WriteMappings(); BuildMapping(); } }));
        mappingArea.Children.Add(Text("三指、四指轻点仅在手机发送独立触点时触发；系统遥控器目前没有发送其轨迹。", 11));
    }
    void SaveMapping(string value) { if (value == "default") mappings.Remove(MappingKey); else mappings[MappingKey] = value; WriteMappings(); }
    void WriteMappings() { try { var tmp = MappingPath + ".tmp"; File.WriteAllLines(tmp, mappings.OrderBy(x => x.Key).Select(x => x.Key + "=" + x.Value), new UTF8Encoding(false)); File.Move(tmp, MappingPath, true); } catch (Exception ex) { MessageBox.Show(ex.Message, "保存失败"); } }
    void RecordShortcut(object sender, KeyEventArgs e) { if (!editingShortcut) return; e.Handled = true; var key = e.Key == Key.System ? e.SystemKey : e.Key; if (key == Key.Escape) { BuildMapping(); return; } if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return; var mods = Keyboard.Modifiers; int flags = (mods.HasFlag(ModifierKeys.Control) ? 1 : 0) | (mods.HasFlag(ModifierKeys.Alt) ? 2 : 0) | (mods.HasFlag(ModifierKeys.Shift) ? 4 : 0) | (mods.HasFlag(ModifierKeys.Windows) ? 8 : 0); SaveMapping("win_shortcut:" + KeyInterop.VirtualKeyFromKey(key) + ":" + flags); BuildMapping(); }
    async Task ReadEvents(CancellationToken token)
    {
        using var client=new HttpClient { Timeout=Timeout.InfiniteTimeSpan };
        while(!token.IsCancellationRequested)
        {
            try
            {
                using var stream=await client.GetStreamAsync("http://127.0.0.1:18765/events",token);
                using var reader=new StreamReader(stream);
                while(!token.IsCancellationRequested)
                {
                    var line=await reader.ReadLineAsync(token);if(line==null)break;
                    if(!line.StartsWith("data: "))continue;
                    using var document=JsonDocument.Parse(line[6..]);var packet=document.RootElement.Clone();
                    await Dispatcher.InvokeAsync(()=>Consume(packet,line[6..]));
                }
            }
            catch(OperationCanceledException) { break; }
            catch(Exception) { }
            try { await Task.Delay(1000,token); } catch(OperationCanceledException) { break; }
        }
    }
    void Consume(JsonElement packet, string line)
    {
        if(packet.GetProperty("event").GetString()=="button") {buttonHistory.Add(packet.GetProperty("data").GetProperty("name").GetString()??"");if(buttonHistory.Count>25)buttonHistory.RemoveAt(0);if(keyHistory!=null)keyHistory.Text=string.Join("\n",buttonHistory);}
        eventLines.Add(line); if(eventLines.Count>80)eventLines.RemoveAt(0);
        if(history!=null)history.Text=string.Join("\n",eventLines.TakeLast(25));
        if(trajectory==null || packet.GetProperty("event").GetString()!="contact")return;
        var data=packet.GetProperty("data");int phase=data.GetProperty("phase").GetInt32(),finger=data.GetProperty("finger").GetInt32();
        var p=new Point(data.GetProperty("x").GetDouble()/1000*Math.Max(1,trajectory.ActualWidth),data.GetProperty("y").GetDouble()/1000*260);
        if(phase==1){var colors=new[]{Brushes.DodgerBlue,Brushes.Orange,Brushes.MediumSeaGreen,Brushes.MediumPurple};var path=new Polyline{Stroke=colors[Math.Abs(finger)%4],StrokeThickness=2};trails[finger]=path;trajectory.Children.Add(path);if(trajectory.Children.Count>100)trajectory.Children.RemoveAt(0);}
        if(trails.TryGetValue(finger,out var trail)){trail.Points.Add(p);if(trail.Points.Count>1000)trail.Points.RemoveAt(0);}
    }

    protected override void OnExit(ExitEventArgs e) { eventsCancel.Cancel();if(core!=null){if(!core.HasExited)core.Kill(true);core.Dispose();}tray.Visible=false;tray.Icon?.Dispose();tray.Dispose();http.Dispose();base.OnExit(e); }
    void Quit() { stopping=true;Shutdown(); }
    sealed class UniformGridCompat : System.Windows.Controls.Primitives.UniformGrid { public UniformGridCompat(int columns) { Columns = columns; } }
}
