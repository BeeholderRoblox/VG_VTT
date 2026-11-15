// Vagabond VTT desktop app.
// A tiny launcher: starts vtt-server.ps1 in the background (no console window) and opens the VTT
// in its own app window using the Edge (Chromium) engine that ships with Windows.
// Closing the VTT window stops the server. Nothing is downloaded and no outside services are used.
// Build with build-app.ps1 (uses the C# compiler that comes with Windows).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Net;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class VttApp {
    static readonly string Dir = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string Data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VagabondVTT");
    static readonly Color Bg = Color.FromArgb(28, 26, 36), Panel = Color.FromArgb(40, 37, 52), Gold = Color.FromArgb(224, 178, 74), Ink = Color.FromArgb(230, 226, 240), Dim = Color.FromArgb(150, 145, 170);
    static Icon AppIcon;
    static StreamWriter Log;
    static readonly object LogLock = new object();

    [STAThread]
    static void Main(string[] args) {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try { AppIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        if (!File.Exists(Path.Combine(Dir, "vagabond-vtt.html")) || !File.Exists(Path.Combine(Dir, "vtt-server.ps1"))) {
            Fail("Vagabond VTT.exe needs vagabond-vtt.html and vtt-server.ps1 in the same folder.\n\nKeep all the VTT files together.");
            return;
        }
        Directory.CreateDirectory(Data);
        string mode = null;
        foreach (string a in args) { string s = a.TrimStart('-', '/').ToLowerInvariant(); if (s == "gm" || s == "host") mode = "gm"; else if (s == "join") mode = "join"; }
        if (mode == null) mode = Pick();
        if (mode == null) return;
        Run(mode == "join");
    }

    // ---------- first screen: GM or player ----------
    static string Pick() {
        string result = null;
        Form f = new Form();
        f.Text = "Vagabond VTT"; f.Icon = AppIcon; f.BackColor = Bg; f.ForeColor = Ink;
        f.FormBorderStyle = FormBorderStyle.FixedSingle; f.MaximizeBox = false; f.StartPosition = FormStartPosition.CenterScreen;
        f.ClientSize = new Size(440, 300); f.Font = new Font("Segoe UI", 10f);
        Label t = new Label(); t.Text = "VAGABOND VTT"; t.Font = new Font("Segoe UI Semibold", 20f); t.ForeColor = Gold;
        t.AutoSize = false; t.TextAlign = ContentAlignment.MiddleCenter; t.SetBounds(0, 18, 440, 44); f.Controls.Add(t);
        Label sub = new Label(); sub.Text = "How are you playing today?"; sub.ForeColor = Dim; sub.AutoSize = false;
        sub.TextAlign = ContentAlignment.MiddleCenter; sub.SetBounds(0, 62, 440, 24); f.Controls.Add(sub);
        string last = ReadSetting("lastMode");
        Button gm = BigButton("Run my game  (GM)", "Hosts the game on this PC. Friends join through Steam or your Wi-Fi.", 100);
        Button join = BigButton("Join a friend via Steam", "Your GM must be a Steam friend and already running their game.", 190);
        gm.Click += delegate { result = "gm"; f.Close(); };
        join.Click += delegate { result = "join"; f.Close(); };
        f.Controls.Add(gm); f.Controls.Add(join);
        f.AcceptButton = last == "join" ? join : gm;
        f.Shown += delegate { (last == "join" ? join : gm).Focus(); };
        Application.Run(f);
        if (result != null) WriteSetting("lastMode", result);
        return result;
    }
    static Button BigButton(string title, string hint, int y) {
        Button b = new Button();
        b.Text = title + "\n" + hint; b.TextAlign = ContentAlignment.MiddleLeft; b.Padding = new Padding(14, 0, 8, 0);
        b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderColor = Color.FromArgb(80, 72, 100); b.FlatAppearance.MouseOverBackColor = Color.FromArgb(56, 50, 74);
        b.BackColor = Panel; b.ForeColor = Ink; b.Cursor = Cursors.Hand; b.SetBounds(24, y, 392, 76);
        b.Paint += delegate(object s, PaintEventArgs e) {
            // draw a bold title line and a dim hint line instead of the default single style
            e.Graphics.Clear(b.ClientRectangle.Contains(b.PointToClient(Cursor.Position)) ? b.FlatAppearance.MouseOverBackColor : b.BackColor);
            using (Pen p = new Pen(b.Focused ? Gold : b.FlatAppearance.BorderColor, b.Focused ? 2 : 1)) e.Graphics.DrawRectangle(p, 1, 1, b.Width - 3, b.Height - 3);
            using (Font tf = new Font("Segoe UI Semibold", 12.5f)) TextRenderer.DrawText(e.Graphics, title, tf, new Point(16, 12), Ink);
            using (Font hf = new Font("Segoe UI", 9f)) TextRenderer.DrawText(e.Graphics, hint, hf, new Rectangle(16, 40, b.Width - 30, 30), Dim, TextFormatFlags.WordBreak);
        };
        return b;
    }

    // ---------- run ----------
    static void Run(bool join) {
        int port = join ? 8091 : 8090;
        string url = "http://localhost:" + port + "/" + (join ? "" : "?app=gm");
        Process server = null;

        if (!IsVtt(port, join)) {
            string logPath = Path.Combine(Data, join ? "join.log" : "server.log");
            try { Log = new StreamWriter(logPath, false, new UTF8Encoding(false)); Log.AutoFlush = true; } catch { }
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(Dir, "vtt-server.ps1") + "\"" + (join ? " -Join" : "") + " -ParentPid " + Process.GetCurrentProcess().Id);
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = Dir;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8; psi.StandardErrorEncoding = Encoding.UTF8;
            try { server = Process.Start(psi); }
            catch (Exception e) { Fail("Couldn't start the game server (PowerShell).\n\n" + e.Message); return; }
            server.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { WriteLog(e.Data); };
            server.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { WriteLog(e.Data); };
            server.BeginOutputReadLine(); server.BeginErrorReadLine();

            // small "starting" window while the server comes up (Steam's first-time setup can take a bit)
            Form splash = Splash(join ? "Connecting to Steam…" : "Starting your game server…");
            splash.Show(); Application.DoEvents();
            DateTime until = DateTime.Now.AddSeconds(120);
            bool up = false;
            while (DateTime.Now < until && !splash.IsDisposed) {
                if (server.HasExited) break;
                if (IsVtt(port, join)) { up = true; break; }
                for (int i = 0; i < 5; i++) { Application.DoEvents(); Thread.Sleep(50); }
            }
            bool cancelled = splash.IsDisposed;
            if (!splash.IsDisposed) splash.Close();
            if (cancelled) { Kill(server); return; }
            if (!up) {
                Thread.Sleep(300);
                Kill(server);
                Fail((join ? "Couldn't join through Steam." : "The game server didn't start.") + "\n\n" + LogTail(logPath, 6) + "\n\nFull log: " + logPath);
                return;
            }
        }

        string browser = FindBrowser();
        if (browser == null) {
            // no Edge/Chrome: fall back to the default browser and keep a small window to stop the server
            try { Process.Start(url); } catch { }
            MessageBox.Show("Vagabond VTT is open in your browser at\n" + url + "\n\nClick OK when you're done playing to stop the server.", "Vagabond VTT", MessageBoxButtons.OK, MessageBoxIcon.Information);
            Kill(server);
            return;
        }
        string profile = Path.Combine(Data, "browser");
        string bargs = "--app=\"" + url + "\" --user-data-dir=\"" + profile + "\" --no-first-run --no-default-browser-check --disable-sync" +
            " --disable-features=msEdgeSidebarV2,msHubApps,msUndersideButton,msEdgeTranslate,Translate --window-size=1440,900" +
            // draw on the graphics card: GPU canvas rasterizing even on drivers Edge is unsure about, and the fast GPU on laptops with two
            " --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy --force_high_performance_gpu";
        try { Process.Start(browser, bargs); }
        catch (Exception e) { Kill(server); Fail("Couldn't open the VTT window.\n\n" + e.Message); return; }

        // wait until every window of our app profile is closed
        Thread.Sleep(4000);
        int misses = 0;
        while (misses < 2) { if (AppWindowsOpen(profile)) misses = 0; else misses++; Thread.Sleep(1500); }

        // the server watches this app and shuts itself down cleanly (Steam, router port) once we exit;
        // give it a moment, then make sure it's gone
        if (server != null && !server.HasExited) { Thread.Sleep(100); }
    }

    static bool AppWindowsOpen(string profile) {
        try {
            using (ManagementObjectSearcher q = new ManagementObjectSearcher("SELECT CommandLine FROM Win32_Process WHERE Name='msedge.exe' OR Name='chrome.exe'"))
                foreach (ManagementObject o in q.Get()) {
                    string cl = o["CommandLine"] as string;
                    if (cl != null && cl.IndexOf(profile, StringComparison.OrdinalIgnoreCase) >= 0) return true;
                }
        } catch { return true; }
        return false;
    }

    static string FindBrowser() {
        foreach (string exe in new[] { "msedge.exe", "chrome.exe" }) {
            foreach (RegistryKey root in new[] { Registry.LocalMachine, Registry.CurrentUser }) {
                try {
                    using (RegistryKey k = root.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" + exe)) {
                        string p = k == null ? null : k.GetValue("") as string;
                        if (!string.IsNullOrEmpty(p) && File.Exists(p.Trim('"'))) return p.Trim('"');
                    }
                } catch { }
            }
        }
        string[] guesses = {
            Environment.ExpandEnvironmentVariables(@"%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"),
            Environment.ExpandEnvironmentVariables(@"%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"),
            Environment.ExpandEnvironmentVariables(@"%ProgramFiles%\Google\Chrome\Application\chrome.exe"),
            Environment.ExpandEnvironmentVariables(@"%LocalAppData%\Google\Chrome\Application\chrome.exe") };
        foreach (string g in guesses) if (File.Exists(g)) return g;
        return null;
    }

    // is a VTT server (of the right kind) already answering on this port?
    static bool IsVtt(int port, bool join) {
        try {
            HttpWebRequest r = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/vtt-info");
            r.Timeout = 800; r.ReadWriteTimeout = 800; r.Proxy = null;
            using (WebResponse resp = r.GetResponse()) using (StreamReader sr = new StreamReader(resp.GetResponseStream())) {
                string s = sr.ReadToEnd();
                return s.Contains("\"vtt\":true") && s.Contains("\"steamJoin\":" + (join ? "true" : "false"));
            }
        } catch { return false; }
    }

    static Form Splash(string text) {
        Form f = new Form();
        f.Text = "Vagabond VTT"; f.Icon = AppIcon; f.BackColor = Bg; f.ForeColor = Ink;
        f.FormBorderStyle = FormBorderStyle.FixedSingle; f.MaximizeBox = false; f.MinimizeBox = false;
        f.StartPosition = FormStartPosition.CenterScreen; f.ClientSize = new Size(360, 110); f.Font = new Font("Segoe UI", 10.5f);
        Label l = new Label(); l.Text = text; l.AutoSize = false; l.TextAlign = ContentAlignment.MiddleCenter; l.SetBounds(0, 22, 360, 30); f.Controls.Add(l);
        ProgressBar p = new ProgressBar(); p.Style = ProgressBarStyle.Marquee; p.MarqueeAnimationSpeed = 25; p.SetBounds(40, 64, 280, 14); f.Controls.Add(p);
        return f;
    }

    static void WriteLog(string line) {
        if (line == null || Log == null) return;
        lock (LogLock) { try { Log.WriteLine(line); } catch { } }
    }
    static string LogTail(string path, int n) {
        try {
            string[] all;
            lock (LogLock) { if (Log != null) Log.Flush(); }
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) using (StreamReader sr = new StreamReader(fs)) all = sr.ReadToEnd().Split('\n');
            List<string> keep = new List<string>();
            for (int i = all.Length - 1; i >= 0 && keep.Count < n; i--) { string s = all[i].Trim(); if (s.Length > 0 && !s.StartsWith("---") && !s.StartsWith("===")) keep.Insert(0, s); }
            return keep.Count > 0 ? string.Join("\n", keep.ToArray()) : "(no details)";
        } catch { return "(no details)"; }
    }
    static void Kill(Process p) { try { if (p != null && !p.HasExited) p.Kill(); } catch { } }
    static void Fail(string msg) { MessageBox.Show(msg, "Vagabond VTT", MessageBoxButtons.OK, MessageBoxIcon.Warning); }

    static string SettingsPath { get { return Path.Combine(Data, "launcher.txt"); } }
    static string ReadSetting(string key) {
        try { foreach (string l in File.ReadAllLines(SettingsPath)) if (l.StartsWith(key + "=")) return l.Substring(key.Length + 1); } catch { }
        return null;
    }
    static void WriteSetting(string key, string val) { try { File.WriteAllText(SettingsPath, key + "=" + val + "\n"); } catch { } }
}
