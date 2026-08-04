param([Parameter(Mandatory = $true)][string]$Repo)

# OP14-056 Wadatsumi once-per-turn seal (user ruling 2026-07-27): E2 (self-
# negate for the turn when your hand is discarded by an effect) re-firing in
# the same turn caused an infinite self-negate loop. E2 now carries
# once_per_turn=true. This resolves E2 twice in the same turn through the
# real dispatch path: fire #1 must disable the card, fire #2 must resolve
# NOTHING (once gate), duel must stay healthy.
# Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class WadatsumiOnce {
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

    const uint WADA   = 880002221; // OP14-056
    const uint LEADER = 880000634;
    const uint FILLER = 880000881;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();

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
            } else { data.type = 1; data.race = 2; }
            Marshal.StructureToPtr(data, output, false);
        } catch (Exception e) { callbackErrors.Add("card reader: " + e); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        string text = Marshal.PtrToStringAnsi(message); if (text == null) text = "";
        if (type == 0) errors.Add(text); else probes.Add("t" + type + ": " + text);
    }
    static int Load(IntPtr duel, string name) {
        foreach (string d in new string[] { expansionScripts, standardScripts, Path.Combine(standardScripts, "unofficial") }) {
            string path = Path.Combine(d, name);
            if (File.Exists(path)) { byte[] b = File.ReadAllBytes(path); return OCG_LoadScript(duel, b, (uint)b.Length, name); }
        }
        if (name != "c0.lua") callbackErrors.Add("missing script: " + name);
        return 0;
    }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name) {
        try { return Load(duel, Marshal.PtrToStringAnsi(name)); } catch (Exception e) { callbackErrors.Add("script reader: " + e); return 0; }
    }
    class Reader {
        public byte[] buf; public int pos;
        public Reader(byte[] b, int p) { buf = b; pos = p; }
        public byte U8() { byte v = buf[pos]; pos += 1; return v; }
        public uint U32() { uint v = BitConverter.ToUInt32(buf, pos); pos += 4; return v; }
        public ulong U64() { ulong v = BitConverter.ToUInt64(buf, pos); pos += 8; return v; }
    }
    static void RespondI32(IntPtr duel, int v) { OCG_DuelSetResponse(duel, BitConverter.GetBytes(v), 4); }

    public static int Run(string repo) {
        string release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");

        Options o = new Options();
        o.seed0 = 1; o.seed1 = 2; o.seed2 = 3; o.seed3 = 4; o.flags = 0x2000000000UL;
        Player pl = new Player(); pl.startingLP = 5; pl.startingDrawCount = 5; pl.drawCountPerTurn = 1;
        o.team1 = pl; o.team2 = pl;
        o.cardReader = cardReader; o.scriptReader = scriptReader; o.logHandler = logHandler; o.cardReaderDone = cardReaderDone; o.enableUnsafeLibraries = 1;

        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref o) != 0 || duel == IntPtr.Zero) { Console.WriteLine("FAIL create"); return 2; }

        try {
            foreach (string name in new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local probe = Effect.GlobalEffect()\n" +
                "probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "probe:SetOperation(function()\n" +
                "  if Duel.GetTurnCount() ~= 2 or opcg._wo_done then return end\n" +
                "  opcg._wo_done = true\n" +
                "  local w = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880002221 end,0,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if w then Duel.MoveToField(w,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) end\n" +
                "  Debug.Message('placed='..tostring(w ~= nil))\n" +
                "  if not w then return end\n" +
                "  local ctx = {card=w, player=0, event_player=0, event_count=1}\n" +
                "  local done1 = OPCGCore.DispatchTiming(w, 'ON_HAND_DISCARDED_BY_TRAIT_EFFECT', ctx)\n" +
                "  Debug.Message('fire1_ok='..tostring(done1 and done1[1] and done1[1].ok == true))\n" +
                "  local ok, why = opcg.runtime.can_resolve(w, 'E2', {card=w, player=0})\n" +
                "  Debug.Message('gate2 ok='..tostring(ok)..' why='..tostring(why))\n" +
                "  local ctx2 = {card=w, player=0, event_player=0, event_count=1}\n" +
                "  local done2 = OPCGCore.DispatchTiming(w, 'ON_HAND_DISCARDED_BY_TRAIT_EFFECT', ctx2)\n" +
                "  Debug.Message('fire2_ok='..tostring(done2 and done2[1] and done2[1].ok == true))\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe,0)\n" +
                "local probe2 = Effect.GlobalEffect()\n" +
                "probe2:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe2:SetCode(EVENT_PHASE_START + PHASE_END)\n" +
                "probe2:SetOperation(function()\n" +
                "  if Duel.GetTurnCount() ~= 2 or opcg._wo_end then return end\n" +
                "  opcg._wo_end = true\n" +
                "  local w = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880002221 end,0,LOCATION_MZONE,0,nil):GetFirst()\n" +
                "  Debug.Message('disabled_end='..tostring(w ~= nil and w:IsDisabled() and true or false))\n" +
                "  Debug.Message('wo_probe_done')\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe2,0)\n";
            byte[] pb = System.Text.Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "probe.lua") != 1) callbackErrors.Add("probe failed");

            Action<int, uint, int> add = delegate (int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) { NewCard c = new NewCard(); c.team = (byte)p; c.duelist = 0; c.code = code; c.con = (byte)p; c.loc = 1; c.seq = 0; c.pos = 8; OCG_DuelNewCard(duel, ref c); }
            };
            add(0, LEADER, 1); add(0, WADA, 1); add(0, FILLER, 44);
            add(1, LEADER, 1); add(1, FILLER, 45);
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
                }
                if (probes.Exists(delegate (string s) { return s.Contains("wo_probe_done"); })) done = true;
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
                    uint n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    r.U8(); byte toEp = r.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                } else if (lastId == 15) {
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); uint smin = r.U32(); r.U32();
                    uint n = r.U32();
                    uint take = smin > 0 ? smin : 0;
                    if (take == 0) { OCG_DuelSetResponse(duel, new byte[8], 8); continue; }
                    List<byte> resp = new List<byte>();
                    resp.AddRange(BitConverter.GetBytes((int)0));
                    resp.AddRange(BitConverter.GetBytes(take));
                    for (uint i = 0; i < take; ++i) resp.AddRange(BitConverter.GetBytes(i));
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                } else if (lastId == 23 || lastId == 25 || lastId == 26) { RespondI32(duel, -1); }
                else if (lastId == 19) { RespondI32(duel, 0x1); }
                else if (lastId == 18 || lastId == 24) {
                    Reader r = new Reader(lastMsg, 1); byte player = r.U8(); byte need = r.U8(); uint flag = r.U32();
                    uint avail = ~flag; List<byte> resp = new List<byte>(); int given = 0;
                    for (int bit = 0; bit < 32 && given < Math.Max((int)need, 1); ++bit) {
                        if ((avail & (1u << bit)) == 0) continue;
                        byte con = (byte)((bit >= 16) ? (1 - player) : player);
                        int local = bit & 0xf; byte loc = (byte)((local >= 8) ? 8 : 4); byte seq = (byte)((local >= 8) ? (local - 8) : local);
                        resp.Add(con); resp.Add(loc); resp.Add(seq); given++;
                    }
                    if (given == 0) { Console.WriteLine("FAIL no free zone"); break; }
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                } else { Console.WriteLine("FAIL unexpected id=" + lastId); break; }
                if (newTurns >= 4) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (string p in probes) Console.WriteLine("LOG " + p);
        Console.WriteLine("--- results ---");
        Console.WriteLine("errors=" + errors.Count + " callbacks=" + callbackErrors.Count);
        foreach (string e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (string e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        bool fire1 = probes.Exists(delegate (string s) { return s.Contains("fire1_ok=true"); });
        bool gateBlocked = probes.Exists(delegate (string s) { return s.Contains("gate2 ok=false") && s.Contains("ONCE_PER_TURN_USED"); });
        bool fire2Blocked = probes.Exists(delegate (string s) { return s.Contains("fire2_ok=false"); });
        bool disabledEnd = probes.Exists(delegate (string s) { return s.Contains("disabled_end=true"); });
        Console.WriteLine("fire1_ok=" + fire1 + " gate_once_blocked=" + gateBlocked + " fire2_blocked=" + fire2Blocked + " disabled_at_end=" + disabledEnd);
        bool pass = fire1 && gateBlocked && fire2Blocked && disabledEnd
            && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "WADATSUMI_ONCE PASS" : "WADATSUMI_ONCE FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[WadatsumiOnce]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [WadatsumiOnce]::Run((Resolve-Path -LiteralPath $Repo).Path)
