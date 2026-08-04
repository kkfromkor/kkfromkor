param([Parameter(Mandatory = $true)][string]$Repo)

# EB03-006 Nami power-drop audit (user report 2026-07-27: power reduction
# does not happen). Two legs in one run:
#  E1 [On Play] cost: your ACTIVE leader -5000 this turn -> draw 1.
#     T2: DispatchTiming ON_PLAY, leader (Vivi, 5000) must read 0 after.
#  E2 [Main, once/turn] leader has Alabasta trait -> enemy character -1000.
#     T3: activate from idle by code, target P1's 880000002 (5000 -> 4000),
#     read at T3 end phase (THIS_TURN buff still live there).
# Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class Eb03006Power {
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

    const uint VIVI   = 880002104; // P0 leader, Alabasta trait, power 5000
    const uint NAMI   = 880002109; // EB03-006
    const uint VICTIM = 880000002; // P1 character, base power 5000
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

        bool e2Activated = false; bool namiPlayed = false; int drawT5 = 0;
        bool e2ActivatedT7 = false; bool t7Reported = false; int becomeTargets = 0;
        try {
            foreach (string name in new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local probe = Effect.GlobalEffect()\n" +
                "probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "probe:SetOperation(function()\n" +
                "  local turn = Duel.GetTurnCount()\n" +
                "  if turn == 2 and not opcg._np_t2 then\n" +
                "    opcg._np_t2 = true\n" +
                "    local vic = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000002 end,1,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "    if vic then Duel.MoveToField(vic,1,1,LOCATION_MZONE,POS_FACEUP_ATTACK,true) end\n" +
                "  elseif turn == 5 and not opcg._np_t5 then\n" +
                "    opcg._np_t5 = true\n" +
                "    local lead = opcg.GetLeader(0)\n" +
                "    Debug.Message('lead_atk_before='..tostring(lead and lead:GetAttack()))\n" +
                "    Debug.Message('don_count='..Duel.GetFieldGroupCount(0, LOCATION_MZONE+LOCATION_SZONE+LOCATION_PZONE, 0))\n" +
                "  elseif turn == 7 and not opcg._np_t7 then\n" +
                "    opcg._np_t7 = true\n" +
                "    local nami = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880002109 end,0,LOCATION_MZONE,0,nil):GetFirst()\n" +
                "    if nami then opcg.SetRested(nami, nil, 'EFFECT') end\n" +
                "    Debug.Message('nami_rested_t7='..tostring(nami ~= nil and opcg.IsRested(nami)))\n" +
                "  end\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe,0)\n" +
                "local probe2 = Effect.GlobalEffect()\n" +
                "probe2:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe2:SetCode(EVENT_PHASE_START + PHASE_END)\n" +
                "probe2:SetOperation(function()\n" +
                "  local turn = Duel.GetTurnCount()\n" +
                "  if turn == 5 and not opcg._np_t5e then\n" +
                "    opcg._np_t5e = true\n" +
                "    local lead = opcg.GetLeader(0)\n" +
                "    Debug.Message('lead_atk_after='..tostring(lead and lead:GetAttack()))\n" +
                "    local nami = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880002109 end,0,LOCATION_MZONE,0,nil):GetFirst()\n" +
                "    Debug.Message('nami_on_field='..tostring(nami ~= nil))\n" +
                "    local vic = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000002 end,1,LOCATION_MZONE,0,nil):GetFirst()\n" +
                "    Debug.Message('vic_atk_t5end='..tostring(vic and vic:GetAttack()))\n" +
                "  elseif turn == 7 and not opcg._np_t7e then\n" +
                "    opcg._np_t7e = true\n" +
                "    local vic = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000002 end,1,LOCATION_MZONE,0,nil):GetFirst()\n" +
                "    Debug.Message('vic_atk_t7end='..tostring(vic and vic:GetAttack()))\n" +
                "    Debug.Message('np_probe_done')\n" +
                "  end\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe2,0)\n";
            byte[] pb = System.Text.Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "probe.lua") != 1) callbackErrors.Add("probe failed");

            NewCard nami = new NewCard(); nami.team = 0; nami.duelist = 0; nami.code = NAMI; nami.con = 0; nami.loc = 0x2; nami.seq = 0; nami.pos = 0x1;
            OCG_DuelNewCard(duel, ref nami);
            Action<int, uint, int> add = delegate (int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) { NewCard c = new NewCard(); c.team = (byte)p; c.duelist = 0; c.code = code; c.con = (byte)p; c.loc = 1; c.seq = 0; c.pos = 8; OCG_DuelNewCard(duel, ref c); }
            };
            add(0, VIVI, 1); add(0, FILLER, 40);
            add(1, VICTIM, 1); add(1, FILLER, 40);
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
                    else if (id == 80 || id == 83) becomeTargets++;
                    else if (id == 90 && newTurns == 5) { Reader r = new Reader(payload, 1); r.U8(); drawT5 += (int)r.U32(); }
                }
                if (probes.Exists(delegate (string s) { return s.Contains("np_probe_done"); })) done = true;
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL no msg"); break; }

                if (lastId == 12) { RespondI32(duel, 1); }
                else if (lastId == 13) { RespondI32(duel, newTurns >= 2 ? 1 : 0); } // decline mulligan, accept effect prompts
                else if (lastId == 14) { RespondI32(duel, 0); }
                else if (lastId == 16) { RespondI32(duel, -1); }
                else if (lastId == 11) {
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n;
                    n = r.U32(); int playIdx = -1;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); if (code == NAMI) playIdx = (int)i; }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); int actIdx = -1;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); if (code == NAMI && actIdx < 0) actIdx = (int)i; }
                    if (playIdx >= 0 && newTurns == 5 && !namiPlayed) {
                        namiPlayed = true;
                        Console.WriteLine("T5 PLAY Nami idx " + playIdx);
                        RespondI32(duel, (playIdx << 16) | 0);
                    } else if (actIdx >= 0 && newTurns == 5 && namiPlayed && !e2Activated) {
                        e2Activated = true;
                        Console.WriteLine("T5 ACTIVATE Nami E2 idx " + actIdx);
                        RespondI32(duel, (actIdx << 16) | 5);
                    } else if (actIdx >= 0 && newTurns == 7 && !e2ActivatedT7) {
                        e2ActivatedT7 = true;
                        Console.WriteLine("T7 ACTIVATE Nami E2 (rested) idx " + actIdx);
                        RespondI32(duel, (actIdx << 16) | 5);
                    } else {
                        if (newTurns == 7 && !e2ActivatedT7 && !t7Reported) {
                            t7Reported = true;
                            Console.WriteLine("T7 idle: Nami E2 NOT in activatable list (repro!)");
                        }
                        RespondI32(duel, 7);
                    }
                                } else if (lastId == 10) {
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    r.U8(); byte toEp = r.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                } else if (lastId == 15) { // select: prefer VICTIM (E2 target), else first min
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); uint smin = r.U32(); r.U32();
                    uint n = r.U32(); int vicIdx = -1; int save = r.pos;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); if (code == VICTIM) vicIdx = (int)i; }
                    r.pos = save;
                    uint take = vicIdx >= 0 ? 1 : (smin > 0 ? smin : 0);
                    if (take == 0) { OCG_DuelSetResponse(duel, new byte[8], 8); continue; }
                    List<byte> resp = new List<byte>();
                    resp.AddRange(BitConverter.GetBytes((int)0));
                    resp.AddRange(BitConverter.GetBytes(take));
                    if (vicIdx >= 0) resp.AddRange(BitConverter.GetBytes((uint)vicIdx));
                    else for (uint i = 0; i < take; ++i) resp.AddRange(BitConverter.GetBytes(i));
                    Console.WriteLine("select_card n=" + n + " min=" + smin + " -> " + (vicIdx >= 0 ? "VICTIM" : "first"));
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                } else if (lastId == 25 || lastId == 26) { RespondI32(duel, -1); }
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
                } else if (lastId == 23) { RespondI32(duel, 0); }
                else { Console.WriteLine("FAIL unexpected id=" + lastId); break; }
                if (newTurns >= 8) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (string p in probes) Console.WriteLine("LOG " + p);
        Console.WriteLine("--- results ---");
        Console.WriteLine("errors=" + errors.Count + " callbacks=" + callbackErrors.Count);
        foreach (string e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (string e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        bool played = probes.Exists(delegate (string s2) { return s2.Contains("nami_on_field=true"); });
        bool leadDropped = probes.Exists(delegate (string s2) { return s2.Contains("lead_atk_after=0"); });
        bool vicDropped = probes.Exists(delegate (string s2) { return s2.Contains("vic_atk_t5end=4000"); });
        string lb = ""; string la = ""; string va = "";
        foreach (string p2 in probes) {
            if (p2.Contains("lead_atk_before=")) lb = p2;
            if (p2.Contains("lead_atk_after=")) la = p2;
            if (p2.Contains("vic_atk_t5end=")) va = p2;
        }
        Console.WriteLine("played=" + played + " | " + lb + " -> " + la + " (want 5000->0) | " + va + " (want 4000) | draw_t5=" + drawT5 + " e2=" + e2Activated);
        bool vicT7 = probes.Exists(delegate (string s2) { return s2.Contains("vic_atk_t7end=4000"); });
        Console.WriteLine("T7: rested_activation=" + e2ActivatedT7 + " vic_t7_dropped=" + vicT7);
        Console.WriteLine("become_target_msgs=" + becomeTargets);
        bool pass = played && leadDropped && e2Activated && vicDropped && drawT5 >= 2 && e2ActivatedT7 && vicT7 && becomeTargets >= 2
            && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "EB03006_POWER PASS" : "EB03006_POWER FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[Eb03006Power]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [Eb03006Power]::Run((Resolve-Path -LiteralPath $Repo).Path)
