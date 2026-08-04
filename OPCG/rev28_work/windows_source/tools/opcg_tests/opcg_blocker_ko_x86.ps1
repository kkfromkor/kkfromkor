param([Parameter(Mandatory = $true)][string]$Repo)

# Blocker KO repro. A probe seats an ACTIVE blocker (880000016, power 2000,
# BLOCKER keyword) on P1 and a high-power attacker (880000001, power 7000) on
# P0 at turn 2. On turn 3 P0 attacks the P1 leader; the block step should let
# P1 declare the blocker (rests it, redirects the attack), and since
# 7000 >= 2000 the blocker MUST be KO'd (sent to trash 0x10). If the blocker
# survives, the redirected-battle KO path is broken.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class BlockerKo {
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

    const uint LEADER   = 880000634;
    const uint ATTACKER = 880000001; // power 7000
    const uint BLOCKER  = 880000016; // power 2000, BLOCKER keyword
    const uint FILLER   = 880000881;
    // 879999999 host str2 = counter prompt, str1 = blocker prompt (aux.Stringid = code<<20|n)
    static readonly ulong BLOCK_PROMPT = ((ulong)879999999 << 20) + 0;

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

        bool attacked = false, blockPrompted = false, blockerRested = false, blockerDestroyed = false, blockerToGrave = false;
        // [연장전] 지인 증상 "서로 공격 후 다음 턴 공격 선언 불가" 검증:
        // T3(P0 캐릭터 어택+블록전투) 후 T4(P1 리더 어택), T5(P0 동일 캐릭터 재어택)
        int lastAttackTurn = -1; List<int> attackTurns = new List<int>();

        try {
            foreach (string name in new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local probe = Effect.GlobalEffect()\n" +
                "probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "probe:SetOperation(function()\n" +
                "  if Duel.GetTurnCount() ~= 2 or opcg._blk_setup then return end\n" +
                "  opcg._blk_setup = true\n" +
                "  local atk = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000001 end,0,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if atk then Duel.MoveToField(atk,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) Debug.Message('placed attacker seq='..atk:GetSequence()) end\n" +
                "  local blk = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000016 end,1,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if blk then Duel.MoveToField(blk,1,1,LOCATION_MZONE,POS_FACEUP_ATTACK,true) Debug.Message('placed blocker seq='..blk:GetSequence()..' active='..tostring(opcg.IsActive(blk))..' isblocker='..tostring(opcg.HasKeyword(blk,'BLOCKER'))) end\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe,0)\n" +
                "local spy = Effect.GlobalEffect()\n" +
                "spy:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "spy:SetCode(EVENT_DESTROYED)\n" +
                "spy:SetOperation(function(e,tp,eg)\n" +
                "  if not eg then return end\n" +
                "  for c in aux.Next(eg) do Debug.Message('SPY_DESTROYED code='..c:GetOriginalCode()..' rBATTLE='..tostring(c:IsReason(REASON_BATTLE))) end\n" +
                "end)\n" +
                "Duel.RegisterEffect(spy,0)\n" +
                "local function dump(tag)\n" +
                "  local a=Duel.GetAttacker() local t=Duel.GetAttackTarget()\n" +
                "  local s=tag..' attacker='..(a and (a:GetOriginalCode()..'(pow'..a:GetAttack()..',pos'..a:GetPosition()..')') or 'nil')\n" +
                "  s=s..' target='..(t and (t:GetOriginalCode()..'(pow'..t:GetAttack()..',pos'..t:GetPosition()..',lead'..tostring(opcg.IsLeader(t))..')') or 'nil')\n" +
                "  Debug.Message(s)\n" +
                "end\n" +
                "for _,code in ipairs({EVENT_BATTLE_START, EVENT_PRE_DAMAGE_CALCULATE, EVENT_BATTLED, EVENT_DAMAGE_STEP_END}) do\n" +
                "  local ev = Effect.GlobalEffect() ev:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) ev:SetCode(code)\n" +
                "  ev:SetOperation(function() dump('EV'..code) end) Duel.RegisterEffect(ev,0)\n" +
                "end\n";
            byte[] pb = System.Text.Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "probe.lua") != 1) callbackErrors.Add("probe failed");

            Action<int, uint, int> add = delegate (int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) { NewCard c = new NewCard(); c.team = (byte)p; c.duelist = 0; c.code = code; c.con = (byte)p; c.loc = 1; c.seq = 0; c.pos = 8; OCG_DuelNewCard(duel, ref c); }
            };
            add(0, LEADER, 1); add(0, ATTACKER, 1); add(0, FILLER, 44);
            add(1, LEADER, 1); add(1, BLOCKER, 1); add(1, FILLER, 44);
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
                    else if (id == 60) Console.WriteLine("step " + step + ": MSG_ATTACK");
                    else if (id == 50) { // MSG_MOVE
                        Reader r = new Reader(payload, 1); uint code = r.U32();
                        r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if (code == BLOCKER) {
                            moves.Add("BLOCKER 0x" + ploc.ToString("x") + "->0x" + cloc.ToString("x"));
                            Console.WriteLine("step " + step + ": MOVE blocker 0x" + ploc.ToString("x") + "->0x" + cloc.ToString("x"));
                            if (cloc == 0x10) blockerToGrave = true;
                        }
                    } else if (id == 53) { // MSG_POS (rest)
                        Reader r = new Reader(payload, 1); uint code = r.U32(); r.U8(); r.U8(); r.U8(); byte pp = r.U8(), cp = r.U8();
                        if (code == BLOCKER && (cp & 0x4) != 0) { blockerRested = true; Console.WriteLine("step " + step + ": blocker rested"); }
                    }
                }
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL no msg"); break; }

                if (lastId == 13 || lastId == 12) {
                    Reader r = new Reader(lastMsg, 1); r.U8(); ulong desc = r.U64();
                    int ans = (desc == BLOCK_PROMPT) ? 1 : 0; // YES to block, NO to everything else
                    if (desc == BLOCK_PROMPT) { blockPrompted = true; Console.WriteLine("BLOCK PROMPT -> YES"); }
                    RespondI32(duel, ans);
                } else if (lastId == 14) { RespondI32(duel, 0); }
                else if (lastId == 16) { RespondI32(duel, -1); }
                else if (lastId == 11) { // idle
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n;
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    r.U8(); r.U8(); r.U8();
                    n = r.U32(); int atkIdx = -1; uint atkCode = 0;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); if (atkIdx < 0) { atkIdx = (int)i; atkCode = code; } if (code == ATTACKER) { atkIdx = (int)i; atkCode = code; } }
                    if (atkIdx >= 0 && lastAttackTurn != newTurns && newTurns >= 3) {
                        lastAttackTurn = newTurns; attackTurns.Add(newTurns); attacked = true;
                        Console.WriteLine("T" + newTurns + " ATTACK with " + atkCode + " via idx " + atkIdx);
                        RespondI32(duel, (atkIdx << 16) | 9);
                    }
                    else RespondI32(duel, 7);
                } else if (lastId == 10) { // battlecmd
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    byte toM2 = r.U8(); byte toEp = r.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                } else if (lastId == 15) { // select_card
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); uint smin = r.U32(); r.U32();
                    uint n = r.U32(); int pick = 0; int blkIdx = -1; bool allHand = n > 0;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); byte loc = r.U8(); r.U32(); r.U32(); if (loc != 0x2) allHand = false; if (code == BLOCKER) blkIdx = (int)i; }
                    // decline min0 all-hand windows (counter step) so nothing buffs the blocker
                    if (smin == 0 && allHand && blkIdx < 0) { Console.WriteLine("select_card min0 hand (counter) -> decline"); OCG_DuelSetResponse(duel, new byte[8], 8); continue; }
                    if (blkIdx >= 0) pick = blkIdx;
                    Console.WriteLine("select_card n=" + n + " min=" + smin + " -> " + pick);
                    byte[] resp = new byte[12];
                    Array.Copy(BitConverter.GetBytes((int)0), 0, resp, 0, 4);
                    Array.Copy(BitConverter.GetBytes((uint)1), 0, resp, 4, 4);
                    Array.Copy(BitConverter.GetBytes((uint)pick), 0, resp, 8, 4);
                    OCG_DuelSetResponse(duel, resp, 12);
                } else if (lastId == 26) { RespondI32(duel, -1); }
                else if (lastId == 25) { RespondI32(duel, -1); }
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
        foreach (string s in moves) Console.WriteLine("MOVE " + s);
        foreach (string s in probes) if (s.Contains("SPY_DESTROYED") && s.Contains("880000016")) blockerDestroyed = true;
        Console.WriteLine("--- results ---");
        Console.WriteLine("errors=" + errors.Count + " callbacks=" + callbackErrors.Count);
        foreach (string e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (string e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        Console.WriteLine("attacked=" + attacked + " block_prompted=" + blockPrompted + " blocker_rested=" + blockerRested
            + " blocker_destroyed=" + blockerDestroyed + " blocker_to_grave=" + blockerToGrave);
        Console.WriteLine("attack_turns=[" + string.Join(",", attackTurns) + "] (T3=블록전투, T4=상대 반격, T5=동일 캐릭터 재공격)");
        bool reattacks = attackTurns.Contains(3) && attackTurns.Contains(4) && attackTurns.Contains(5);
        bool pass = attacked && blockPrompted && blockerRested && blockerToGrave && reattacks
            && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "BLOCKER_KO PASS" : "BLOCKER_KO FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[BlockerKo]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [BlockerKo]::Run((Resolve-Path -LiteralPath $Repo).Path)
