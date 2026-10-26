using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class WidgetProgram {
    public static readonly string Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    public static readonly string StartupLink = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Codex 悬浮开关.lnk");
    public static bool IsMain(string file, string name, string command) {
        string prefix = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps", "OpenAI.Codex_");
        return !String.IsNullOrEmpty(file) && file.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            && (String.Equals(name,"ChatGPT.exe",StringComparison.OrdinalIgnoreCase) || String.Equals(name,"Codex.exe",StringComparison.OrdinalIgnoreCase))
            && !Regex.IsMatch(command ?? "", @"(?:^|\s)--type(?:=|\s)");
    }
    public static bool IsRunning() {
        using (var query = new ManagementObjectSearcher("SELECT Name, ExecutablePath, CommandLine FROM Win32_Process WHERE Name='ChatGPT.exe' OR Name='Codex.exe'")) {
            foreach (ManagementObject row in query.Get()) {
                using(row) { if (IsMain(row["ExecutablePath"] as string, row["Name"] as string, row["CommandLine"] as string)) return true; }
            }
        }
        return false;
    }
    public static void SetAutostart(bool enabled) {
        if (!enabled) { if (File.Exists(StartupLink)) File.Delete(StartupLink); return; }
        object shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        object shortcut = null;
        try {
            shortcut = shell.GetType().InvokeMember("CreateShortcut",BindingFlags.InvokeMethod,null,shell,new object[]{StartupLink});
            Type type = shortcut.GetType();
            type.InvokeMember("TargetPath",BindingFlags.SetProperty,null,shortcut,new object[]{Application.ExecutablePath});
            type.InvokeMember("WorkingDirectory",BindingFlags.SetProperty,null,shortcut,new object[]{Root});
            type.InvokeMember("IconLocation",BindingFlags.SetProperty,null,shortcut,new object[]{Path.Combine(Root,"CodexToggle.ico")+",0"});
            type.InvokeMember("Description",BindingFlags.SetProperty,null,shortcut,new object[]{"登录后只显示悬浮按钮；Codex 由你点击打开。"});
            type.InvokeMember("Save",BindingFlags.InvokeMethod,null,shortcut,null);
        } finally { if(shortcut!=null) Marshal.FinalReleaseComObject(shortcut); Marshal.FinalReleaseComObject(shell); }
    }
    [STAThread]
    public static int Main(string[] args) {
        if (Array.IndexOf(args,"--self-test")>=0) {
            string app=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"WindowsApps","OpenAI.Codex_test","app","ChatGPT.exe");
            if(!IsMain(app,"ChatGPT.exe", "ChatGPT.exe") || IsMain(app,"ChatGPT.exe","ChatGPT.exe --type=renderer") || IsMain("C:\\Other\\ChatGPT.exe","ChatGPT.exe","") || IsMain(app,"node.exe","")) return 2;
            File.WriteAllText(Path.Combine(Root,"widget-self-test.json"),new JavaScriptSerializer().Serialize(new { MainProcessRegression="PASS", Running=IsRunning(), StartupExists=File.Exists(StartupLink)}),Encoding.UTF8);
            return 0;
        }
        string sid=WindowsIdentity.GetCurrent().User.Value;
        bool created;
        using(var mutex=new Mutex(true,"Local\\CodexFloatingButton-"+sid,out created)) {
            if(!created) { IntPtr existing=Native.FindWindow(null,"Codex 悬浮开关"); if(existing!=IntPtr.Zero) Native.PostMessage(existing,0x8049,IntPtr.Zero,IntPtr.Zero); return 0; }
            Native.SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try { Application.Run(new FloatingButton()); }
            catch(Exception ex) { File.WriteAllText(Path.Combine(Root,"widget-error.log"),DateTime.Now+" "+ex,Encoding.UTF8); MessageBox.Show("悬浮按钮未能运行："+ex.Message,"Codex 悬浮开关",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
        }
        return 0;
    }
}

internal sealed class FloatingButton : Form {
    readonly Image artwork;
    readonly ToolTip tips=new ToolTip();
    readonly ContextMenuStrip menu=new ContextMenuStrip();
    readonly ToolStripMenuItem stateItem=new ToolStripMenuItem();
    readonly ToolStripMenuItem topItem=new ToolStripMenuItem("置顶显示");
    readonly ToolStripMenuItem autoItem=new ToolStripMenuItem("开机显示悬浮按钮");
    readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
    bool running, busy, dragging, probing, pressed;
    Point downCursor, downLocation;
    string activeAction="Toggle";
    readonly JavaScriptSerializer json=new JavaScriptSerializer();
    public FloatingButton() {
        Text="Codex 悬浮开关"; Name="CodexFloatingButton"; AccessibleName="Codex 悬浮开关";
        // Unowned window supports accessibility; WS_EX_TOOLWINDOW still suppresses its taskbar entry.
        FormBorderStyle=FormBorderStyle.None; ShowInTaskbar=true; StartPosition=FormStartPosition.Manual;
        AutoScaleMode=AutoScaleMode.None; Size=new Size(92,92); TopMost=true;
        Icon=new Icon(Path.Combine(WidgetProgram.Root,"CodexToggle.ico"));
        using(var original=Image.FromFile(Path.Combine(WidgetProgram.Root,"CodexToggle.png"))) artwork=new Bitmap(original);
        Cursor=Cursors.Hand; tips.InitialDelay=200;tips.ReshowDelay=100;tips.AutoPopDelay=5000;
        LoadPosition(); BuildMenu();
        Shown+=(s,e)=>{ RenderButton();Probe();timer.Start(); };
        Move+=(s,e)=>{if(IsHandleCreated) RenderButton();};
        FormClosed+=(s,e)=>{SavePosition();timer.Stop();timer.Dispose();artwork.Dispose();tips.Dispose();menu.Dispose();};
        timer.Interval=2500;timer.Tick+=(s,e)=>Probe();
    }
    protected override bool ShowWithoutActivation {get{return true;}}
    protected override void WndProc(ref Message m){if(m.Msg==0x8049){DefaultPosition();TopMost=true;topItem.Checked=true;SavePosition();RenderButton();return;}base.WndProc(ref m);}
    protected override CreateParams CreateParams {get{var p=base.CreateParams;p.ExStyle|=0x80000|0x80|0x08000000;return p;}}
    void BuildMenu() {
        stateItem.Enabled=false;menu.Items.Add(stateItem);menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("打开 Codex",null,(s,e)=>RunAction("Open"));
        menu.Items.Add("彻底关闭 Codex",null,(s,e)=>RunAction("Close"));
        menu.Items.Add(new ToolStripSeparator());
        topItem.Checked=TopMost;topItem.CheckOnClick=true;topItem.Click+=(s,e)=>{TopMost=topItem.Checked;SavePosition();};menu.Items.Add(topItem);
        autoItem.Checked=File.Exists(WidgetProgram.StartupLink);autoItem.CheckOnClick=true;
        autoItem.Click+=(s,e)=>{try{WidgetProgram.SetAutostart(autoItem.Checked);}catch(Exception ex){autoItem.Checked=File.Exists(WidgetProgram.StartupLink);ShowError(ex.Message);}};
        menu.Items.Add(autoItem);
        menu.Items.Add("回到屏幕右侧",null,(s,e)=>{DefaultPosition();SavePosition();});
        menu.Items.Add(new ToolStripSeparator());menu.Items.Add("退出悬浮按钮",null,(s,e)=>Close());
    }
    void DefaultPosition(){Rectangle r=Screen.PrimaryScreen.WorkingArea;Location=new Point(r.Right-Width-24,r.Top+(r.Height-Height)/2);}
    void LoadPosition(){
        DefaultPosition();
        try{
            string file=Path.Combine(WidgetProgram.Root,"widget-settings.json");if(!File.Exists(file))return;
            var d=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file,Encoding.UTF8));
            var point=new Point(Convert.ToInt32(d["X"]),Convert.ToInt32(d["Y"]));
            bool visible=false;foreach(Screen screen in Screen.AllScreens)if(screen.WorkingArea.Contains(new Rectangle(point,Size)))visible=true;
            if(visible)Location=point;if(d.ContainsKey("TopMost"))TopMost=Convert.ToBoolean(d["TopMost"]);
        }catch{}
    }
    void SavePosition(){try{File.WriteAllText(Path.Combine(WidgetProgram.Root,"widget-settings.json"),json.Serialize(new{X=Left,Y=Top,TopMost=TopMost}),Encoding.UTF8);}catch{}}
    void RenderButton(){
        if(!IsHandleCreated||IsDisposed)return;
        using(var bitmap=new Bitmap(Width,Height,PixelFormat.Format32bppPArgb)){
            using(var g=Graphics.FromImage(bitmap)){
                g.Clear(Color.Transparent);g.SmoothingMode=SmoothingMode.AntiAlias;g.InterpolationMode=InterpolationMode.HighQualityBicubic;
                g.DrawImage(artwork,new Rectangle(0,0,Width,Height));
                using(var bg=new SolidBrush(Color.FromArgb(245,12,27,34)))g.FillEllipse(bg,13,9,18,18);
                using(var brush=new SolidBrush(busy?Color.FromArgb(255,193,78):running?Color.FromArgb(63,228,160):Color.FromArgb(151,171,182)))g.FillEllipse(brush,17,13,10,10);
            }
            Native.SetBitmap(Handle,bitmap,Location);
        }
        string status=busy?(activeAction=="Close"?"正在关闭 Codex…":activeAction=="Open"?"正在打开 Codex…":"正在检查 Codex 状态和出口…"):running?"Codex 已运行 · 单击确认关闭":"Codex 未运行 · 单击检查出口并打开";
        tips.SetToolTip(this,status+"\n按住拖动 · 右键菜单");stateItem.Text=status;
    }
    void Probe(){
        if(probing||IsDisposed)return;probing=true;
        Task.Run(()=>{
            try{bool value=WidgetProgram.IsRunning();if(!IsDisposed)BeginInvoke((Action)(()=>{running=value;probing=false;RenderButton();}));}
            catch{if(!IsDisposed)try{BeginInvoke((Action)(()=>probing=false));}catch{}}
        });
    }
    void RunAction(string action){
        if(busy)return;busy=true;activeAction="Check";RenderButton();
        Task.Run(()=>{
            string planned=action,failure=null;ExitCheckResult check=null;
            try{
                if(action=="Toggle")planned=WidgetProgram.IsRunning()?"Close":"Open";
                if(planned=="Open"){
                    check=StaticExitChecker.Check(WidgetProgram.Root);
                    try{File.WriteAllText(Path.Combine(WidgetProgram.Root,"last-network-check.json"),new JavaScriptSerializer().Serialize(check),Encoding.UTF8);}catch{}
                }
            }catch(Exception error){failure=error.Message;}
            if(!IsDisposed)try{BeginInvoke((Action)(()=>{
                if(failure!=null){busy=false;RenderButton();ShowError(failure);return;}
                bool started=false;
                try{
                    started=CodexActionGuard.TryExecute(planned,check,
                        (text,title,icon)=>MessageBox.Show(this,text,title,MessageBoxButtons.YesNo,icon,MessageBoxDefaultButton.Button2)==DialogResult.Yes,
                        ()=>{activeAction=planned;RenderButton();ExecuteAction(planned);});
                }catch(Exception error){ShowError(error.Message);}
                if(!started){busy=false;RenderButton();Probe();}
            }));}catch{}
        });
    }
    void ExecuteAction(string action){
        Task.Run(()=>{
            string failure=null;
            try{
                var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0","powershell.exe"));
                start.Arguments="-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \""+Path.Combine(WidgetProgram.Root,"CodexToggle.ps1")+"\" -Action "+action+" -Quiet";
                start.UseShellExecute=false;start.CreateNoWindow=true;start.WindowStyle=ProcessWindowStyle.Hidden;
                start.RedirectStandardOutput=true;start.RedirectStandardError=true;
                var errors=new StringBuilder();
                using(var process=new Process()){
                    process.StartInfo=start;process.OutputDataReceived+=(s,e)=>{};process.ErrorDataReceived+=(s,e)=>{if(e.Data!=null)lock(errors)errors.AppendLine(e.Data);};
                    process.Start();process.BeginOutputReadLine();process.BeginErrorReadLine();
                    if(!process.WaitForExit(45000)){process.Kill();failure="操作等待超时，请稍后再试。";}else{process.WaitForExit();if(process.ExitCode!=0)failure="操作未完成，请查看运行记录。\n"+errors.ToString().Trim();}
                }
            }catch(Exception ex){failure=ex.Message;}
            if(!IsDisposed)try{BeginInvoke((Action)(()=>{busy=false;Probe();RenderButton();if(failure!=null)ShowError(failure);}));}catch{}
        });
    }
    void ShowError(string text){MessageBox.Show(text,"Codex 悬浮开关",MessageBoxButtons.OK,MessageBoxIcon.Information);}
    protected override void OnMouseDown(MouseEventArgs e){base.OnMouseDown(e);if(e.Button==MouseButtons.Left){pressed=true;dragging=false;downCursor=Cursor.Position;downLocation=Location;Capture=true;}}
    protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);if(!pressed)return;Point delta=new Point(Cursor.Position.X-downCursor.X,Cursor.Position.Y-downCursor.Y);if(Math.Abs(delta.X)+Math.Abs(delta.Y)>6)dragging=true;if(dragging){Point pos=new Point(downLocation.X+delta.X,downLocation.Y+delta.Y);Rectangle area=Screen.FromPoint(Cursor.Position).WorkingArea;Location=new Point(Math.Max(area.Left,Math.Min(pos.X,area.Right-Width)),Math.Max(area.Top,Math.Min(pos.Y,area.Bottom-Height)));}}
    protected override void OnMouseUp(MouseEventArgs e){base.OnMouseUp(e);if(e.Button==MouseButtons.Right){menu.Show(this,e.Location);return;}if(e.Button!=MouseButtons.Left||!pressed)return;pressed=false;Capture=false;if(dragging){SavePosition();dragging=false;}else RunAction("Toggle");}
}

internal static class Native {
    [StructLayout(LayoutKind.Sequential)]struct PointI{public int X,Y;public PointI(int x,int y){X=x;Y=y;}}
    [StructLayout(LayoutKind.Sequential)]struct SizeI{public int X,Y;public SizeI(int x,int y){X=x;Y=y;}}
    [StructLayout(LayoutKind.Sequential,Pack=1)]struct Blend{public byte Op,Flags,Alpha,Format;}
    [DllImport("user32.dll")]internal static extern bool SetProcessDPIAware();
    [DllImport("user32.dll",CharSet=CharSet.Unicode)]internal static extern IntPtr FindWindow(string className,string title);
    [DllImport("user32.dll")]internal static extern bool PostMessage(IntPtr handle,int message,IntPtr wParam,IntPtr lParam);
    [DllImport("user32.dll")]static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")]static extern int ReleaseDC(IntPtr h,IntPtr dc);
    [DllImport("gdi32.dll")]static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")]static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")]static extern IntPtr SelectObject(IntPtr dc,IntPtr value);
    [DllImport("gdi32.dll")]static extern bool DeleteObject(IntPtr value);
    [DllImport("user32.dll")]static extern bool UpdateLayeredWindow(IntPtr h,IntPtr screen,ref PointI top,ref SizeI size,IntPtr src,ref PointI zero,int key,ref Blend blend,int flags);
    internal static void SetBitmap(IntPtr handle,Bitmap bitmap,Point point){
        IntPtr screen=GetDC(IntPtr.Zero),memory=CreateCompatibleDC(screen),image=IntPtr.Zero,old=IntPtr.Zero;
        try{image=bitmap.GetHbitmap(Color.FromArgb(0));old=SelectObject(memory,image);var top=new PointI(point.X,point.Y);var size=new SizeI(bitmap.Width,bitmap.Height);var zero=new PointI(0,0);var blend=new Blend{Op=0,Flags=0,Alpha=255,Format=1};UpdateLayeredWindow(handle,screen,ref top,ref size,memory,ref zero,0,ref blend,2);}
        finally{if(old!=IntPtr.Zero)SelectObject(memory,old);if(image!=IntPtr.Zero)DeleteObject(image);DeleteDC(memory);ReleaseDC(IntPtr.Zero,screen);}
    }
}
