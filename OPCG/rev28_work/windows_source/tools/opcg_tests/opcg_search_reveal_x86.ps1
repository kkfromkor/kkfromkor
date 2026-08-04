param([Parameter(Mandatory = $true)][string]$Repo)

# OP07-111 Lilith (ruling 2026-07-27): a deck search that CONSTRAINS what it
# fetches (trait filter etc.) is a PUBLIC search even without reveal text -
# the opponent must be able to verify the pick. Lilith's IR carries
# reveal=false (compiled from the plain text), which used to suppress the
# reveal. The executor now forces the reveal for filtered picks.
# This resolves Lilith's ON_PLAY (look 5, add 1 Egghead) with Atlas seeded
# on top of the deck and asserts a MSG_CONFIRM_CARDS (31) addressed to the
# OPPONENT (player=1) carrying the picked card. Run with 32-bit PowerShell.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class SearchReveal {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReader(IntPtr payload, uint code, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReaderDone(IntPtr payload, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int ScriptReader(IntPtr payload, IntPtr duel, IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void LogHandler(IntPtr payload, IntPtr message, int type);

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

    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_CreateDuel(out IntPtr duel, ref Options options);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DestroyDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelNewCard(IntPtr duel, ref NewCard info);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_StartDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_DuelProcess(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr OCG_DuelGetMessage(IntPtr duel, out uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelSetResponse(IntPtr duel, byte[] buffer, uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_LoadScript(IntPtr duel, byte[] buffer, uint length, [MarshalAs(UnmanagedType.LPStr)] string name);

    const uint LILITH = 880000966; // OP07-111
    const uint ATLAS  = 880000953; // Egghead character, the expected pick
    const uint FILLER = 880000881;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();
    static int oppConfirms = 0; static bool oppSawAtlas = false; static bool atlasToHand = false;

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    public static void LoadDb(string csv) {
        foreach (string line in File.ReadAllLines(csv)) {
            string[] f = line.Split(',');
            if (f.Length < 9) continue;
            ulong[] v = new ulong[9];
            for (int i = 0; i < 9; ++i) v[i] = unchecked((ulong)long.Parse(f[i]));
            cardDb[(uint)v[0]] = v;
        }
    }
    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            CardData data = new CardData(); data.code = code;
            ulong[] v;
            if (cardDb.TryGetValue(code, out v)) {
                data.type = (uint)v[1]; data.race = v[2]; data.level = (uint)v[3];
                data.attribute = (uint)v[4]; data.category = (uint)v[5];
                data.attack = (int)(long)v[7]; data.defense = (int)(long)v[8];
                ulong sc = v[6];
                if (sc != 0) {
                    IntPtr buf = Marshal.AllocHGlobal(10); int off = 0;
                    for (int s = 0; s < 4; ++s) { ushort part = (ushort)((sc >> (16 * s)) & 0xffff); if (part == 0) continue; Marshal.WriteInt16(buf, off, (short)part); off += 2; }
                    Marshal.WriteInt16(buf, off, 0); data.setcodes = buf;
                }
            } else { data.type = 1; data.race = 2; }
            Marshal.StructureToPtr(data, output, false);
        } catch (Exception e) { callbackErrors.Add("card reader: " + e); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        string text = Marshal.PtrToStringAnsi(message); if (text == null) text = "";
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
    class Reader {
        public byte[] buf; public int pos;
        public Reader(byte[] b, int p) { buf = b; pos = p; }
        public byte U8() { byte v = buf[pos]; pos += 1; return v; }
        public uint U32() { uint v = BitConverter.ToUInt32(buf, pos); pos += 4; return v; }
    }
    static void RespondI32(IntPtr duel, int v) { OCG_DuelSetResponse(duel, BitConverter.GetBytes(v), 4); }

    const string testScript = @"
local ge = Effect.GlobalEffect()
ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
ge:SetCode(EVENT_PHASE_START + PHASE_MAIN1)
ge:SetOperation(function()
    if Duel.GetTurnCount() ~= 2 or opcg._sr_done then return end
    opcg._sr_done = true
    local atlas = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000953 end,0,LOCATION_DECK,0,nil):GetFirst()
    if atlas then Duel.MoveSequence(atlas, 0) end
    Debug.Message('atlas_on_top=' .. tostring(atlas ~= nil))
    local lilith = Duel.GetFieldGroup(0,LOCATION_MZONE,0):Filter(function(c) return c:GetOriginalCode()==880000966 end,nil):GetFirst()
    Debug.Message('lilith_found=' .. tostring(lilith ~= nil))
    if not lilith then return end
    local done = OPCGCore.DispatchTiming(lilith, 'ON_PLAY', nil)
    Debug.Message('dispatched=' .. tostring(#(done or {})))
    Debug.Message('sr_probe_done')
end)
Duel.RegisterEffect(ge, 0)
";

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");

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
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var script = Encoding.UTF8.GetBytes(testScript);
            if (OCG_LoadScript(duel, script, (uint)script.Length, "probe.lua") != 1)
                callbackErrors.Add("test script failed to load");

            NewCard lil = new NewCard(); lil.team = 0; lil.duelist = 0; lil.code = LILITH; lil.con = 0; lil.loc = 0x4; lil.seq = 0; lil.pos = 0x1;
            OCG_DuelNewCard(duel, ref lil);
            Action<int, uint, int> add = delegate (int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) { NewCard c = new NewCard(); c.team = (byte)p; c.duelist = 0; c.code = code; c.con = (byte)p; c.loc = 1; c.seq = 0; c.pos = 8; OCG_DuelNewCard(duel, ref c); }
            };
            add(0, ATLAS, 1); add(0, FILLER, 40);
            add(1, FILLER, 40);
            OCG_StartDuel(duel);

            uint lastId = 0; byte[] lastMsg = null; int newTurns = 0; bool done = false;
            for (int step = 0; step < 20000 && !done; ++step) {
                int status = OCG_DuelProcess(duel);
                uint length; IntPtr ptr = OCG_DuelGetMessage(duel, out length);
                byte[] all = new byte[length]; if (length > 0) Marshal.Copy(ptr, all, 0, (int)length);
                int off = 0;
                while (off + 4 <= all.Length) {
                    uint pl2 = BitConverter.ToUInt32(all, off); off += 4;
                    if (pl2 == 0 || off + pl2 > all.Length) break;
                    byte id = all[off];
                    byte[] payload = new byte[pl2]; Array.Copy(all, off, payload, 0, (int)pl2); off += (int)pl2;
                    lastId = id; lastMsg = payload;
                    if (id == 40) newTurns++;
                    else if (id == 31 && newTurns == 2) { // MSG_CONFIRM_CARDS: player u8, count u32, entries
                        Reader r = new Reader(payload, 1);
                        byte who = r.U8(); uint n = r.U32();
                        bool hasAtlas = false;
                        for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); if (code == ATLAS) hasAtlas = true; }
                        Console.WriteLine("CONFIRM to P" + who + " n=" + n + " atlas=" + hasAtlas);
                        if (who == 1) { oppConfirms++; if (hasAtlas) oppSawAtlas = true; }
                    }
                    else if (id == 50) {
                        Reader r = new Reader(payload, 1); uint code = r.U32();
                        r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if (code == ATLAS && cloc == 0x2) atlasToHand = true;
                    }
                }
                if (probes.Contains("sr_probe_done")) done = true;
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL no msg"); break; }

                if (lastId == 12) { RespondI32(duel, 1); }
                else if (lastId == 13) { RespondI32(duel, 0); }
                else if (lastId == 14) { RespondI32(duel, 0); }
                else if (lastId == 16) { RespondI32(duel, -1); }
                else if (lastId == 11) { RespondI32(duel, 7); }
                else if (lastId == 10) {
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.pos += 8; r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    r.U8(); byte toEp = r.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                } else if (lastId == 15) { // pick ATLAS when offered, else first min
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); uint smin = r.U32(); r.U32();
                    uint n = r.U32(); int atlasIdx = -1; int save = r.pos;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); if (code == ATLAS) atlasIdx = (int)i; }
                    r.pos = save;
                    uint take = atlasIdx >= 0 ? 1U : (smin > 0 ? smin : 0U);
                    if (take == 0) { OCG_DuelSetResponse(duel, new byte[8], 8); continue; }
                    var resp = new List<byte>();
                    resp.AddRange(BitConverter.GetBytes((int)0));
                    resp.AddRange(BitConverter.GetBytes(take));
                    if (atlasIdx >= 0) { Console.WriteLine("select -> ATLAS"); resp.AddRange(BitConverter.GetBytes((uint)atlasIdx)); }
                    else for (uint i = 0; i < take; ++i) resp.AddRange(BitConverter.GetBytes(i));
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                } else if (lastId == 23 || lastId == 25 || lastId == 26) { RespondI32(duel, -1); }
                else if (lastId == 19) { RespondI32(duel, 0x1); }
                else if (lastId == 18 || lastId == 24) {
                    Reader r = new Reader(lastMsg, 1); byte player = r.U8(); byte need = r.U8(); uint flag = r.U32();
                    uint avail = ~flag; var resp = new List<byte>(); int given = 0;
                    for (int bit = 0; bit < 32 && given < Math.Max((int)need, 1); ++bit) {
                        if ((avail & (1u << bit)) == 0) continue;
                        byte con = (byte)((bit >= 16) ? (1 - player) : player);
                        int local = bit & 0xf; byte loc = (byte)((local >= 8) ? 8 : 4); byte seq = (byte)((local >= 8) ? (local - 8) : local);
                        resp.Add(con); resp.Add(loc); resp.Add(seq); given++;
                    }
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                } else { Console.WriteLine("FAIL unexpected id=" + lastId); break; }
                if (newTurns >= 3) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var p in probes) Console.WriteLine("PROBE: " + p);
        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        Console.WriteLine("opp_confirms=" + oppConfirms + " opp_saw_pick=" + oppSawAtlas + " to_hand=" + atlasToHand);
        bool pass = oppSawAtlas && atlasToHand && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "SEARCH_REVEAL PASS" : "SEARCH_REVEAL FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[SearchReveal]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [SearchReveal]::Run((Resolve-Path -LiteralPath $Repo).Path)
