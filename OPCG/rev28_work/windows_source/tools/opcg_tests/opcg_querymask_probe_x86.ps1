param([Parameter(Mandatory = $true)][string]$Repo)

# Probe the EXACT ocgcore.dll for what OCG_DuelQueryLocation returns on an
# OPCG MZONE with two masks: the sparse power-service mask (QUERY_POSITION |
# QUERY_ATTACK = 0x102, what Multirole CoreUtils.cpp currently sends after
# every message) vs the upstream full refresh mask (0x3981FFF). Then run a
# faithful C# port of Multirole's DeserializeLocationQueryBuffer /
# DeserializeOneQuery (whose inner loop has NO ptr bounds check and stops
# only on QUERY_END) against each, and report whether it walks out of bounds.
# This reproduces the server's memcpy access-violation headlessly.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class QueryMaskProbe {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReader(IntPtr p, uint code, IntPtr d);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReaderDone(IntPtr p, IntPtr d);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int ScriptReader(IntPtr p, IntPtr duel, IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void LogHandler(IntPtr p, IntPtr msg, int t);

    [StructLayout(LayoutKind.Sequential)] public struct Player { public uint startingLP, startingDrawCount, drawCountPerTurn; }
    [StructLayout(LayoutKind.Sequential)] public struct Options {
        public ulong seed0, seed1, seed2, seed3, flags;
        public Player team1, team2;
        public DataReader cardReader; public IntPtr payload1;
        public ScriptReader scriptReader; public IntPtr payload2;
        public LogHandler logHandler; public IntPtr payload3;
        public DataReaderDone cardReaderDone; public IntPtr payload4;
        public byte enableUnsafeLibraries;
    }
    [StructLayout(LayoutKind.Sequential)] public struct NewCard { public byte team, duelist; public uint code; public byte con; public uint loc, seq, pos; }
    [StructLayout(LayoutKind.Sequential)] public struct CardData {
        public uint code, alias; public IntPtr setcodes;
        public uint type, level, attribute; public ulong race;
        public int attack, defense; public uint lscale, rscale, link_marker, category;
    }
    // OCG_QueryInfo: flags u32, con u8, loc u32, seq u32, overlay_seq u32
    [StructLayout(LayoutKind.Sequential)] public struct QueryInfo { public uint flags; public byte con; public uint loc, seq, overlay_seq; }

    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_CreateDuel(out IntPtr duel, ref Options o);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DestroyDuel(IntPtr d);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelNewCard(IntPtr d, ref NewCard c);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_StartDuel(IntPtr d);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_DuelProcess(IntPtr d);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr OCG_DuelGetMessage(IntPtr d, out uint len);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_LoadScript(IntPtr d, byte[] b, uint len, [MarshalAs(UnmanagedType.LPStr)] string name);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr OCG_DuelQueryLocation(IntPtr d, out uint len, ref QueryInfo info);

    const uint LEADER = 880000634;
    const uint LOCATION_MZONE = 0x4;
    const uint QUERY_POSITION = 0x2, QUERY_ATTACK = 0x100, QUERY_END = 0x80000000;
    const ulong OPT = 0x6000000000UL | 0x10UL; // high 0x60 (OPCG_MODE|SCRIPTED_RPS) + PSEUDO_SHUFFLE, matches Multirole

    static string std_, exp_;
    static readonly List<string> cbErr = new List<string>();
    static readonly Dictionary<uint, ulong[]> db = new Dictionary<uint, ulong[]>();
    static readonly DataReader cr = ReadCard; static readonly DataReaderDone crd = (p, d) => {};
    static readonly ScriptReader sr = ReadScript; static readonly LogHandler lh = (p, m, t) => {};

    public static void LoadDb(string csv) {
        foreach (var line in File.ReadAllLines(csv)) {
            var f = line.Split(','); if (f.Length < 9) continue;
            var v = new ulong[9]; for (int i = 0; i < 9; ++i) v[i] = unchecked((ulong)long.Parse(f[i]));
            db[(uint)v[0]] = v;
        }
    }
    static void ReadCard(IntPtr p, uint code, IntPtr o) {
        try { var d = new CardData { code = code }; ulong[] v;
            if (db.TryGetValue(code, out v)) { d.type=(uint)v[1]; d.race=v[2]; d.level=(uint)v[3]; d.attribute=(uint)v[4]; d.category=(uint)v[5]; d.attack=(int)(long)v[7]; d.defense=(int)(long)v[8]; }
            else { d.type = 1; d.race = 2; }
            Marshal.StructureToPtr(d, o, false);
        } catch (Exception e) { cbErr.Add("card: " + e); }
    }
    static int Load(IntPtr duel, string name) {
        foreach (var dir in new[] { exp_, std_, Path.Combine(std_, "unofficial") }) {
            var path = Path.Combine(dir, name);
            if (File.Exists(path)) { var b = File.ReadAllBytes(path); return OCG_LoadScript(duel, b, (uint)b.Length, name); }
        }
        if (name != "c0.lua") cbErr.Add("missing script: " + name);
        return 0;
    }
    static int ReadScript(IntPtr p, IntPtr duel, IntPtr name) {
        try { return Load(duel, Marshal.PtrToStringAnsi(name)); } catch (Exception e) { cbErr.Add("script: " + e); return 0; }
    }

    // Faithful port of Multirole DeserializeLocationQueryBuffer + DeserializeOneQuery.
    // The inner loop mirrors the C++ EXACTLY: no bounds check, stops only on
    // QUERY_END. In C# an over-read throws IndexOutOfRange, which is precisely
    // the server's out-of-bounds access rendered safe/observable.
    static uint RU16(byte[] b, ref int p) { uint v = (uint)(b[p] | (b[p+1] << 8)); p += 2; return v; }
    static uint RU32(byte[] b, ref int p) { uint v = (uint)(b[p] | (b[p+1]<<8) | (b[p+2]<<16) | (b[p+3]<<24)); p += 4; return v; }

    static int maxReached;
    static bool DeserializeOne(byte[] b, ref int p) {
        if (RU16(b, ref p) == 0) return true; // empty slot terminator
        p -= 2;
        while (true) {
            uint size = RU16(b, ref p);
            uint flag = RU32(b, ref p);
            if (flag == QUERY_END) return true;
            switch (flag) {
                case 0x8: case 0x10: case 0x20: // level/rank etc (u32)
                default:
                    // generic: skip the declared field size (minus the 4-byte flag)
                    p += (int)size - 4;
                    break;
            }
            if (p > maxReached) maxReached = p;
            if (p > b.Length) throw new IndexOutOfRangeException("walked past buffer end at " + p + "/" + b.Length);
        }
    }
    static string Deserialize(byte[] b) {
        try {
            int p = 0;
            if (b.Length < 4) return "SHORT_BUFFER(" + b.Length + "B) -> Read<u32> OOB";
            uint total = RU32(b, ref p);
            long ptrMax = (long)total; // matches ptr_original + total (best case)
            int cards = 0;
            while (p < ptrMax && p < b.Length) { DeserializeOne(b, ref p); cards++; if (cards > 100) break; }
            return "OK cards=" + cards + " total_hdr=" + total + " buf=" + b.Length + " maxRead=" + maxReached;
        } catch (Exception e) { return "CRASH: " + e.Message; }
    }

    static byte[] Query(IntPtr duel, byte con, uint flags) {
        var info = new QueryInfo { flags = flags, con = con, loc = LOCATION_MZONE, seq = 0, overlay_seq = 0 };
        uint len; var ptr = OCG_DuelQueryLocation(duel, out len, ref info);
        var buf = new byte[len]; if (len > 0) Marshal.Copy(ptr, buf, 0, (int)len);
        return buf;
    }
    static string Hex(byte[] b, int n) {
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < Math.Min(n, b.Length); ++i) sb.Append(b[i].ToString("x2") + " ");
        return sb.ToString();
    }

    public static int Run(string repo) {
        var rel = Path.Combine(repo, "bin", "release"); Directory.SetCurrentDirectory(rel);
        std_ = Path.Combine(rel, "script"); exp_ = Path.Combine(rel, "expansions", "script");
        var opt = new Options { seed0=1, seed1=2, seed2=3, seed3=4, flags=OPT,
            team1=new Player{startingLP=5,startingDrawCount=5,drawCountPerTurn=1},
            team2=new Player{startingLP=5,startingDrawCount=5,drawCountPerTurn=1},
            cardReader=cr, scriptReader=sr, logHandler=lh, cardReaderDone=crd, enableUnsafeLibraries=1 };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref opt) != 0 || duel == IntPtr.Zero) { Console.WriteLine("FAIL create"); return 2; }
        foreach (var n in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" }) if (Load(duel, n) != 1) cbErr.Add("init: " + n);
        Action<int,uint,int> add = (p, code, cp) => { for (int k=0;k<cp;++k){ var c=new NewCard{team=(byte)p,duelist=0,code=code,con=(byte)p,loc=1,seq=0,pos=8}; OCG_DuelNewCard(duel, ref c);} };
        add(0, LEADER, 1); add(0, 880000881, 45); add(1, LEADER, 1); add(1, 880000881, 45);
        OCG_StartDuel(duel);
        // pump a few steps so the field/leaders settle
        for (int i = 0; i < 40; ++i) { int st = OCG_DuelProcess(duel); uint l; OCG_DuelGetMessage(duel, out l); if (st == 1) break; if (st == 0) break; }

        Console.WriteLine("--- empty/leader MZONE query, player 0 ---");
        maxReached = 0;
        var sparse = Query(duel, 0, QUERY_POSITION | QUERY_ATTACK);
        Console.WriteLine("SPARSE(0x102) len=" + sparse.Length + " head=[" + Hex(sparse, 24) + "]");
        Console.WriteLine("  parse: " + Deserialize(sparse));
        maxReached = 0;
        var full = Query(duel, 0, 0x3981FFF);
        Console.WriteLine("FULL(0x3981FFF) len=" + full.Length + " head=[" + Hex(full, 24) + "]");
        Console.WriteLine("  parse: " + Deserialize(full));

        OCG_DestroyDuel(duel);
        Console.WriteLine("cb_errors=" + cbErr.Count);
        foreach (var e in cbErr) Console.WriteLine("CB: " + e);
        bool sparseCrash = Deserialize(sparse).StartsWith("CRASH") || Deserialize(sparse).StartsWith("SHORT");
        bool fullOk = Deserialize(full).StartsWith("OK");
        Console.WriteLine(sparseCrash ? "VERDICT: SPARSE mask is the crash source" : "VERDICT: sparse mask parses clean");
        Console.WriteLine(fullOk ? "VERDICT: FULL mask is safe" : "VERDICT: full mask also problematic");
        return 0;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[QueryMaskProbe]::LoadDb((Join-Path (Resolve-Path -LiteralPath $Repo).Path 'tools\opcg_tests\cdb_dump.csv'))
exit [QueryMaskProbe]::Run((Resolve-Path -LiteralPath $Repo).Path)
