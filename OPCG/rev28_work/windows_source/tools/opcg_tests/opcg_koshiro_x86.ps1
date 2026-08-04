param([Parameter(Mandatory = $true)][string]$Repo)

# OP12-027 Koshiro (880001480): when ANOTHER of your SLASH characters
# (cost <= 5) would be K.O.'d by an opponent effect, you may instead REST
# Koshiro. Regression: the replacement must rest KOSHIRO (the effect source),
# not the victim, and must apply even when the victim is already rested.
# Run with 32-bit PowerShell (the release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgKoshiroHeadless {
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
                ulong sc = v[6];
                if (sc != 0) {
                    IntPtr buf = Marshal.AllocHGlobal(10); int off = 0;
                    for (int s = 0; s < 4; ++s) {
                        ushort part = (ushort)((sc >> (16 * s)) & 0xffff);
                        if (part == 0) continue;
                        Marshal.WriteInt16(buf, off, (short)part); off += 2;
                    }
                    Marshal.WriteInt16(buf, off, 0); data.setcodes = buf;
                }
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
        if (name.StartsWith("c999")) {
            var stub = Encoding.UTF8.GetBytes("local s,id=GetID()\nfunction s.initial_effect(c)\nend\n");
            return OCG_LoadScript(duel, stub, (uint)stub.Length, name);
        }
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

    static void Drain(IntPtr duel) {
        uint len; var buf = OCG_DuelGetMessage(duel, out len);
        if (buf == IntPtr.Zero || len == 0) return;
        var bytes = new byte[len]; Marshal.Copy(buf, bytes, 0, (int)len);
        int off = 0;
        while (off + 4 <= bytes.Length) {
            uint pl = BitConverter.ToUInt32(bytes, off); off += 4;
            if (pl == 0 || off + pl > bytes.Length) break;
            off += (int)pl;
        }
    }

    // KO the victim through the OPCG contract path (opponent effect), exactly
    // like a real card would, then read back who ended up rested.
    const string testScript = @"
local ge = Effect.GlobalEffect()
ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
ge:SetCode(EVENT_STARTUP)
ge:SetOperation(function()
    local function probe(t) Debug.Message(t) end
    local function ensure(ok, label) assert(ok, 'KOSHIRO ' .. label) end
    probe('startup_fired')
    local field = Duel.GetFieldGroup(0, LOCATION_MZONE, 0)
    probe('mzone_count=' .. tostring(field:GetCount()))
    local koshiro = field:Filter(function(c) return c:GetCode() == 880001480 end, nil):GetFirst()
    local victim  = field:Filter(function(c) return c:GetCode() == 880000004 end, nil):GetFirst()
    probe('found koshiro=' .. tostring(koshiro ~= nil) .. ' victim=' .. tostring(victim ~= nil))
    ensure(koshiro and victim, 'both cards on field')
    if Duel.Adjust then Duel.Adjust() end
    probe('koshiro_active_before=' .. tostring(opcg.IsActive(koshiro)))
    probe('koshiro_has_native_replace=' .. tostring(koshiro:IsHasEffect(EFFECT_DESTROY_REPLACE) and true or false))
    -- an opponent-effect K.O. through the REAL path: a native destroy,
    -- intercepted by Koshiro's EFFECT_DESTROY_REPLACE
    local destroyed = Duel.Destroy(victim, REASON_EFFECT, LOCATION_GRAVE, 1)
    probe('destroy_returned=' .. tostring(destroyed))
    probe('victim_saved=' .. tostring(victim:IsLocation(LOCATION_MZONE)))
    probe('koshiro_rested_after=' .. tostring(opcg.IsRested(koshiro)))
    probe('victim_rested_after=' .. tostring(opcg.IsRested(victim)))
    probe('victim_on_field=' .. tostring(victim:IsLocation(LOCATION_MZONE)))
end)
Duel.RegisterEffect(ge, 0)
";

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        LoadDb(Path.Combine(repo, "tools", "opcg_tests", "cdb_dump.csv"));

        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4, flags = 0x2000000000UL,
            team1 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader,
            logHandler = logHandler, cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed"); return 2;
        }
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var script = Encoding.UTF8.GetBytes(testScript);
            if (OCG_LoadScript(duel, script, (uint)script.Length, "opcg_koshiro_test.lua") != 1)
                callbackErrors.Add("test script failed to load");
            // koshiro + victim start ON the field (MZONE, face-up active) so the
            // test never depends on a yielding MoveToField mid-startup
            var onField = new NewCard { team = 0, duelist = 0, code = 880001480, con = 0, loc = 0x4, seq = 0, pos = 0x1 };
            OCG_DuelNewCard(duel, ref onField);
            var vic = new NewCard { team = 0, duelist = 0, code = 880000004, con = 0, loc = 0x4, seq = 1, pos = 0x1 };
            OCG_DuelNewCard(duel, ref vic);
            var deck = new uint[] { 999000001, 999000002, 999000003, 999000004, 999000005, 999000006 };
            for (uint seq = 0; seq < deck.Length; ++seq) {
                var card = new NewCard { team = 0, duelist = 0, code = deck[seq], con = 0, loc = 1, seq = seq, pos = 8 };
                OCG_DuelNewCard(duel, ref card);
            }
            OCG_StartDuel(duel);
            int st = 2; int step = 0;
            for (; step < 1200 && st != 0; ++step) {
                st = OCG_DuelProcess(duel); Drain(duel);
                // answer YES to every yes/no: the only prompt in this isolated
                // test is Koshiro's optional replacement (its whole point)
                if (st == 1) OCG_DuelSetResponse(duel, BitConverter.GetBytes(1), 4);
                if (probes.Contains("victim_on_field=true") || probes.Contains("victim_on_field=false")) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var p in probes) Console.WriteLine("PROBE: " + p);
        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        bool saved = probes.Contains("victim_saved=true");
        bool koshiroRested = probes.Contains("koshiro_rested_after=true");
        bool victimNotRested = probes.Contains("victim_rested_after=false");
        bool pass = errors.Count == 0 && callbackErrors.Count == 0 && saved && koshiroRested && victimNotRested;
        Console.WriteLine(pass ? "KOSHIRO PASS" : "KOSHIRO FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgKoshiroHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
