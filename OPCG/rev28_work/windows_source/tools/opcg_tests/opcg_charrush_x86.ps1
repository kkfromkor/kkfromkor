param([Parameter(Mandatory = $true)][string]$Repo)

# Class rule audit (user directive 2026-07-27): "can attack CHARACTERS on
# its play turn" (EFFECT_ALLOW_ATTACK_CHARACTER - OP14-090 Mr.1, OP04-096)
# must NOT open the leader on the play turn. Scenario: Mr.1 placed at T3
# (play-turn state, condition met via a vanilla cost-8 ally) attacks - the
# target window must offer ONLY the rested enemy character, never the
# leader (seq 5). At T5 (no longer play turn) the leader must be offered
# again. Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class CharRush {
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

    const uint LEADER = 880000634;
    const uint MR1    = 880002255; // OP14-090, power 6000
    const uint BIG    = 880000065; // vanilla cost 8 (fulfils Mr.1's condition)
    const uint VICTIM = 880000002; // P1 character, power 5000
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

        bool attackedT3 = false, attackedT5 = false, victimDied = false;
        bool sawTargetsT3 = false, leaderOfferedT3 = false, leaderOfferedT5 = false;

        try {
            foreach (string name in new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local probe = Effect.GlobalEffect()\n" +
                "probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "probe:SetOperation(function()\n" +
                "  if Duel.GetTurnCount() ~= 3 or opcg._cr_setup then return end\n" +
                "  opcg._cr_setup = true\n" +
                "  local big = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000065 end,0,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if big then Duel.MoveToField(big,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) end\n" +
                "  local mr1 = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880002255 end,0,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if mr1 then Duel.MoveToField(mr1,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) end\n" +
                "  local vic = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000002 end,1,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if vic then Duel.MoveToField(vic,1,1,LOCATION_MZONE,POS_FACEUP_DEFENSE,true) end\n" +
                "  Debug.Message('setup big='..tostring(big ~= nil)..' mr1='..tostring(mr1 ~= nil)..' vic='..tostring(vic ~= nil))\n" +
                "  if mr1 then Debug.Message('mr1_turnid='..tostring(mr1.GetTurnID and mr1:GetTurnID()))\n" +
                "    Debug.Message('mr1_allow='..tostring(mr1:IsHasEffect(opcg.EFFECT_ALLOW_ATTACK_CHARACTER) and true or false)) end\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe,0)\n";
            byte[] pb = System.Text.Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "probe.lua") != 1) callbackErrors.Add("probe failed");

            Action<int, uint, int> add = delegate (int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) { NewCard c = new NewCard(); c.team = (byte)p; c.duelist = 0; c.code = code; c.con = (byte)p; c.loc = 1; c.seq = 0; c.pos = 8; OCG_DuelNewCard(duel, ref c); }
            };
            add(0, LEADER, 1); add(0, MR1, 1); add(0, BIG, 1); add(0, FILLER, 43);
            add(1, LEADER, 1); add(1, VICTIM, 1); add(1, FILLER, 44);
            OCG_StartDuel(duel);

            uint lastId = 0; byte[] lastMsg = null; int newTurns = 0;
            for (int step = 0; step < 20000; ++step) {
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
                    else if (id == 50) {
                        Reader r = new Reader(payload, 1); uint code = r.U32();
                        r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if (code == VICTIM && ploc == 0x4 && cloc == 0x10 && newTurns == 3) victimDied = true;
                    }
                }
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL no msg"); break; }

                if (lastId == 12) { RespondI32(duel, 0); }
                else if (lastId == 13) { RespondI32(duel, 0); }
                else if (lastId == 14) { RespondI32(duel, 0); }
                else if (lastId == 16) { RespondI32(duel, -1); }
                else if (lastId == 11) {
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n;
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    r.U8(); r.U8(); r.U8();
                    n = r.U32(); int mr1Idx = -1;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); if (code == MR1) mr1Idx = (int)i; }
                    if (mr1Idx >= 0 && newTurns == 3 && !attackedT3) {
                        attackedT3 = true;
                        Console.WriteLine("T3 ATTACK with Mr.1 (play turn)");
                        RespondI32(duel, (mr1Idx << 16) | 9);
                    } else if (mr1Idx >= 0 && newTurns == 5 && !attackedT5) {
                        attackedT5 = true;
                        Console.WriteLine("T5 ATTACK with Mr.1 (later turn)");
                        RespondI32(duel, (mr1Idx << 16) | 9);
                    }
                    else RespondI32(duel, 7);
                } else if (lastId == 10) {
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    r.U8(); byte toEp = r.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                } else if (lastId == 15) {
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); uint smin = r.U32(); r.U32();
                    uint n = r.U32(); int pick = 0; bool isTargetWindow = false; bool hasLeader = false; int vicIdx = -1; int leaderIdx = -1; int save = r.pos;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); byte con = r.U8(); byte loc = r.U8(); uint seq = r.U32(); r.U32();
                        if (con == 1 && loc == 0x4) { isTargetWindow = true; if (seq == 5) { hasLeader = true; leaderIdx = (int)i; } if (code == VICTIM) vicIdx = (int)i; }
                    }
                    r.pos = save;
                    if (isTargetWindow && newTurns == 3 && attackedT3 && !sawTargetsT3) {
                        sawTargetsT3 = true; leaderOfferedT3 = hasLeader;
                        Console.WriteLine("T3 target window n=" + n + " leader_offered=" + hasLeader);
                        pick = vicIdx >= 0 ? vicIdx : 0;
                    } else if (isTargetWindow && newTurns == 5 && attackedT5) {
                        leaderOfferedT5 = leaderOfferedT5 || hasLeader;
                        Console.WriteLine("T5 target window n=" + n + " leader_offered=" + hasLeader);
                        pick = leaderIdx >= 0 ? leaderIdx : 0;
                    } else if (smin == 0) { OCG_DuelSetResponse(duel, new byte[8], 8); continue; }
                    List<byte> resp = new List<byte>();
                    resp.AddRange(BitConverter.GetBytes((int)0));
                    resp.AddRange(BitConverter.GetBytes((uint)1));
                    resp.AddRange(BitConverter.GetBytes((uint)pick));
                    OCG_DuelSetResponse(duel, resp.ToArray(), 12);
                } else if (lastId == 25 || lastId == 26 || lastId == 23) { RespondI32(duel, -1); }
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
                if (newTurns >= 6) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (string p in probes) Console.WriteLine("LOG " + p);
        Console.WriteLine("--- results ---");
        Console.WriteLine("errors=" + errors.Count + " callbacks=" + callbackErrors.Count);
        foreach (string e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (string e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        Console.WriteLine("t3_attacked=" + attackedT3 + " t3_target_window=" + sawTargetsT3
            + " t3_leader_offered=" + leaderOfferedT3 + " victim_died=" + victimDied
            + " t5_attacked=" + attackedT5 + " t5_leader_offered=" + leaderOfferedT5);
        bool pass = attackedT3 && sawTargetsT3 && !leaderOfferedT3 && victimDied
            && attackedT5 && leaderOfferedT5
            && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "CHARRUSH PASS" : "CHARRUSH FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[CharRush]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [CharRush]::Run((Resolve-Path -LiteralPath $Repo).Path)
