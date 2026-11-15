<#
  Vagabond VTT game server + Steam helper.

  GM:      double-click "Start VTT Server.bat"
           Serves the VTT to players on your network, and (if Steam is running) lets Steam friends
           join through Steam's own networking. No port forwarding needed for Steam players.
  Player:  double-click "Join via Steam.bat"
           Connects to your GM through Steam and opens the VTT in your browser.

  Steam networking is reached through Valve's steam_api64.dll using Valve's public test app
  "Spacewar" (App ID 480). While it runs, Steam shows you as "Playing Spacewar".
  The DLL is copied once from a Valve-signed copy inside one of your installed Steam games.

  Options: -Port 8090  -NoUpnp  -NoSteam  -LocalOnly  -Join
#>
param([int]$Port = 0, [switch]$NoUpnp, [switch]$LocalOnly, [switch]$Join, [switch]$NoSteam, [int]$ParentPid = 0)
# -ParentPid: started by the desktop app; stop by ourselves when the app closes
function Test-ParentGone { return ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Port -le 0) { $Port = $(if ($Join) { 8091 } else { 8090 }) }
if (-not (Test-Path (Join-Path $here 'vagabond-vtt.html'))) {
  Write-Host "vagabond-vtt.html was not found next to this script ($here)." -ForegroundColor Red
  Write-Host "Keep vagabond-vtt.html, vtt-server.ps1 and the .bat files in the same folder."
  exit 1
}
if (-not [Environment]::Is64BitProcess) { Write-Host 'Please run this with 64-bit PowerShell.' -ForegroundColor Red; exit 1 }

if (-not ('VttServer' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class Util {
    public static string JsonStr(string s) {
        if (s == null) return "null";
        StringBuilder sb = new StringBuilder("\"");
        foreach (char ch in s) {
            if (ch == '"') sb.Append("\\\""); else if (ch == '\\') sb.Append("\\\\");
            else if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4")); else sb.Append(ch);
        }
        return sb.Append("\"").ToString();
    }
    public static string Err(string text) { return "{\"type\":\"error\",\"text\":" + JsonStr(text) + "}"; }
}

/* ---------------- Steam networking (ISteamNetworkingMessages via the flat C API) ---------------- */
public static class SteamNet {
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string p);
    [DllImport("kernel32", CharSet = CharSet.Ansi, ExactSpelling = true)] static extern IntPtr GetProcAddress(IntPtr h, string n);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_InitFlat(IntPtr err);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_InitOld();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_Void();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Pipe();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_PipeVoid(int pipe);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_NextCb(int pipe, IntPtr msg);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_Ptr();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Send(IntPtr self, IntPtr ident, IntPtr data, uint len, int flags, int channel);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_Recv(IntPtr self, int channel, IntPtr outArr, int max);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_Accept(IntPtr self, IntPtr ident);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_Release(IntPtr msg);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_SelfStr(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_SetRP(IntPtr self, IntPtr k, IntPtr v);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_FriendRP(IntPtr self, ulong id, IntPtr k);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_FriendCount(IntPtr self, int flags);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong D_FriendByIdx(IntPtr self, int i, int flags);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr D_FriendName(IntPtr self, ulong id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_GamePlayed(IntPtr self, ulong id, IntPtr info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_ReqRP(IntPtr self, ulong id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate ulong D_SteamId(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void D_SelfVoid(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] delegate bool D_Close(IntPtr self, IntPtr ident);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_SessInfo(IntPtr self, IntPtr ident, IntPtr info, IntPtr status);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int D_RelayStatus(IntPtr self, IntPtr details);

    static IntPtr lib, msgs, friends, user, utils, identBuf, cbBuf, recvArr, gameInfo;
    static D_Close fClose; static D_SessInfo fSessInfo; static D_RelayStatus fRelay;
    // every Steam call happens on the Steam thread; other threads queue work here
    static readonly ConcurrentQueue<Action> work = new ConcurrentQueue<Action>();
    public static void Post(Action a) { work.Enqueue(a); }
    public static Action<ulong> OnSessionRequest;
    static int pipe;
    static D_PipeVoid fRunFrame, fFreeCb; static D_NextCb fNextCb; static D_Send fSend; static D_Recv fRecv; static D_Accept fAccept; static D_Release fRelease;
    static D_SetRP fSetRP; static D_FriendRP fFriendRP; static D_FriendCount fFriendCount; static D_FriendByIdx fFriendByIdx; static D_FriendName fFriendName;
    static D_GamePlayed fGamePlayed; static D_ReqRP fReqRP;

    public static volatile bool Ready;
    public static ulong MyId;
    public static string MyName = "";
    public static string Error = "";
    public static volatile bool ScanFriends;
    public static volatile string HostsJson = "[]";
    public static Action<ulong, string> OnText;
    public static Action<ulong> OnSessionFailed;
    public static Func<ulong, bool> AcceptFrom;

    static readonly ConcurrentQueue<KeyValuePair<ulong, byte[]>> outbox = new ConcurrentQueue<KeyValuePair<ulong, byte[]>>();
    static readonly ConcurrentQueue<KeyValuePair<string, string>> rpQueue = new ConcurrentQueue<KeyValuePair<string, string>>();
    static readonly Dictionary<string, byte[][]> partial = new Dictionary<string, byte[][]>();
    static readonly HashSet<ulong> requested = new HashSet<ulong>();
    const int CHUNK = 400 * 1024;
    static int nextMsgId = 0;

    static T F<T>(string name) where T : class {
        IntPtr p = GetProcAddress(lib, name);
        if (p == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }
    static IntPtr Accessor(params string[] names) {
        foreach (string n in names) { D_Ptr f = F<D_Ptr>(n); if (f != null) { IntPtr r = f(); if (r != IntPtr.Zero) return r; } }
        return IntPtr.Zero;
    }
    static string Utf8(IntPtr p) {
        if (p == IntPtr.Zero) return "";
        List<byte> b = new List<byte>();
        for (int i = 0; i < 4096; i++) { byte x = Marshal.ReadByte(p, i); if (x == 0) break; b.Add(x); }
        return Encoding.UTF8.GetString(b.ToArray());
    }
    static IntPtr Utf8Ptr(string s) {
        byte[] b = Encoding.UTF8.GetBytes(s ?? "");
        IntPtr p = Marshal.AllocHGlobal(b.Length + 1);
        Marshal.Copy(b, 0, p, b.Length); Marshal.WriteByte(p, b.Length, 0);
        return p;
    }

    public static bool Start(string dll, string dir) {
        ManualResetEvent done = new ManualResetEvent(false);
        Thread t = new Thread(() => {
            try { InitInternal(dll, dir); } catch (Exception e) { Error = e.Message; }
            done.Set();
            if (Ready) Loop();
        });
        t.IsBackground = true; t.Start();
        done.WaitOne(30000);
        return Ready;
    }

    static void InitInternal(string dll, string dir) {
        Environment.SetEnvironmentVariable("SteamAppId", "480");
        Environment.SetEnvironmentVariable("SteamGameId", "480");
        try { File.WriteAllText(Path.Combine(dir, "steam_appid.txt"), "480"); } catch { }
        Directory.SetCurrentDirectory(dir);
        lib = LoadLibrary(dll);
        if (lib == IntPtr.Zero) { Error = "Could not load steam_api64.dll"; return; }
        bool ok;
        D_InitFlat initFlat = F<D_InitFlat>("SteamAPI_InitFlat");
        if (initFlat != null) {
            IntPtr err = Marshal.AllocHGlobal(1024); Marshal.WriteByte(err, 0, 0);
            int r = initFlat(err); ok = r == 0;
            if (!ok) Error = "Steam could not start (" + Utf8(err) + "). Is Steam running and are you logged in?";
            Marshal.FreeHGlobal(err);
        } else {
            D_InitOld io = F<D_InitOld>("SteamAPI_Init");
            if (io == null) { Error = "This steam_api64.dll is too old."; return; }
            ok = io();
            if (!ok) Error = "Steam could not start. Is Steam running and are you logged in?";
        }
        if (!ok) return;

        D_Void mdInit = F<D_Void>("SteamAPI_ManualDispatch_Init");
        D_Pipe getPipe = F<D_Pipe>("SteamAPI_GetHSteamPipe");
        fRunFrame = F<D_PipeVoid>("SteamAPI_ManualDispatch_RunFrame");
        fNextCb = F<D_NextCb>("SteamAPI_ManualDispatch_GetNextCallback");
        fFreeCb = F<D_PipeVoid>("SteamAPI_ManualDispatch_FreeLastCallback");
        fSend = F<D_Send>("SteamAPI_ISteamNetworkingMessages_SendMessageToUser");
        fRecv = F<D_Recv>("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel");
        fAccept = F<D_Accept>("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser");
        fRelease = F<D_Release>("SteamAPI_SteamNetworkingMessage_t_Release");
        fClose = F<D_Close>("SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser");
        fSessInfo = F<D_SessInfo>("SteamAPI_ISteamNetworkingMessages_GetSessionConnectionInfo");
        fRelay = F<D_RelayStatus>("SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus");
        if (mdInit == null || getPipe == null || fRunFrame == null || fNextCb == null || fFreeCb == null || fSend == null || fRecv == null || fAccept == null || fRelease == null) {
            Error = "This steam_api64.dll is missing Steam networking functions (too old)."; return;
        }
        mdInit(); pipe = getPipe();
        msgs = Accessor("SteamAPI_SteamNetworkingMessages_SteamAPI_v002");
        friends = Accessor("SteamAPI_SteamFriends_v018", "SteamAPI_SteamFriends_v017", "SteamAPI_SteamFriends_v019");
        user = Accessor("SteamAPI_SteamUser_v023", "SteamAPI_SteamUser_v024", "SteamAPI_SteamUser_v022", "SteamAPI_SteamUser_v021");
        utils = Accessor("SteamAPI_SteamNetworkingUtils_SteamAPI_v004", "SteamAPI_SteamNetworkingUtils_SteamAPI_v003");
        if (msgs == IntPtr.Zero) { Error = "Steam networking is not available."; return; }
        if (user != IntPtr.Zero) { D_SteamId gid = F<D_SteamId>("SteamAPI_ISteamUser_GetSteamID"); if (gid != null) MyId = gid(user); }
        if (friends != IntPtr.Zero) {
            D_SelfStr gpn = F<D_SelfStr>("SteamAPI_ISteamFriends_GetPersonaName"); if (gpn != null) MyName = Utf8(gpn(friends));
            fSetRP = F<D_SetRP>("SteamAPI_ISteamFriends_SetRichPresence");
            fFriendRP = F<D_FriendRP>("SteamAPI_ISteamFriends_GetFriendRichPresence");
            fFriendCount = F<D_FriendCount>("SteamAPI_ISteamFriends_GetFriendCount");
            fFriendByIdx = F<D_FriendByIdx>("SteamAPI_ISteamFriends_GetFriendByIndex");
            fFriendName = F<D_FriendName>("SteamAPI_ISteamFriends_GetFriendPersonaName");
            fGamePlayed = F<D_GamePlayed>("SteamAPI_ISteamFriends_GetFriendGamePlayed");
            fReqRP = F<D_ReqRP>("SteamAPI_ISteamFriends_RequestFriendRichPresence");
        }
        if (utils != IntPtr.Zero) { D_SelfVoid irn = F<D_SelfVoid>("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess"); if (irn != null) irn(utils); }
        identBuf = Marshal.AllocHGlobal(136); for (int i = 0; i < 136; i++) Marshal.WriteByte(identBuf, i, 0);
        cbBuf = Marshal.AllocHGlobal(64); recvArr = Marshal.AllocHGlobal(8 * 64); gameInfo = Marshal.AllocHGlobal(64);
        Ready = true;
    }

    public static volatile int RelayState = 0;   // 100 = Steam's relay network is ready
    public static bool RelayReady { get { return RelayState == 100 || fRelay == null; } }
    static void SetIdent(ulong to) {
        Marshal.WriteInt32(identBuf, 0, 16); Marshal.WriteInt32(identBuf, 4, 8); Marshal.WriteInt64(identBuf, 8, (long)to);
    }
    // must run on the Steam thread
    static void CloseNow(ulong who) { if (fClose == null) return; SetIdent(who); fClose(msgs, identBuf); }
    public static void CloseSession(ulong who) { Post(() => CloseNow(who)); }
    // 1 connecting, 2 finding a route, 3 connected, 4 closed by the other side, 5 problem, 0 no session
    public static volatile int LastState = 0;
    public static void QueryState(ulong who, Action<int> done) {
        Post(() => { int st = 0; if (fSessInfo != null) { SetIdent(who); st = fSessInfo(msgs, identBuf, IntPtr.Zero, IntPtr.Zero); } LastState = st; done(st); });
    }
    static readonly ConcurrentDictionary<ulong, string> names = new ConcurrentDictionary<ulong, string>();
    static void LearnName(ulong id) {   // Steam thread only
        try { if (fFriendName != null && friends != IntPtr.Zero) { string n = Utf8(fFriendName(friends, id)); if (!string.IsNullOrEmpty(n) && n != "[unknown]") names[id] = n; } } catch { }
    }
    public static string NameOf(ulong id) { string n; return names.TryGetValue(id, out n) ? n : "a Steam player"; }

    static void Loop() {
        DateTime lastScan = DateTime.MinValue, lastRelay = DateTime.MinValue;
        while (true) {
            try {
                fRunFrame(pipe);
                while (fNextCb(pipe, cbBuf)) {
                    int id = Marshal.ReadInt32(cbBuf, 4);
                    IntPtr param = Marshal.ReadIntPtr(cbBuf, 8);
                    if (id == 1251 && param != IntPtr.Zero) {            // SteamNetworkingMessagesSessionRequest_t
                        int type = Marshal.ReadInt32(param, 0);
                        ulong who = (ulong)Marshal.ReadInt64(param, 8);
                        if (type == 16 && (AcceptFrom == null || AcceptFrom(who))) {
                            bool ok = fAccept(msgs, param); LearnName(who);
                            Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  Steam: " + NameOf(who) + " is connecting" + (ok ? "..." : " (accept failed)"));
                            Action<ulong> sr = OnSessionRequest; if (sr != null) sr(who);
                        }
                    } else if (id == 1252 && param != IntPtr.Zero) {     // SteamNetworkingMessagesSessionFailed_t
                        // SteamNetConnectionInfo_t starts with the remote identity; close the dead session so the next attempt starts clean
                        ulong who = (ulong)Marshal.ReadInt64(param, 8);
                        CloseNow(who);
                        Action<ulong> f = OnSessionFailed; if (f != null) f(who);
                    }
                    fFreeCb(pipe);
                }
                Action job; while (work.TryDequeue(out job)) { try { job(); } catch (Exception e) { Console.WriteLine("Steam: " + e.Message); } }
                if ((DateTime.UtcNow - lastRelay).TotalSeconds > 1) { lastRelay = DateTime.UtcNow; if (fRelay != null && utils != IntPtr.Zero) RelayState = fRelay(utils, IntPtr.Zero); }
                int n;
                while ((n = fRecv(msgs, 0, recvArr, 64)) > 0) {
                    for (int i = 0; i < n; i++) {
                        IntPtr m = Marshal.ReadIntPtr(recvArr, i * 8);
                        IntPtr data = Marshal.ReadIntPtr(m, 0);
                        int size = Marshal.ReadInt32(m, 8);
                        ulong who = (ulong)Marshal.ReadInt64(m, 24);
                        byte[] b = new byte[Math.Max(0, size)];
                        if (size > 0) Marshal.Copy(data, b, 0, size);
                        fRelease(m);
                        if (!names.ContainsKey(who)) LearnName(who);
                        try { HandleIncoming(who, b); } catch (Exception e) { Console.WriteLine("Steam message error: " + e.Message); }
                    }
                }
                KeyValuePair<ulong, byte[]> o; int sent = 0;
                while (sent < 200 && outbox.TryDequeue(out o)) { SendRaw(o.Key, o.Value); sent++; }
                KeyValuePair<string, string> rp;
                while (rpQueue.TryDequeue(out rp)) SetRPNow(rp.Key, rp.Value);
                if (ScanFriends && (DateTime.UtcNow - lastScan).TotalSeconds > 3) { lastScan = DateTime.UtcNow; ScanHosts(); }
            } catch (Exception e) { Console.WriteLine("Steam: " + e.Message); }
            Thread.Sleep(5);
        }
    }

    public static void SendText(ulong to, string s) {
        if (!Ready) return;
        byte[] d = Encoding.UTF8.GetBytes(s);
        if (d.Length + 1 <= CHUNK) {
            byte[] p = new byte[d.Length + 1]; p[0] = 0; Buffer.BlockCopy(d, 0, p, 1, d.Length);
            outbox.Enqueue(new KeyValuePair<ulong, byte[]>(to, p)); return;
        }
        int id = Interlocked.Increment(ref nextMsgId);
        int total = (d.Length + CHUNK - 1) / CHUNK;
        for (int i = 0; i < total; i++) {
            int off = i * CHUNK, len = Math.Min(CHUNK, d.Length - off);
            byte[] p = new byte[9 + len]; p[0] = 1;
            BitConverter.GetBytes(id).CopyTo(p, 1); BitConverter.GetBytes((ushort)i).CopyTo(p, 5); BitConverter.GetBytes((ushort)total).CopyTo(p, 7);
            Buffer.BlockCopy(d, off, p, 9, len);
            outbox.Enqueue(new KeyValuePair<ulong, byte[]>(to, p));
        }
    }

    static void HandleIncoming(ulong who, byte[] b) {
        if (b.Length < 1) return;
        string text = null;
        if (b[0] == 0) text = Encoding.UTF8.GetString(b, 1, b.Length - 1);
        else if (b[0] == 1 && b.Length >= 9) {
            int id = BitConverter.ToInt32(b, 1); int idx = BitConverter.ToUInt16(b, 5); int total = BitConverter.ToUInt16(b, 7);
            if (total == 0 || idx >= total || total > 400) return;
            string key = who + ":" + id; byte[][] parts;
            if (!partial.TryGetValue(key, out parts) || parts.Length != total) { parts = new byte[total][]; partial[key] = parts; }
            byte[] chunk = new byte[b.Length - 9]; Buffer.BlockCopy(b, 9, chunk, 0, chunk.Length); parts[idx] = chunk;
            foreach (byte[] x in parts) if (x == null) return;
            partial.Remove(key);
            MemoryStream ms = new MemoryStream(); foreach (byte[] x in parts) ms.Write(x, 0, x.Length);
            text = Encoding.UTF8.GetString(ms.ToArray());
        }
        Action<ulong, string> f = OnText;
        if (text != null && f != null) f(who, text);
    }

    static void SendRaw(ulong to, byte[] p) {
        SetIdent(to);                                  // k_ESteamNetworkingIdentityType_SteamID
        IntPtr d = Marshal.AllocHGlobal(Math.Max(1, p.Length));
        Marshal.Copy(p, 0, d, p.Length);
        // Reliable only. No AutoRestartBrokenSession: that flag makes every retry open a brand-new connection while the other side
        // is still holding the first one, and Steam drops them all ("Symmetric role resolution ... we are already the server").
        // Broken sessions are closed explicitly instead (SessionFailed callback / join retries), so the next attempt starts clean.
        int r = fSend(msgs, identBuf, d, (uint)p.Length, 8, 0);
        Marshal.FreeHGlobal(d);
        if (r != 1) { Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  Steam send to " + NameOf(to) + " failed (result " + r + "), resetting that connection"); CloseNow(to); }
    }

    public static void SetRichPresence(string k, string v) { rpQueue.Enqueue(new KeyValuePair<string, string>(k, v)); }
    static void SetRPNow(string k, string v) {
        if (fSetRP == null || friends == IntPtr.Zero) return;
        IntPtr pk = Utf8Ptr(k), pv = Utf8Ptr(v);
        fSetRP(friends, pk, pv);
        Marshal.FreeHGlobal(pk); Marshal.FreeHGlobal(pv);
    }

    static void ScanHosts() {
        if (friends == IntPtr.Zero || fFriendCount == null || fFriendByIdx == null || fFriendRP == null) return;
        StringBuilder sb = new StringBuilder("["); bool first = true;
        IntPtr key = Utf8Ptr("vtt_host"), pkey = Utf8Ptr("vtt_players");
        int n = fFriendCount(friends, 4);   // k_EFriendFlagImmediate
        for (int i = 0; i < n && i < 3000; i++) {
            ulong id = fFriendByIdx(friends, i, 4);
            if (fGamePlayed == null || !fGamePlayed(friends, id, gameInfo)) continue;
            ulong gid = (ulong)Marshal.ReadInt64(gameInfo, 0);
            if ((gid & 0xFFFFFF) != 480) continue;
            if (fReqRP != null && requested.Add(id)) fReqRP(friends, id);
            string code = Utf8(fFriendRP(friends, id, key));
            if (string.IsNullOrEmpty(code)) continue;
            string name = fFriendName != null ? Utf8(fFriendName(friends, id)) : id.ToString();
            string who = Utf8(fFriendRP(friends, id, pkey));
            sb.Append(first ? "" : ",").Append("{\"id\":\"").Append(id).Append("\",\"name\":").Append(Util.JsonStr(name)).Append(",\"code\":").Append(Util.JsonStr(code))
              .Append(",\"players\":").Append(Util.JsonStr(who)).Append("}");
            first = false;
        }
        Marshal.FreeHGlobal(key); Marshal.FreeHGlobal(pkey);
        HostsJson = sb.Append("]").ToString();
    }
}

/* ---------------- web server + message hub ---------------- */
public class VttClient {
    public TcpClient Tcp;
    public Stream S;
    public readonly object Lk = new object();
    public string Id;
    public volatile bool Alive = true;
}
public class SteamPeer { public ulong Id; public string Key; public DateTime Last; }

public class VttServer {
    TcpListener listener;
    string root;
    string code = "";
    readonly object gate = new object();
    VttClient gm;
    readonly Dictionary<string, VttClient> players = new Dictionary<string, VttClient>();
    readonly Dictionary<ulong, SteamPeer> steamPeers = new Dictionary<ulong, SteamPeer>();
    int nextId = 0;
    public string Info = "{}";
    public bool JoinMode;
    public bool SteamOn;
    VttClient joinLocal; ulong joinGm; volatile bool joinHeard;

    public void Start(int port, string rootDir, string gameCode, bool localOnly) {
        root = rootDir; code = gameCode ?? "";
        listener = new TcpListener(localOnly ? IPAddress.Loopback : IPAddress.Any, port);
        listener.Start();
        Thread t = new Thread(AcceptLoop); t.IsBackground = true; t.Start();
    }
    public void Stop() { try { listener.Stop(); } catch { } }
    static void Log(string s) { Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  " + s); }
    static void Warn(string s) { ConsoleColor old = Console.ForegroundColor; try { Console.ForegroundColor = ConsoleColor.Yellow; Log(s); } finally { Console.ForegroundColor = old; } }
    static void Good(string s) { ConsoleColor old = Console.ForegroundColor; try { Console.ForegroundColor = ConsoleColor.Green; Log(s); } finally { Console.ForegroundColor = old; } }

    /* ---- Steam: GM side ---- */
    public void EnableSteamHost() {
        SteamOn = true;
        SteamNet.AcceptFrom = delegate(ulong id) { return true; };
        SteamNet.OnText = OnSteamHost;
        SteamNet.SetRichPresence("vtt_host", code);
        SteamNet.SetRichPresence("vtt_players", "");
        SteamNet.SetRichPresence("status", "Hosting a Vagabond VTT game");
        Thread reaper = new Thread(() => {
            while (true) {
                Thread.Sleep(5000);
                List<SteamPeer> gone = new List<SteamPeer>(); VttClient g;
                lock (gate) {
                    foreach (SteamPeer p in steamPeers.Values) if ((DateTime.UtcNow - p.Last).TotalSeconds > 25) gone.Add(p);
                    foreach (SteamPeer p in gone) steamPeers.Remove(p.Id);
                    g = gm;
                }
                foreach (SteamPeer p in gone) { SteamNet.CloseSession(p.Id); if (g != null) SendText(g, p.Key + "\n{\"type\":\"_leave\"}"); Log(SteamNet.NameOf(p.Id) + " timed out over Steam."); }
            }
        });
        reaper.IsBackground = true; reaper.Start();
    }
    void OnSteamHost(ulong who, string txt) {
        SteamPeer p; VttClient g; bool known;
        lock (gate) { known = steamPeers.TryGetValue(who, out p); g = gm; }
        bool isJoin = txt.Contains("\"type\":\"_join\"");
        if (isJoin) {
            Match m = Regex.Match(txt, "\"code\":\"([^\"]*)\"");
            string c = m.Success ? m.Groups[1].Value.Trim().ToUpperInvariant() : "";
            if (c != code) { SteamNet.SendText(who, Util.Err("Wrong game code. Check it with your GM.")); Log("Turned away " + SteamNet.NameOf(who) + " (wrong game code)."); return; }
            if (!known) { p = new SteamPeer(); p.Id = who; p.Key = "s" + who; lock (gate) { steamPeers[who] = p; } Log(SteamNet.NameOf(who) + " joined over Steam."); }
            p.Last = DateTime.UtcNow;
            SteamNet.SendText(who, "{\"type\":\"_joined\",\"gm\":" + Util.JsonStr(SteamNet.MyName) + "}");
            if (g == null) {
                SteamNet.SendText(who, "{\"type\":\"_gmleft\"}");
                Warn(SteamNet.NameOf(who) + " is connected and waiting, but your game isn't hosted yet. Open vagabond-vtt.html and click Multiplayer -> Host.");
            }
            return;
        }
        if (!known) return;
        p.Last = DateTime.UtcNow;
        if (txt == "{\"type\":\"_ping\"}") return;
        if (txt == "{\"type\":\"_bye\"}") {
            lock (gate) { steamPeers.Remove(who); }
            SteamNet.CloseSession(who);
            if (g != null) SendText(g, p.Key + "\n{\"type\":\"_leave\"}");
            Log(SteamNet.NameOf(who) + " left."); return;
        }
        if (g != null) SendText(g, p.Key + "\n" + txt);
    }

    /* ---- Steam: player side ---- */
    public void EnableSteamJoin() {
        SteamOn = true;
        SteamNet.ScanFriends = true;
        SteamNet.AcceptFrom = delegate(ulong id) { return id == joinGm; };
        SteamNet.OnText = delegate(ulong who, string txt) {
            VttClient c;
            lock (gate) { if (who != joinGm) return; c = joinLocal; }
            if (c == null) return;
            if (txt.StartsWith("{\"type\":\"_joined\"")) {
                bool first = !joinHeard; joinHeard = true;
                if (first) {
                    Log("Connected to the GM over Steam.");
                    SendText(c, "{\"type\":\"_steam\",\"phase\":\"connected\",\"text\":\"Connected to your GM through Steam\"}");
                    SendText(c, "{\"type\":\"_gmback\"}");   // makes the page (re)send its hello now that the link is real
                }
                return;
            }
            if (!joinHeard) return;
            SendText(c, txt);
        };
        SteamNet.OnSessionFailed = delegate(ulong who) {
            lock (gate) { if (who != joinGm) return; }
            joinFailed = true;
            if (joinHeard) { joinHeard = false; Log("The Steam connection to the GM dropped. Reconnecting..."); }
        };
    }
    volatile bool joinFailed;
    void Status(VttClient c, string phase, string text) { SendText(c, "{\"type\":\"_steam\",\"phase\":" + Util.JsonStr(phase) + ",\"text\":" + Util.JsonStr(text) + "}"); }
    void JoinSession(VttClient c, Dictionary<string, string> q) {
        string gmS, pc; q.TryGetValue("gm", out gmS); q.TryGetValue("code", out pc);
        ulong gmId;
        if (gmS == null || !ulong.TryParse(gmS.Trim(), out gmId) || gmId == 0) { SendText(c, Util.Err("Enter your GM's Steam friend code.")); Close(c); return; }
        if (gmId < 76561197960265728UL) gmId += 76561197960265728UL;
        if (gmId == SteamNet.MyId) { SendText(c, Util.Err("That's your own Steam account. Enter the GM's friend code.")); Close(c); return; }
        VttClient old;
        lock (gate) { old = joinLocal; joinLocal = c; joinGm = gmId; joinHeard = false; joinFailed = false; }
        if (old != null) Close(old);
        string joinMsg = "{\"type\":\"_join\",\"code\":" + Util.JsonStr((pc ?? "").Trim().ToUpperInvariant()) + "}";
        Log("Contacting the GM over Steam...");
        Thread hb = new Thread(() => {
            DateTime started = DateTime.UtcNow, lastTry = DateTime.MinValue, lastPing = DateTime.UtcNow; int tries = 0, lastShown = -1;
            // 1) wait (briefly) for Steam's relay network, so the first attempt doesn't fail and leave a half-open connection behind
            if (!SteamNet.RelayReady) Status(c, "relay", "Starting Steam networking…");
            while (c.Alive && !SteamNet.RelayReady && (DateTime.UtcNow - started).TotalSeconds < 15) Thread.Sleep(250);
            while (c.Alive) {
                if (joinHeard) {
                    if ((DateTime.UtcNow - lastPing).TotalSeconds >= 5) { lastPing = DateTime.UtcNow; SteamNet.SendText(gmId, "{\"type\":\"_ping\"}"); }
                    started = DateTime.UtcNow; tries = 0; lastShown = -1; lastTry = DateTime.MinValue; Thread.Sleep(250); continue;
                }
                // 2) not linked yet: start a clean attempt (close any stale session first), then give it ~12 s to complete
                if (lastTry == DateTime.MinValue || joinFailed || (DateTime.UtcNow - lastTry).TotalSeconds > 12) {
                    joinFailed = false; tries++;
                    if (tries > 1) Status(c, "retry", "Still trying to reach your GM (attempt " + tries + ")…");
                    else Status(c, "contacting", "Contacting your GM through Steam…");
                    SteamNet.CloseSession(gmId); Thread.Sleep(tries > 1 ? 1500 : 300);
                    SteamNet.SendText(gmId, joinMsg); lastTry = DateTime.UtcNow;
                }
                // 3) tell the page what Steam is doing
                SteamNet.QueryState(gmId, st => {
                    if (joinHeard || st == lastShown) return; lastShown = st;
                    if (st == 1) Status(c, "contacting", "Contacting your GM through Steam…");
                    else if (st == 2) Status(c, "route", "Finding a route to your GM…");
                    else if (st == 3) Status(c, "linked", "Linked with your GM's PC. Waiting for their game…");
                    else if (st == 4 || st == 5) Status(c, "retry", "Steam couldn't reach your GM yet. Trying again…");
                });
                if ((DateTime.UtcNow - started).TotalSeconds > 90) {
                    SendText(c, Util.Err("Couldn't reach the GM over Steam after 90 seconds. Check: the GM's server window says STEAM IS ON, you're Steam friends, the game code matches, and both of you clicked Allow if Windows asked about the network."));
                    Close(c); break;
                }
                Thread.Sleep(1000);
            }
        });
        hb.IsBackground = true; hb.Start();
        try {
            while (c.Alive) {
                int op; byte[] data = ReadMessage(c.S, out op);
                if (data == null || op == 8) break;
                if (op == 9) { SendFrame(c, 10, data); continue; }
                if (op != 1) continue;
                if (!joinHeard) continue;   // the page resends its hello once the Steam link is up
                SteamNet.SendText(gmId, Encoding.UTF8.GetString(data));
            }
        } catch { }
        Close(c);
        SteamNet.SendText(gmId, "{\"type\":\"_bye\"}");
        Log("Left the game.");
    }

    /* ---- HTTP + WebSocket plumbing ---- */
    void AcceptLoop() {
        while (true) {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); } catch { return; }
            Thread t = new Thread(Handle); t.IsBackground = true; t.Start(c);
        }
    }
    static string ReadHead(Stream s) {
        List<byte> buf = new List<byte>(); int b;
        while ((b = s.ReadByte()) != -1) {
            buf.Add((byte)b); int n = buf.Count;
            if (n >= 4 && buf[n - 4] == 13 && buf[n - 3] == 10 && buf[n - 2] == 13 && buf[n - 1] == 10) return Encoding.ASCII.GetString(buf.ToArray());
            if (n > 16384) return null;
        }
        return null;
    }
    static Dictionary<string, string> ParseQuery(string q) {
        Dictionary<string, string> d = new Dictionary<string, string>();
        foreach (string part in q.Split('&')) {
            if (part.Length == 0) continue;
            int i = part.IndexOf('=');
            string k = i < 0 ? part : part.Substring(0, i), v = i < 0 ? "" : part.Substring(i + 1);
            try { d[Uri.UnescapeDataString(k)] = Uri.UnescapeDataString(v.Replace('+', ' ')); } catch { }
        }
        return d;
    }
    void Handle(object o) {
        TcpClient tcp = (TcpClient)o;
        try {
            tcp.NoDelay = true;
            NetworkStream ns = tcp.GetStream();
            ns.ReadTimeout = 15000;
            string head = ReadHead(ns);
            if (head == null) { tcp.Close(); return; }
            string[] lines = head.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            string[] rl = lines[0].Split(' ');
            if (rl.Length < 2) { tcp.Close(); return; }
            string path = rl[1];
            Dictionary<string, string> h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length; i++) { int k = lines[i].IndexOf(':'); if (k > 0) h[lines[i].Substring(0, k).Trim()] = lines[i].Substring(k + 1).Trim(); }
            string q = ""; int qi = path.IndexOf('?');
            if (qi >= 0) { q = path.Substring(qi + 1); path = path.Substring(0, qi); }
            string up;
            if (path == "/ws" && h.TryGetValue("Upgrade", out up) && up.ToLowerInvariant() == "websocket") {
                ns.ReadTimeout = Timeout.Infinite; ns.WriteTimeout = 30000;
                WebSocket(tcp, ns, h, ParseQuery(q));
                return;
            }
            if (path.StartsWith("/campaign")) { CampaignApi(tcp, ns, rl[0], path, ParseQuery(q), h); }
            else if (path.StartsWith("/art-")) { ArtApi(tcp, ns, rl[0], path, ParseQuery(q), h); }
            else Serve(ns, path);
        } catch { }
        try { tcp.Close(); } catch { }
    }
    /* ---- campaign files: saved next to the app in "Campaigns\<name>\", only for requests from this PC ---- */
    string CampDir { get { return Path.Combine(root, "Campaigns"); } }
    static string SafeName(string n) {
        if (string.IsNullOrEmpty(n)) n = "Campaign";
        char[] bad = Path.GetInvalidFileNameChars(); StringBuilder sb = new StringBuilder();
        foreach (char ch in n) sb.Append(Array.IndexOf(bad, ch) >= 0 ? '_' : ch);
        string s = sb.ToString().Trim().TrimEnd('.');
        if (s.Length > 60) s = s.Substring(0, 60).Trim();
        if (s.Length == 0 || s == "." || s == "..") s = "Campaign";
        return s;
    }
    static void Reply(Stream s, string status, string type, byte[] body) {
        byte[] hb = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
        s.Write(hb, 0, hb.Length); s.Write(body, 0, body.Length); s.Flush();
    }
    static long UnixMs(DateTime t) { return (long)(t.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }
    string ListCampaigns() {
        StringBuilder sb = new StringBuilder("["); bool first = true;
        if (Directory.Exists(CampDir)) foreach (string d in Directory.GetDirectories(CampDir)) {
            FileInfo[] fs = new DirectoryInfo(d).GetFiles("*.json");
            if (fs.Length == 0) continue;
            Array.Sort(fs, delegate(FileInfo a, FileInfo b) { return b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc); });
            if (!first) sb.Append(','); first = false;
            sb.Append("{\"name\":").Append(Util.JsonStr(Path.GetFileName(d))).Append(",\"files\":[");
            for (int i = 0; i < fs.Length && i < 60; i++) {
                if (i > 0) sb.Append(',');
                sb.Append("{\"f\":").Append(Util.JsonStr(fs[i].Name)).Append(",\"t\":").Append(UnixMs(fs[i].LastWriteTime)).Append(",\"size\":").Append(fs[i].Length).Append('}');
            }
            sb.Append("]}");
        }
        return sb.Append(']').ToString();
    }
    void CampaignApi(TcpClient tcp, Stream s, string method, string path, Dictionary<string, string> q, Dictionary<string, string> h) {
        IPEndPoint ep = tcp.Client.RemoteEndPoint as IPEndPoint;
        if (ep == null || !IPAddress.IsLoopback(ep.Address)) { Reply(s, "403 Forbidden", "text/plain", Encoding.UTF8.GetBytes("Only the GM's own PC can do that.")); return; }
        if (!LocalPage(h)) { Reply(s, "403 Forbidden", "text/plain", Encoding.UTF8.GetBytes("Only the VTT page on this PC can do that.")); Warn("Blocked a request from another website (" + OriginOf(h) + ")."); return; }
        try {
            string c, f, name, kind;
            q.TryGetValue("c", out c); q.TryGetValue("f", out f); q.TryGetValue("name", out name); q.TryGetValue("kind", out kind);
            if (path == "/campaigns" && method == "GET") { Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"folder\":" + Util.JsonStr(CampDir) + ",\"list\":" + ListCampaigns() + "}")); return; }
            if (path == "/campaign-file" && method == "GET") {
                string file = Path.Combine(Path.Combine(CampDir, SafeName(c)), Path.GetFileName(f ?? ""));
                if (!file.EndsWith(".json", StringComparison.OrdinalIgnoreCase) || !File.Exists(file)) { Reply(s, "404 Not Found", "text/plain", Encoding.UTF8.GetBytes("No such save")); return; }
                Reply(s, "200 OK", "application/json", File.ReadAllBytes(file)); return;
            }
            if (path == "/campaign-save" && method == "POST") {
                string ls; int len = 0; if (h.TryGetValue("Content-Length", out ls)) int.TryParse(ls, out len);
                if (len <= 0 || len > 256 * 1024 * 1024) { Reply(s, "413 Payload Too Large", "text/plain", Encoding.UTF8.GetBytes("Bad size")); return; }
                byte[] body = new byte[len]; int got = 0;
                while (got < len) { int n = s.Read(body, got, len - got); if (n <= 0) break; got += n; }
                if (got < len) { Reply(s, "400 Bad Request", "text/plain", Encoding.UTF8.GetBytes("Incomplete")); return; }
                string safe = SafeName(name), dir = Path.Combine(CampDir, safe); Directory.CreateDirectory(dir);
                string tag = kind == "manual" ? "saved" : kind == "switch" ? "before switching" : "auto";
                string file = Path.Combine(dir, safe + " " + DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss") + " " + tag + ".json");
                File.WriteAllBytes(file + ".tmp", body); if (File.Exists(file)) File.Delete(file); File.Move(file + ".tmp", file);
                // keep the 30 newest automatic backups of each campaign (saves you made yourself are kept)
                FileInfo[] autos = new DirectoryInfo(dir).GetFiles("* auto.json");
                Array.Sort(autos, delegate(FileInfo a, FileInfo b) { return a.LastWriteTimeUtc.CompareTo(b.LastWriteTimeUtc); });
                for (int i = 0; i < autos.Length - 30; i++) { try { autos[i].Delete(); } catch { } }
                Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"ok\":true,\"file\":" + Util.JsonStr(Path.GetFileName(file)) + ",\"folder\":" + Util.JsonStr(dir) + "}")); return;
            }
            if (path == "/campaign-open" && method == "POST") {   // show the folder in File Explorer
                string dir = string.IsNullOrEmpty(c) ? CampDir : Path.Combine(CampDir, SafeName(c)); Directory.CreateDirectory(dir);
                System.Diagnostics.Process.Start("explorer.exe", "\"" + dir + "\"");
                Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}")); return;
            }
            Reply(s, "404 Not Found", "text/plain", Encoding.UTF8.GetBytes("Not found"));
        } catch (Exception e) { try { Reply(s, "500 Internal Server Error", "text/plain", Encoding.UTF8.GetBytes(e.Message)); } catch { } }
    }    /* ---- art folders: "Art\" next to the app (every campaign) and "Campaigns\<name>\Art\" (that campaign only) ----
       Subfolders are categories, each picture is a PNG, and art.json holds per-picture settings. Only this PC can use these. */
    string ArtRoot(Dictionary<string, string> q) {
        string scope, c; q.TryGetValue("scope", out scope); q.TryGetValue("c", out c);
        return scope == "campaign" ? Path.Combine(Path.Combine(CampDir, SafeName(c)), "Art") : Path.Combine(root, "Art");
    }
    // "Trees/Pine Tree.png" -> a safe path inside the art folder (no "..", no drive letters, at most 3 levels, .png only)
    static string SafeArtPath(string artRoot, string p) {
        if (string.IsNullOrEmpty(p)) return null;
        string[] parts = p.Replace('\\', '/').Split(new char[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || parts.Length > 3) return null;
        string full = artRoot;
        for (int i = 0; i < parts.Length; i++) { string s = SafeName(parts[i]); if (s == "Campaign" && parts[i] != "Campaign") return null; full = Path.Combine(full, s); }
        if (!full.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) return null;
        string a = Path.GetFullPath(artRoot).TrimEnd('\\') + "\\", b = Path.GetFullPath(full);
        return b.StartsWith(a, StringComparison.OrdinalIgnoreCase) ? b : null;
    }
    static byte[] ReadBody(Stream s, Dictionary<string, string> h, int max) {
        string ls; int len = 0; if (h.TryGetValue("Content-Length", out ls)) int.TryParse(ls, out len);
        if (len <= 0 || len > max) return null;
        byte[] body = new byte[len]; int got = 0;
        while (got < len) { int n = s.Read(body, got, len - got); if (n <= 0) break; got += n; }
        return got < len ? null : body;
    }
    void ArtApi(TcpClient tcp, Stream s, string method, string path, Dictionary<string, string> q, Dictionary<string, string> h) {
        IPEndPoint ep = tcp.Client.RemoteEndPoint as IPEndPoint;
        if (ep == null || !IPAddress.IsLoopback(ep.Address)) { Reply(s, "403 Forbidden", "text/plain", Encoding.UTF8.GetBytes("Only the GM's own PC can do that.")); return; }
        if (!LocalPage(h)) { Reply(s, "403 Forbidden", "text/plain", Encoding.UTF8.GetBytes("Only the VTT page on this PC can do that.")); Warn("Blocked a request from another website (" + OriginOf(h) + ")."); return; }
        try {
            string ar = ArtRoot(q), p; q.TryGetValue("p", out p);
            if (path == "/art-list" && method == "GET") {
                StringBuilder sb = new StringBuilder("{\"folder\":").Append(Util.JsonStr(ar)).Append(",\"files\":[");
                bool first = true;
                if (Directory.Exists(ar)) foreach (string f in Directory.GetFiles(ar, "*.png", SearchOption.AllDirectories)) {
                    string rel = f.Substring(ar.Length).TrimStart('\\').Replace('\\', '/');
                    if (rel.StartsWith("_Removed/", StringComparison.OrdinalIgnoreCase) || rel.Split('/').Length > 3) continue;
                    FileInfo fi = new FileInfo(f); if (fi.Length > 4 * 1024 * 1024) continue;
                    if (!first) sb.Append(','); first = false;
                    sb.Append("{\"p\":").Append(Util.JsonStr(rel)).Append(",\"t\":").Append(UnixMs(fi.LastWriteTime)).Append(",\"size\":").Append(fi.Length).Append('}');
                }
                string mf = Path.Combine(ar, "art.json"), manifest = File.Exists(mf) ? File.ReadAllText(mf, Encoding.UTF8) : "{}";
                if (manifest.Trim().Length == 0 || manifest.TrimStart()[0] != '{') manifest = "{}";
                sb.Append("],\"manifest\":").Append(manifest).Append('}');
                Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes(sb.ToString())); return;
            }
            if (path == "/art-file" && method == "GET") {
                string f = SafeArtPath(ar, p); if (f == null || !File.Exists(f)) { Reply(s, "404 Not Found", "text/plain", Encoding.UTF8.GetBytes("No such picture")); return; }
                Reply(s, "200 OK", "image/png", File.ReadAllBytes(f)); return;
            }
            if (path == "/art-save" && method == "POST") {
                string f = SafeArtPath(ar, p); if (f == null) { Reply(s, "400 Bad Request", "text/plain", Encoding.UTF8.GetBytes("Bad picture path")); return; }
                byte[] body = ReadBody(s, h, 4 * 1024 * 1024);
                if (body == null || body.Length < 8 || body[0] != 0x89 || body[1] != 0x50 || body[2] != 0x4E || body[3] != 0x47) { Reply(s, "400 Bad Request", "text/plain", Encoding.UTF8.GetBytes("Not a PNG")); return; }
                Directory.CreateDirectory(Path.GetDirectoryName(f));
                File.WriteAllBytes(f + ".tmp", body); if (File.Exists(f)) File.Delete(f); File.Move(f + ".tmp", f);
                Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}")); return;
            }
            if (path == "/art-manifest" && method == "POST") {
                byte[] body = ReadBody(s, h, 2 * 1024 * 1024); if (body == null) { Reply(s, "400 Bad Request", "text/plain", Encoding.UTF8.GetBytes("Bad settings")); return; }
                string txt = Encoding.UTF8.GetString(body).Trim(); if (txt.Length == 0 || txt[0] != '{') { Reply(s, "400 Bad Request", "text/plain", Encoding.UTF8.GetBytes("Bad settings")); return; }
                Directory.CreateDirectory(ar); string mf = Path.Combine(ar, "art.json");
                File.WriteAllText(mf + ".tmp", txt, new UTF8Encoding(false)); if (File.Exists(mf)) File.Delete(mf); File.Move(mf + ".tmp", mf);
                Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}")); return;
            }
            if (path == "/art-remove" && method == "POST") {   // moved to Art\_Removed, never deleted outright
                string f = SafeArtPath(ar, p); if (f == null || !File.Exists(f)) { Reply(s, "404 Not Found", "text/plain", Encoding.UTF8.GetBytes("No such picture")); return; }
                string bin = Path.Combine(ar, "_Removed"); Directory.CreateDirectory(bin);
                string dest = Path.Combine(bin, DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss") + " " + Path.GetFileName(f)); File.Move(f, dest);
                Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}")); return;
            }
            if (path == "/art-open" && method == "POST") { Directory.CreateDirectory(ar); System.Diagnostics.Process.Start("explorer.exe", "\"" + ar + "\""); Reply(s, "200 OK", "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}")); return; }
            Reply(s, "404 Not Found", "text/plain", Encoding.UTF8.GetBytes("Not found"));
        } catch (Exception e) { try { Reply(s, "500 Internal Server Error", "text/plain", Encoding.UTF8.GetBytes(e.Message)); } catch { } }
    }
    void Serve(Stream s, string path) {
        byte[] body; string type = "text/html; charset=utf-8", status = "200 OK";
        if (path == "/" || path == "/index.html" || path == "/vagabond-vtt.html") {
            string f = Path.Combine(root, "vagabond-vtt.html");
            body = File.Exists(f) ? File.ReadAllBytes(f) : Encoding.UTF8.GetBytes("vagabond-vtt.html is missing next to the server.");
        } else if (path == "/vtt-info") {
            type = "application/json";
            body = Encoding.UTF8.GetBytes("{\"vtt\":true,\"steamJoin\":" + (JoinMode ? "true" : "false") + ",\"me\":" + Util.JsonStr(SteamNet.MyName) + "}");
        } else if (path == "/steam-hosts" && JoinMode) {
            type = "application/json"; body = Encoding.UTF8.GetBytes(SteamNet.HostsJson);
        } else { status = "404 Not Found"; type = "text/plain"; body = Encoding.UTF8.GetBytes("Not found"); }
        string hdr = "HTTP/1.1 " + status + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        byte[] hb = Encoding.ASCII.GetBytes(hdr);
        s.Write(hb, 0, hb.Length); s.Write(body, 0, body.Length); s.Flush();
    }
    void WebSocket(TcpClient tcp, NetworkStream ns, Dictionary<string, string> h, Dictionary<string, string> q) {
        string key;
        if (!h.TryGetValue("Sec-WebSocket-Key", out key)) { tcp.Close(); return; }
        string accept;
        using (SHA1 sha = SHA1.Create()) accept = Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        byte[] resp = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
        ns.Write(resp, 0, resp.Length);
        VttClient c = new VttClient(); c.Tcp = tcp; c.S = ns;
        IPEndPoint ep = tcp.Client.RemoteEndPoint as IPEndPoint;
        string from = ep == null ? "?" : ep.Address.ToString();
        if (JoinMode) {
            if (ep == null || !IPAddress.IsLoopback(ep.Address)) { Close(c); return; }
            if (!LocalPage(h)) { Warn("Blocked a connection from another website (" + OriginOf(h) + ")."); Close(c); return; }
            JoinSession(c, q); return;
        }
        string role; q.TryGetValue("role", out role);
        bool isGm = role == "gm";
        if (isGm) {
            if (ep == null || !IPAddress.IsLoopback(ep.Address)) { SendText(c, Util.Err("The GM has to host from the PC that runs the server.")); Close(c); return; }
            if (!LocalPage(h)) { SendText(c, Util.Err("Only the VTT page on this PC can host.")); Close(c); Warn("Blocked a GM connection from another website (" + OriginOf(h) + ")."); return; }
            VttClient old; List<VttClient> ps; List<SteamPeer> sps;
            lock (gate) { old = gm; gm = c; c.Id = "gm"; ps = new List<VttClient>(players.Values); sps = new List<SteamPeer>(steamPeers.Values); }
            if (old != null) { SendText(old, "_\n{\"type\":\"_replaced\"}"); Close(old); }   // the newer GM window wins; the old one stops instead of fighting back
            SendText(c, "_\n" + Info);
            SendText(c, "_\n{\"type\":\"_campaign\",\"data\":" + Util.JsonStr(ReadCampaign()) + "}");   // the page decides: load it, replace it, or ask
            foreach (VttClient p in ps) SendText(p, "{\"type\":\"_gmback\"}");
            foreach (SteamPeer p in sps) SteamNet.SendText(p.Id, "{\"type\":\"_gmback\"}");
            Good("GM is hosting." + (ps.Count + sps.Count > 0 ? " Letting in " + (ps.Count + sps.Count) + " waiting player(s)." : " Players can join now."));
        } else {
            string pc; q.TryGetValue("code", out pc);
            if (pc == null || pc.Trim().ToUpperInvariant() != code) {
                SendText(c, Util.Err("Wrong game code. Check it with your GM.")); Close(c);
                Log("Turned away a connection with the wrong code (" + from + ")."); return;
            }
            VttClient g;
            lock (gate) { nextId++; c.Id = "p" + nextId; players[c.Id] = c; g = gm; }
            Log("Player connected (" + from + ").");
            if (g == null) SendText(c, "{\"type\":\"_gmleft\"}");
        }
        try {
            while (c.Alive) {
                int op; byte[] data = ReadMessage(ns, out op);
                if (data == null || op == 8) break;
                if (op == 9) { SendFrame(c, 10, data); continue; }
                if (op != 1) continue;
                string txt = Encoding.UTF8.GetString(data);
                if (isGm) RouteFromGm(txt);
                else { VttClient g2; lock (gate) { g2 = gm; } if (g2 != null) SendText(g2, c.Id + "\n" + txt); }
            }
        } catch { }
        Close(c);
        if (isGm) {
            bool was; List<VttClient> ps2; List<SteamPeer> sps2;
            lock (gate) { was = gm == c; if (was) gm = null; ps2 = new List<VttClient>(players.Values); sps2 = new List<SteamPeer>(steamPeers.Values); }
            if (was) {
                foreach (VttClient p in ps2) SendText(p, "{\"type\":\"_gmleft\"}");
                foreach (SteamPeer p in sps2) SteamNet.SendText(p.Id, "{\"type\":\"_gmleft\"}");
                Warn("GM stopped hosting (the game tab was closed or reloaded). Players wait until the game page is open and hosting again.");
            }
        } else {
            VttClient g3;
            lock (gate) { players.Remove(c.Id); g3 = gm; }
            if (g3 != null) SendText(g3, c.Id + "\n{\"type\":\"_leave\"}");
            Log("Player left (" + from + ").");
        }
    }
    // The browser says which page opened the socket (Origin). The GM and Steam-helper sockets only take the VTT page itself:
    // served from this PC (http://localhost...) or opened as a file ("null"). Any other website open in the same browser is refused.
    // Deliberately not compared with the Host header, so a site whose name merely points at 127.0.0.1 doesn't get in either.
    static string OriginOf(Dictionary<string, string> h) { string o; return h.TryGetValue("Origin", out o) ? o.Trim() : ""; }
    static bool LocalPage(Dictionary<string, string> h) {
        string o = OriginOf(h);
        if (o.Length == 0 || o == "null") return true;
        Uri u;
        return Uri.TryCreate(o, UriKind.Absolute, out u) && (u.Scheme == "http" || u.Scheme == "https") && u.IsLoopback;
    }
    // The campaign lives in campaign.json next to the server, so the app, a browser tab and the .html file all share one save
    // (each of them has its own separate browser storage). Only the GM socket can read or write it; it is never served over HTTP.
    readonly object fileLock = new object();
    bool savedOnce;
    string ReadCampaign() {
        lock (fileLock) { try { string f = Path.Combine(root, "campaign.json"); return File.Exists(f) ? File.ReadAllText(f, Encoding.UTF8) : null; } catch { return null; } }
    }
    void SaveCampaign(string body) {   // "<header json>\n<campaign json>"
        int i = body.IndexOf('\n'); if (i < 0) return;
        string head = body.Substring(0, i), data = body.Substring(i + 1);
        if (data.Length < 2 || data[0] != '{') return;
        lock (fileLock) {
            try {
                string f = Path.Combine(root, "campaign.json"), bakName = "campaign-backup-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json", bak = Path.Combine(root, bakName);
                UTF8Encoding enc = new UTF8Encoding(false);
                if (head.Contains("\"backupOnly\":true")) { File.WriteAllText(bak, data, enc); Log("Kept the other campaign as " + bakName + "."); return; }
                if (head.Contains("\"backup\":true") && File.Exists(f)) { File.Copy(f, bak, true); Log("Kept the previous campaign as " + bakName + "."); }
                string tmp = f + ".tmp";
                File.WriteAllText(tmp, data, enc);   // write beside it, then swap, so a crash never leaves half a file
                if (File.Exists(f)) File.Replace(tmp, f, null); else File.Move(tmp, f);
                if (!savedOnce) { savedOnce = true; Log("Your campaign is saved in campaign.json in the game folder."); }
            } catch (Exception e) { Warn("Couldn't save the campaign file: " + e.Message); }
        }
    }
    void RouteFromGm(string txt) {
        int i = txt.IndexOf('\n'); if (i < 0) return;
        string to = txt.Substring(0, i), body = txt.Substring(i + 1);
        if (to == "_") {   // a note for the server itself: the campaign to save, or who's playing (shown to Steam friends in their join list)
            if (body.StartsWith("{\"type\":\"_save\"")) { SaveCampaign(body); return; }
            Match rm = Regex.Match(body, "\"players\":\"((?:[^\"\\\\]|\\\\.)*)\"");
            if (rm.Success && SteamOn) {
                string list = Regex.Unescape(rm.Groups[1].Value); if (list.Length > 250) list = list.Substring(0, 247) + "...";
                SteamNet.SetRichPresence("vtt_players", list);
                int n = list.Length == 0 ? 0 : list.Split(',').Length;
                SteamNet.SetRichPresence("status", "Hosting a Vagabond VTT game" + (n > 0 ? " (" + n + " playing)" : ""));
            }
            return;
        }
        List<VttClient> targets = new List<VttClient>(); List<ulong> steamTargets = new List<ulong>();
        lock (gate) {
            if (to == "*") { targets.AddRange(players.Values); foreach (SteamPeer p in steamPeers.Values) steamTargets.Add(p.Id); }
            else if (to.StartsWith("s")) { ulong sid; if (ulong.TryParse(to.Substring(1), out sid) && steamPeers.ContainsKey(sid)) steamTargets.Add(sid); }
            else { VttClient p; if (players.TryGetValue(to, out p)) targets.Add(p); }
        }
        foreach (VttClient p in targets) SendText(p, body);
        foreach (ulong sid in steamTargets) SteamNet.SendText(sid, body);
    }
    static byte[] ReadExact(Stream s, int n) {
        byte[] b = new byte[n]; int o = 0;
        while (o < n) { int r = s.Read(b, o, n - o); if (r <= 0) return null; o += r; }
        return b;
    }
    static byte[] ReadMessage(Stream s, out int opcode) {
        opcode = 0; MemoryStream all = null; int firstOp = 1;
        while (true) {
            byte[] h = ReadExact(s, 2); if (h == null) return null;
            bool fin = (h[0] & 0x80) != 0; int op = h[0] & 0x0F; bool masked = (h[1] & 0x80) != 0; long len = h[1] & 0x7F;
            if (len == 126) { byte[] e = ReadExact(s, 2); if (e == null) return null; len = (e[0] << 8) | e[1]; }
            else if (len == 127) { byte[] e = ReadExact(s, 8); if (e == null) return null; len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | e[i]; }
            if (len < 0 || len > 64L * 1024 * 1024) return null;
            byte[] mask = null; if (masked) { mask = ReadExact(s, 4); if (mask == null) return null; }
            byte[] p = len > 0 ? ReadExact(s, (int)len) : new byte[0]; if (p == null) return null;
            if (masked) for (int i = 0; i < p.Length; i++) p[i] ^= mask[i & 3];
            if (op >= 8) { opcode = op; return p; }
            if (op != 0) firstOp = op;
            if (fin && all == null) { opcode = op; return p; }
            if (all == null) all = new MemoryStream();
            all.Write(p, 0, p.Length);
            if (fin) { opcode = firstOp; return all.ToArray(); }
        }
    }
    void SendFrame(VttClient c, int op, byte[] p) {
        if (!c.Alive) return;
        try {
            lock (c.Lk) {
                byte[] h; int n = p.Length;
                if (n < 126) h = new byte[] { (byte)(0x80 | op), (byte)n };
                else if (n < 65536) h = new byte[] { (byte)(0x80 | op), 126, (byte)(n >> 8), (byte)(n & 0xFF) };
                else { h = new byte[10]; h[0] = (byte)(0x80 | op); h[1] = 127; long L = n; for (int i = 0; i < 8; i++) h[9 - i] = (byte)((L >> (8 * i)) & 0xFF); }
                c.S.Write(h, 0, h.Length); c.S.Write(p, 0, p.Length); c.S.Flush();
            }
        } catch { Close(c); }
    }
    void SendText(VttClient c, string s) { SendFrame(c, 1, Encoding.UTF8.GetBytes(s)); }
    void Close(VttClient c) {
        if (!c.Alive) return;
        c.Alive = false;
        try { lock (c.Lk) { c.S.Write(new byte[] { 0x88, 0 }, 0, 2); } } catch { }
        try { c.Tcp.Close(); } catch { }
    }
}

public static class DllCheck {
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string p, IntPtr h, uint flags);
    [DllImport("kernel32", CharSet = CharSet.Ansi, ExactSpelling = true)] static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("kernel32")] static extern bool FreeLibrary(IntPtr h);
    // true if the DLL has the modern Steam networking + manual-dispatch exports we need
    public static bool HasNetworking(string path) {
        IntPtr h = LoadLibraryEx(path, IntPtr.Zero, 1);   // DONT_RESOLVE_DLL_REFERENCES: does not run the DLL
        if (h == IntPtr.Zero) return false;
        try {
            return GetProcAddress(h, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002") != IntPtr.Zero
                && GetProcAddress(h, "SteamAPI_ManualDispatch_Init") != IntPtr.Zero
                && GetProcAddress(h, "SteamAPI_SteamNetworkingMessage_t_Release") != IntPtr.Zero;
        } finally { FreeLibrary(h); }
    }
    static bool SignedByValve(string path) {
        try { System.Security.Cryptography.X509Certificates.X509Certificate c = System.Security.Cryptography.X509Certificates.X509Certificate.CreateFromSignedFile(path); return c != null && c.Subject.IndexOf("Valve", StringComparison.OrdinalIgnoreCase) >= 0; }
        catch { return false; }
    }
    // Fast, bounded search: one game folder at a time, limited depth, skips folder links, stops at the first usable DLL.
    public static string Find(string[] libraries, int maxDepth, int seconds) {
        DateTime end = DateTime.UtcNow.AddSeconds(seconds);
        foreach (string lib in libraries) {
            string common = Path.Combine(Path.Combine(lib, "steamapps"), "common");
            if (!Directory.Exists(common)) continue;
            string[] games;
            try { games = Directory.GetDirectories(common); } catch { continue; }
            foreach (string g in games) {
                if (DateTime.UtcNow > end) { Console.WriteLine(); return null; }
                string name = Path.GetFileName(g); if (name.Length > 48) name = name.Substring(0, 48);
                Console.Write("\r   checking " + name.PadRight(50));
                string hit = SearchGame(g, maxDepth, end);
                if (hit != null) { Console.WriteLine(); return hit; }
            }
        }
        Console.WriteLine();
        return null;
    }
    static string SearchGame(string dir, int maxDepth, DateTime end) {
        Queue<KeyValuePair<string, int>> q = new Queue<KeyValuePair<string, int>>();
        q.Enqueue(new KeyValuePair<string, int>(dir, 0));
        int visited = 0;
        while (q.Count > 0) {
            if (DateTime.UtcNow > end || ++visited > 3000) return null;
            KeyValuePair<string, int> cur = q.Dequeue();
            try {
                string f = Path.Combine(cur.Key, "steam_api64.dll");
                if (File.Exists(f) && HasNetworking(f) && SignedByValve(f)) return f;
                if (cur.Value >= maxDepth) continue;
                foreach (string sub in Directory.GetDirectories(cur.Key)) {
                    try { if ((File.GetAttributes(sub) & FileAttributes.ReparsePoint) != 0) continue; } catch { continue; }
                    q.Enqueue(new KeyValuePair<string, int>(sub, cur.Value + 1));
                }
            } catch { }
        }
        return null;
    }
}
'@
}

# ---------------- find Valve's steam_api64.dll (copied once from an installed Steam game) ----------------
function Find-SteamApi {
  $local = Join-Path $here 'steam_api64.dll'
  if ((Test-Path $local) -and [DllCheck]::HasNetworking($local)) { return $local }
  $steam = $null
  try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
  if (-not $steam) { return $null }
  $libs = @($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path $vdf) {
    foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches).Matches) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') }
  }
  $libs = @($libs | ForEach-Object { [IO.Path]::GetFullPath(($_ -replace '/', '\')) } | Sort-Object -Unique)
  Write-Host "   Looking for Steam's networking file in your Steam games (one time only, up to 90 seconds)..." -ForegroundColor DarkGray
  $hit = [DllCheck]::Find([string[]]$libs, 7, 90)
  if (-not $hit) { return $null }
  $sig = Get-AuthenticodeSignature $hit
  if ($sig.Status -ne 'Valid') { return $null }
  Copy-Item $hit $local -Force
  Write-Host "   Found it in: $(Split-Path $hit -Parent)" -ForegroundColor DarkGray
  return $local
}
function Start-Steam {
  if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { return 'Steam is not running. Open Steam and log in, then start this again.' }
  $dll = Find-SteamApi
  if (-not $dll) { return "Couldn't find Steam's networking file (steam_api64.dll) in your Steam games. Ask your GM for theirs (it's in their VTT folder) and put it in this folder, next to vtt-server.ps1." }
  if (-not [SteamNet]::Start($dll, $here)) { return [SteamNet]::Error }
  return $null
}

# ================= PLAYER: join a GM through Steam =================
if ($Join) {
  try { Clear-Host } catch {}
  Write-Host ''
  Write-Host '  VAGABOND VTT  -  JOIN VIA STEAM' -ForegroundColor Yellow
  Write-Host ''
  $err = Start-Steam
  if ($err) { Write-Host "  $err" -ForegroundColor Red; exit 1 }
  $server = New-Object VttServer
  $server.JoinMode = $true
  try { $server.Start($Port, $here, '', $true) }
  catch { Write-Host "  Port $Port is busy. Is the helper already open in another window?" -ForegroundColor Red; exit 1 }
  $server.EnableSteamJoin()
  $url = "http://localhost:$Port/"
  Write-Host "  Steam is on. You are $([SteamNet]::MyName)." -ForegroundColor Green
  Write-Host "  (Steam shows you as 'Playing Spacewar' while this window is open.)" -ForegroundColor DarkGray
  Write-Host ''
  Write-Host "  Opening the VTT in your browser: $url"
  Write-Host '  Your GM appears there if they are your Steam friend and are hosting.'
  Write-Host ''
  Write-Host '  Keep this window open while you play. Close it to leave.' -ForegroundColor DarkGray
  Write-Host '  ------------------------------------------------' -ForegroundColor DarkYellow
  Start-Process $url
  try { while (-not (Test-ParentGone)) { Start-Sleep -Seconds 1 } } finally { $server.Stop(); try { Write-Host 'Stopped.' } catch {} }
  exit 0
}

# ================= GM: host =================
$chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
$code = -join (1..6 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })

$server = New-Object VttServer
try { $server.Start($Port, $here, $code, [bool]$LocalOnly) }
catch {
  Write-Host "Could not start on port $Port. Is the server already running in another window?" -ForegroundColor Red
  Write-Host $_.Exception.Message
  exit 1
}

# Steam (no port forwarding needed for Steam players)
$steamInfo = $null; $steamErr = $null
if (-not $NoSteam) {
  $steamErr = Start-Steam
  if (-not $steamErr) {
    $server.EnableSteamHost()
    $friendCode = [string]([decimal][SteamNet]::MyId - [decimal]'76561197960265728')
    $steamInfo = @{ name = [SteamNet]::MyName; friendCode = $friendCode; id = [string][SteamNet]::MyId }
  }
}

# this PC's addresses on the home network
$lan = @()
try {
  $lan = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.AddressState -eq 'Preferred' } |
    Sort-Object InterfaceMetric | Select-Object -ExpandProperty IPAddress)
} catch {
  $lan = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notmatch '^(127\.|169\.254\.)' } | ForEach-Object { $_.ToString() })
}

# ask your own router (UPnP) to open the port for non-Steam internet players
$public = $null; $maps = $null
if (-not $NoUpnp -and -not $LocalOnly -and $lan.Count -gt 0) {
  try {
    $nat = New-Object -ComObject HNetCfg.NATUPnP
    $maps = $nat.StaticPortMappingCollection
    if ($maps) {
      try { $maps.Remove($Port, 'TCP') | Out-Null } catch {}
      $null = $maps.Add($Port, 'TCP', $Port, $lan[0], $true, 'Vagabond VTT')
      foreach ($m in $maps) { if ($m.ExternalPort -eq $Port -and $m.Protocol -eq 'TCP') { $public = $m.ExternalIPAddress } }
    }
  } catch { $maps = $null }
}

$server.Info = (@{ type = '_info'; code = $code; port = $Port; lan = @($lan); public = $public; steam = $steamInfo; steamError = $steamErr } | ConvertTo-Json -Compress -Depth 4)

try { Clear-Host } catch {}
Write-Host ''
Write-Host '  ==============================================' -ForegroundColor DarkYellow
Write-Host '             VAGABOND VTT  -  GAME SERVER' -ForegroundColor Yellow
Write-Host '  ==============================================' -ForegroundColor DarkYellow
Write-Host ''
Write-Host "   GAME CODE:  $code" -ForegroundColor Green
Write-Host ''
Write-Host '   GM (you): open vagabond-vtt.html like normal,'
Write-Host '             click  Multiplayer -> Host.' -ForegroundColor White
Write-Host '             Players can only get in once this window says "GM is hosting".' -ForegroundColor DarkGray
Write-Host '             (After the first time, the page re-hosts by itself whenever it is open.)' -ForegroundColor DarkGray
Write-Host '             Do NOT run "Join via Steam" on this PC - that is only for your players.' -ForegroundColor DarkGray
Write-Host ''
if ($steamInfo) {
  Write-Host '   STEAM IS ON  (no port forwarding needed)' -ForegroundColor Cyan
  Write-Host "      Steam friends double-click 'Join via Steam.bat'."
  Write-Host "      You show up in their list as: $($steamInfo.name)"
  Write-Host "      Or they type your friend code $($steamInfo.friendCode) and the game code."
  Write-Host "      (Steam shows you as 'Playing Spacewar' while this runs.)" -ForegroundColor DarkGray
} elseif (-not $NoSteam) {
  Write-Host "   Steam: off. $steamErr" -ForegroundColor DarkGray
}
Write-Host ''
if ($LocalOnly) {
  Write-Host "   Local-only test mode: http://localhost:$Port" -ForegroundColor Cyan
} else {
  Write-Host '   Players on your Wi-Fi / home network open:' -ForegroundColor Cyan
  foreach ($ip in $lan) { Write-Host "      http://${ip}:$Port" -ForegroundColor White }
  if ($public) {
    Write-Host '   Players over the internet (without Steam) open:' -ForegroundColor Cyan
    Write-Host "      http://${public}:$Port   (your router opened the port automatically)" -ForegroundColor White
  }
  Write-Host ''
  Write-Host '   If Windows asks whether to allow PowerShell on the network,' -ForegroundColor DarkGray
  Write-Host '   click Allow so players on your Wi-Fi can connect.' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '   Keep this window open while you play. Close it (or Ctrl+C) to stop.' -ForegroundColor DarkGray
Write-Host '  ----------------------------------------------' -ForegroundColor DarkYellow

try {
  while (-not (Test-ParentGone)) { Start-Sleep -Seconds 1 }
} finally {
  $server.Stop()
  if ($maps) { try { $maps.Remove($Port, 'TCP') | Out-Null } catch {} }
  Write-Host 'Server stopped.'
}
