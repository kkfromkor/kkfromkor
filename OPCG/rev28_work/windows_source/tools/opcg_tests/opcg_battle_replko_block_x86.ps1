param([Parameter(Mandatory = $true)][string]$Repo)

# EB03-001 Vivi leader E1: [Once per turn] when your base-cost>=4 character
# would be K.O.'d, you MAY trash 1 hand card instead. User report 2026-07-27:
# the protection never fires on BATTLE K.O. (effect K.O. path unknown).
# This drives a REAL attack: P0's 7000-power attacker hits P1's rested
# 4-cost character (880000198, power below 7000) at T3 -> the core's battle
# destroy must consult the leader's EFFECT_DESTROY_REPLACE and prompt.
# T4 leg: effect K.O. (Duel.Destroy REASON_EFFECT) on the same victim as a
# comparison point. Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class BattleReplKoBlock {
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

    const uint P0LEADER = 880000634;
    const uint ATTACKER = 880000001; // power 7000
    const uint VIVI     = 880002104; // EB03-001 leader (P1)
    const uint VICTIM   = 880000198; // base cost 4, pow 5000, BLOCKER keyword
    static readonly ulong BLOCK_PROMPT = ((ulong)879999999 << 20) + 0;
    const uint FILLER   = 880000881;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> moves = new List<string>();
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

        bool attacked = false; bool blockPrompted = false;
        List<int> promptTurns = new List<int>(); // turns where the Vivi replace prompt appeared
        bool victimDiedT3 = false, costPaidT3 = false;

        try {
            foreach (string name in new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local probe = Effect.GlobalEffect()\n" +
                "probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "probe:SetOperation(function()\n" +
                "  local turn = Duel.GetTurnCount()\n" +
                "  if turn == 2 and not opcg._rk_setup then\n" +
                "    opcg._rk_setup = true\n" +
                "    local atk = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000001 end,0,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "    if atk then Duel.MoveToField(atk,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) Debug.Message('placed attacker') end\n" +
                "    local vic = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000198 end,1,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "    if vic then Duel.MoveToField(vic,1,1,LOCATION_MZONE,POS_FACEUP_ATTACK,true) Debug.Message('placed blocker active='..tostring(opcg.IsActive(vic))) end\n" +
                "    local ld = Duel.GetFieldGroup(1,LOCATION_MZONE,0):Filter(function(c) return c:GetOriginalCode()==880002104 end,nil):GetFirst()\n" +
                "    Debug.Message('vivi_found='..tostring(ld ~= nil))\n" +
                "    if ld then Debug.Message('replko_registered='..tostring(ld:IsHasEffect(EFFECT_DESTROY_REPLACE) and true or false)) end\n" +
                "  elseif turn == 4 and not opcg._rk_t4 then\n" +
                "    opcg._rk_t4 = true\n" +
                "    local vic = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000198 end,1,LOCATION_MZONE,0,nil):GetFirst()\n" +
                "    Debug.Message('victim_after_battle='..(vic and 'MZONE' or 'GONE'))\n" +
                "    if vic then\n" +
                "      Duel.Destroy(vic, REASON_EFFECT, LOCATION_GRAVE, 0)\n" +
                "      Debug.Message('victim_effect_ko_saved='..tostring(vic:IsLocation(LOCATION_MZONE)))\n" +
                "    end\n" +
                "    Debug.Message('effect_leg_done')\n" +
                "  end\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe,0)\n";
            byte[] pb = System.Text.Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "probe.lua") != 1) callbackErrors.Add("probe failed");

            Action<int, uint, int> add = delegate (int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) { NewCard c = new NewCard(); c.team = (byte)p; c.duelist = 0; c.code = code; c.con = (byte)p; c.loc = 1; c.seq = 0; c.pos = 8; OCG_DuelNewCard(duel, ref c); }
            };
            add(0, P0LEADER, 1); add(0, ATTACKER, 1); add(0, FILLER, 44);
            add(1, VIVI, 1); add(1, VICTIM, 1); add(1, FILLER, 44);
            OCG_StartDuel(duel);

            uint lastId = 0; byte[] lastMsg = null; int newTurns = 0;
            bool done = false;
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
                    else if (id == 60) { Console.WriteLine("step " + step + " T" + newTurns + ": MSG_ATTACK"); }
                    else if (id == 50) { // MSG_MOVE
                        Reader r = new Reader(payload, 1); uint code = r.U32();
                        byte pcon = r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        byte ccon = r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if (code == VICTIM) {
                            moves.Add("VICTIM 0x" + ploc.ToString("x") + "->0x" + cloc.ToString("x") + " T" + newTurns);
                            if (ploc == 0x4 && cloc == 0x10 && newTurns == 3) victimDiedT3 = true;
                        } else if (pcon == 1 && ploc == 0x2 && cloc == 0x10) {
                            moves.Add("P1 HAND->TRASH code=" + code + " T" + newTurns);
                            if (newTurns == 3) costPaidT3 = true;
                        }
                    }
                }
                if (probes.Exists(delegate (string s) { return s.Contains("effect_leg_done"); })) done = true;
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL no msg"); break; }

                if (lastId == 12) { // MSG_SELECT_EFFECTYN: player u8, code u32, ...
                    uint code = BitConverter.ToUInt32(lastMsg, 2);
                    if (code == VIVI) {
                        promptTurns.Add(newTurns);
                        Console.WriteLine("T" + newTurns + " VIVI REPLACE PROMPT -> YES");
                        RespondI32(duel, 1);
                    } else RespondI32(duel, 0);
                } else if (lastId == 13) {
                    Reader r = new Reader(lastMsg, 1); r.U8(); ulong desc = r.U64();
                    int ans = (desc == BLOCK_PROMPT && newTurns == 3) ? 1 : 0;
                    if (ans == 1) { blockPrompted = true; Console.WriteLine("T" + newTurns + " BLOCK PROMPT -> YES"); }
                    RespondI32(duel, ans);
                }
                else if (lastId == 14) { RespondI32(duel, 0); }
                else if (lastId == 16) { RespondI32(duel, -1); }
                else if (lastId == 11) { // idle (+ attackable list appended in OPCG fork)
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n;
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    r.U8(); r.U8(); r.U8();
                    n = r.U32(); int atkIdx = -1;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); if (code == ATTACKER) atkIdx = (int)i; }
                    if (atkIdx >= 0 && newTurns == 3 && !attacked) {
                        attacked = true;
                        Console.WriteLine("T" + newTurns + " ATTACK declared via idx " + atkIdx);
                        RespondI32(duel, (atkIdx << 16) | 9);
                    }
                    else RespondI32(duel, 7);
                } else if (lastId == 10) { // battlecmd: to M2/EP, never re-attack
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    byte toM2 = r.U8(); byte toEp = r.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                } else if (lastId == 15) { // select_card: attack target OR trash-hand cost
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); uint smin = r.U32(); r.U32();
                    uint n = r.U32(); int pick = 0; int vicIdx = -1; bool allHand = n > 0;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); byte loc = r.U8(); r.U32(); r.U32(); if (loc != 0x2) allHand = false; if (code == VICTIM) vicIdx = (int)i; }
                    if (smin == 0 && allHand && vicIdx < 0) { OCG_DuelSetResponse(duel, new byte[8], 8); continue; }
                    if (vicIdx >= 0) pick = vicIdx;
                    Console.WriteLine("select_card n=" + n + " min=" + smin + " allHand=" + allHand + " -> " + pick);
                    byte[] resp = new byte[12];
                    Array.Copy(BitConverter.GetBytes((int)0), 0, resp, 0, 4);
                    Array.Copy(BitConverter.GetBytes((uint)1), 0, resp, 4, 4);
                    Array.Copy(BitConverter.GetBytes((uint)pick), 0, resp, 8, 4);
                    OCG_DuelSetResponse(duel, resp, 12);
                } else if (lastId == 26) { // select_unselect: prefer victim, else finish
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); r.U8(); r.U32(); r.U32();
                    uint n = r.U32(); int vicIdx = -1;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); if (code == VICTIM) vicIdx = (int)i; }
                    RespondI32(duel, vicIdx >= 0 ? vicIdx : -1);
                } else if (lastId == 25) { RespondI32(duel, -1); }
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
                if (newTurns >= 5) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (string p in probes) Console.WriteLine("LOG " + p);
        foreach (string s in moves) Console.WriteLine("MOVE " + s);
        Console.WriteLine("--- results ---");
        Console.WriteLine("errors=" + errors.Count + " callbacks=" + callbackErrors.Count);
        foreach (string e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (string e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        bool registered = probes.Exists(delegate (string s) { return s.Contains("replko_registered=true"); });
        bool battleSaved = probes.Exists(delegate (string s) { return s.Contains("victim_after_battle=MZONE"); });
        bool effectSaved = probes.Exists(delegate (string s) { return s.Contains("victim_effect_ko_saved=true"); });
        bool battlePrompt = promptTurns.Contains(3);
        Console.WriteLine("attacked=" + attacked + " block_prompted=" + blockPrompted + " registered=" + registered
            + " battle_prompt=" + battlePrompt + " battle_saved=" + battleSaved + " cost_paid_T3=" + costPaidT3
            + " victim_died_T3=" + victimDiedT3 + " effect_ko_saved=" + effectSaved
            + " prompt_turns=[" + string.Join(",", promptTurns.ConvertAll(delegate (int t) { return t.ToString(); }).ToArray()) + "]");
        // 'registered' stays informational only: IsHasEffect can't see a
        // FIELD-type replace whose handler is the leader (the prompt firing
        // is the real registration proof)
        bool pass = attacked && blockPrompted && battlePrompt && battleSaved && costPaidT3 && effectSaved
            && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "BATTLE_REPLKO PASS" : "BATTLE_REPLKO FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[BattleReplKoBlock]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [BattleReplKoBlock]::Run((Resolve-Path -LiteralPath $Repo).Path)
