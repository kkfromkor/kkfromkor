param([Parameter(Mandatory = $true)][string]$Repo)

# OP13-003 Gol D. Roger (880001575): "1 DON *being placed* in your DON phase
# is attached to your leader instead." Regression: with the DON deck dry
# (10/10 given), the DON phase places nothing, so the redirect must NOT fire —
# it used to yank an existing cost-area DON onto the leader every turn.
# P0 = Roger, passes every turn. Expected attach series on P0's turns:
#   t1=0 (no field DON yet), t3=1, t5=2, t7=3, t9=4, t11=5 (deck dry now),
#   t13=5 (UNCHANGED — the fix), field stays 10 from t11 on.
# Run with 32-bit PowerShell (the release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class RogerDonCapHeadless {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void DataReader(IntPtr payload, uint code, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void DataReaderDone(IntPtr payload, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int ScriptReader(IntPtr payload, IntPtr duel, IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void LogHandler(IntPtr payload, IntPtr message, int type);

    [StructLayout(LayoutKind.Sequential)]
    public struct Player { public uint startingLP, startingDrawCount, drawCountPerTurn; }
    [StructLayout(LayoutKind.Sequential)]
    public struct Options {
        public ulong seed0, seed1, seed2, seed3, flags;
        public Player team1, team2;
        public DataReader cardReader; public IntPtr payload1;
        public ScriptReader scriptReader; public IntPtr payload2;
        public LogHandler logHandler; public IntPtr payload3;
        public DataReaderDone cardReaderDone; public IntPtr payload4;
        public byte enableUnsafeLibraries;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct NewCard { public byte team, duelist; public uint code; public byte con; public uint loc, seq, pos; }
    [StructLayout(LayoutKind.Sequential)]
    public struct CardData {
        public uint code, alias; public IntPtr setcodes;
        public uint type, level, attribute; public ulong race;
        public int attack, defense; public uint lscale, rscale, link_marker, category;
    }

    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int OCG_CreateDuel(out IntPtr duel, ref Options options);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_DestroyDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_DuelNewCard(IntPtr duel, ref NewCard info);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_StartDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int OCG_DuelProcess(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr OCG_DuelGetMessage(IntPtr duel, out uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_DuelSetResponse(IntPtr duel, byte[] buffer, uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int OCG_LoadScript(IntPtr duel, byte[] buffer, uint length, [MarshalAs(UnmanagedType.LPStr)] string name);

    const uint ROGER = 880001575;
    const uint LEADER2 = 880000634;
    const uint FILLER = 880000881;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static void LoadDb(string csv) {
        foreach (var line in File.ReadAllLines(csv)) {
            var f = line.Split(',');
            if (f.Length < 9) continue;
            var v = new ulong[9];
            for (int i = 0; i < 9; ++i) v[i] = unchecked((ulong)long.Parse(f[i]));
            cardDb[(uint)v[0]] = v;
        }
    }
    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            var data = new CardData { code = code };
            ulong[] v;
            if (cardDb.TryGetValue(code, out v)) {
                data.type = (uint)v[1]; data.race = v[2]; data.level = (uint)v[3];
                data.attribute = (uint)v[4]; data.category = (uint)v[5];
                data.attack = (int)(long)v[7]; data.defense = (int)(long)v[8];
            } else { data.type = 1; data.race = 2; }
            Marshal.StructureToPtr(data, output, false);
        } catch (Exception e) { callbackErrors.Add("card reader: " + e); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        var text = Marshal.PtrToStringAnsi(message) ?? "";
        if (type == 0) errors.Add(text); else probes.Add(text);
    }
    static int Load(IntPtr duel, string name) {
        foreach (var dir in new[] { expansionScripts, standardScripts, Path.Combine(standardScripts, "unofficial") }) {
            var path = Path.Combine(dir, name);
            if (File.Exists(path)) { var b = File.ReadAllBytes(path); return OCG_LoadScript(duel, b, (uint)b.Length, name); }
        }
        if (name != "c0.lua") callbackErrors.Add("missing script: " + name);
        return 0;
    }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name) {
        try { return Load(duel, Marshal.PtrToStringAnsi(name)); }
        catch (Exception e) { callbackErrors.Add("script reader: " + e); return 0; }
    }

    const string probeLua = @"
local probe = Effect.GlobalEffect()
probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)
probe:SetOperation(function()
    Debug.Message('DONPROBE t=' .. Duel.GetTurnCount() ..
        ' p=' .. Duel.GetTurnPlayer() ..
        ' attach=' .. tostring(opcg.AttachedDonCount(0)) ..
        ' field=' .. tostring(opcg.FieldDon(0)))
end)
Duel.RegisterEffect(probe, 0)
";

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        LoadDb(Path.Combine(repo, "tools", "opcg_tests", "cdb_dump.csv"));

        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4, flags = 0x2000000000UL,
            team1 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader,
            logHandler = logHandler, cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed"); return 2;
        }
        int newTurns = 0;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var pb = Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "roger_probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");
            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, ROGER, 1);
            addCards(0, FILLER, 30);
            addCards(1, LEADER2, 1);
            addCards(1, FILLER, 30);
            OCG_StartDuel(duel);

            uint lastMsgId = 0;
            byte[] lastMsg = null;
            int st = 2;
            for (int step = 0; step < 60000 && st != 0; ++step) {
                st = OCG_DuelProcess(duel);
                uint length;
                IntPtr ptr = OCG_DuelGetMessage(duel, out length);
                var all = new byte[length];
                if (length > 0) Marshal.Copy(ptr, all, 0, (int)length);
                int off = 0;
                while (off + 4 <= all.Length) {
                    uint pl = BitConverter.ToUInt32(all, off); off += 4;
                    if (pl == 0 || off + pl > all.Length) break;
                    byte id = all[off];
                    lastMsgId = id;
                    lastMsg = new byte[pl];
                    Array.Copy(all, off, lastMsg, 0, (int)pl);
                    off += (int)pl;
                    if (id == 40) newTurns++;
                }
                if (st == 0) break;
                if (st != 1) continue;
                if (lastMsg == null) break;
                if (lastMsgId == 13 || lastMsgId == 12) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                else if (lastMsgId == 15) {
                    var resp = new byte[8];
                    OCG_DuelSetResponse(duel, resp, 8);
                }
                else if (lastMsgId == 19) OCG_DuelSetResponse(duel, BitConverter.GetBytes(1), 4);
                else if (lastMsgId == 18 || lastMsgId == 24) {
                    byte player = lastMsg[1];
                    uint flag = BitConverter.ToUInt32(lastMsg, 3);
                    uint available = ~flag;
                    byte[] resp = null;
                    for (int bit = 0; bit < 16 && resp == null; ++bit) {
                        if ((available & (1u << bit)) == 0) continue;
                        byte loc = (byte)((bit >= 8) ? 8 : 4);
                        byte seq = (byte)((bit >= 8) ? (bit - 8) : bit);
                        resp = new byte[] { player, loc, seq };
                    }
                    if (resp == null) { Console.WriteLine("select_place: no free zone"); break; }
                    OCG_DuelSetResponse(duel, resp, (uint)resp.Length);
                }
                else { Console.WriteLine("unexpected awaited msg id=" + lastMsgId); break; }
                if (newTurns >= 14) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        var attach = new Dictionary<int, string>();
        var field = new Dictionary<int, string>();
        foreach (var p in probes) {
            if (!p.Contains("DONPROBE")) continue;
            Console.WriteLine("PROBE: " + p);
            var parts = p.Split(' ');
            int t = 0; string a = null, f = null;
            foreach (var part in parts) {
                if (part.StartsWith("t=")) t = int.Parse(part.Substring(2));
                if (part.StartsWith("attach=")) a = part.Substring(7);
                if (part.StartsWith("field=")) f = part.Substring(6);
            }
            if (t > 0) { attach[t] = a; field[t] = f; }
        }
        // refresh phase returns every attached DON to the cost area (official
        // rule), so each of Roger's turns redirects exactly 1 freshly placed
        // DON: attach==1 on t3..t11. t13 places nothing (deck dry) => attach
        // must be 0 (the old bug re-attached a cost-area DON => 1).
        Func<int, string, bool> expect = (t, v) => attach.ContainsKey(t) && attach[t] == v;
        bool series = expect(1, "0") && expect(3, "1") && expect(5, "1")
            && expect(7, "1") && expect(9, "1") && expect(11, "1");
        bool capHolds = expect(13, "0");
        bool fieldCap = field.ContainsKey(11) && field.ContainsKey(13)
            && field[11] == "10" && field[13] == "10";
        Console.WriteLine("series_ok=" + series + " cap_holds=" + capHolds + " field_cap=" + fieldCap);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0 && series && capHolds && fieldCap;
        Console.WriteLine(pass ? "ROGER_DON_CAP PASS" : "ROGER_DON_CAP FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [RogerDonCapHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
