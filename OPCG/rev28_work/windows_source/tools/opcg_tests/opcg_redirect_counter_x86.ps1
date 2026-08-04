param([Parameter(Mandatory = $true)][string]$Repo)

# OP14-060 Doflamingo leader E1 (user report 2026-07-27: pick works, attack
# target never moves): [On opponent attack][once/turn] DON-1: pick your
# leader or a Donquixote-crew character, the attack target BECOMES that card.
# Real battle: P0's 7000 attacker declares on P1's leader at T3; P1 fires the
# leader ignition, returns a DON, picks Baby 5 (880000523, power 1000).
# PASS = a second MSG_ATTACK re-announce lands on the character zone and
# Baby 5 is battle-KO'd (leader takes no life damage).
# Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class RedirectCounter {
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
    const uint CROC     = 880001747; // ST03-001 Baroque leader (P1)
    const uint NHW      = 880000037; // EB01-038 counter event
    const uint BABY5    = 880000523; // Donquixote crew, power 1000
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

        bool attacked = false, chainFired = false, redirected = false, baby5Died = false, targetPicked = false, counterUsed = false;
        int attackMsgs = 0;

        try {
            foreach (string name in new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local probe = Effect.GlobalEffect()\n" +
                "probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "probe:SetOperation(function()\n" +
                "  if Duel.GetTurnCount() ~= 2 or opcg._ra_setup then return end\n" +
                "  opcg._ra_setup = true\n" +
                "  local atk = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000001 end,0,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if atk then Duel.MoveToField(atk,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) Debug.Message('placed attacker') end\n" +
                "  local b5 = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000523 end,1,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if b5 then Duel.MoveToField(b5,1,1,LOCATION_MZONE,POS_FACEUP_ATTACK,true) Debug.Message('placed baby5') end\n" +
                "  local ev = Duel.GetMatchingGroup(function(c) return c:GetOriginalCode()==880000037 end,1,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
                "  if ev and ev:IsLocation(LOCATION_DECK) then Duel.SendtoHand(ev,1,REASON_RULE) end\n" +
                "  Debug.Message('nhw_in_hand='..tostring(ev ~= nil))\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe,0)\n";
            byte[] pb = System.Text.Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "probe.lua") != 1) callbackErrors.Add("probe failed");

            Action<int, uint, int> add = delegate (int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) { NewCard c = new NewCard(); c.team = (byte)p; c.duelist = 0; c.code = code; c.con = (byte)p; c.loc = 1; c.seq = 0; c.pos = 8; OCG_DuelNewCard(duel, ref c); }
            };
            add(0, P0LEADER, 1); add(0, ATTACKER, 1); add(0, FILLER, 44);
            add(1, CROC, 1); add(1, BABY5, 1); add(1, NHW, 1); add(1, FILLER, 43);
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
                    else if (id == 110) { // MSG_ATTACK: attacker loc_info + target loc_info
                        attackMsgs++;
                        Reader r = new Reader(payload, 1);
                        r.U8(); r.U8(); r.U32(); r.U32(); // attacker con/loc/seq/pos
                        byte tcon = r.U8(); byte tloc = r.U8(); uint tseq = r.U32();
                        Console.WriteLine("MSG_ATTACK #" + attackMsgs + " -> target P" + tcon + " loc=0x" + tloc.ToString("x") + " seq=" + tseq);
                        if (attackMsgs >= 2 && tloc == 0x4) redirected = true;
                    }
                    else if (id == 50) {
                        Reader r = new Reader(payload, 1); uint code = r.U32();
                        r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if (code == BABY5) {
                            moves.Add("BABY5 0x" + ploc.ToString("x") + "->0x" + cloc.ToString("x") + " T" + newTurns);
                            if (ploc == 0x4 && cloc == 0x10 && newTurns == 3) baby5Died = true;
                        }
                    }
                }
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL no msg"); break; }

                if (lastId == 12) { // effect yes/no: YES for the Doflamingo prompt
                    uint code = BitConverter.ToUInt32(lastMsg, 2);
                    if (newTurns == 3) { chainFired = true; Console.WriteLine("T3 PROMPT(12) code=" + code + " -> YES"); RespondI32(duel, 1); }
                    else RespondI32(duel, 0);
                } else if (lastId == 13) { RespondI32(duel, newTurns >= 3 ? 1 : 0); }
                else if (lastId == 14) { RespondI32(duel, 0); }
                else if (lastId == 16) { // select_chain: activate Dofla if offered
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); r.U8(); r.U32(); r.U32();
                    uint n = r.U32(); int doflaIdx = -1;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); r.U64(); r.U8(); if ((code == NHW || code == CROC) && doflaIdx < 0) doflaIdx = (int)i; }
                    if (doflaIdx >= 0 && newTurns == 3 && !chainFired) { chainFired = true; Console.WriteLine("T3 CHAIN -> activate"); RespondI32(duel, doflaIdx); }
                    else RespondI32(duel, -1);
                } else if (lastId == 11) {
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
                        Console.WriteLine("T3 ATTACK declared");
                        RespondI32(duel, (atkIdx << 16) | 9);
                    }
                    else RespondI32(duel, 7);
                } else if (lastId == 10) {
                    Reader r = new Reader(lastMsg, 1); r.U8();
                    uint n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    r.U8(); byte toEp = r.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                } else if (lastId == 15) { // prefer BABY5 (redirect pick), else first min
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); uint smin = r.U32(); r.U32();
                    uint n = r.U32(); int b5Idx = -1; int nhwIdx = -1; int save = r.pos;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); if (code == BABY5) b5Idx = (int)i; if (code == NHW) nhwIdx = (int)i; }
                    r.pos = save;
                    int pick = -1;
                    if (nhwIdx >= 0 && newTurns == 3 && !counterUsed) { counterUsed = true; pick = nhwIdx; Console.WriteLine("counter select -> NHW"); }
                    else if (b5Idx >= 0) { pick = b5Idx; }
                    uint take = pick >= 0 ? 1U : (smin > 0 ? smin : 0U);
                    if (take == 0) { OCG_DuelSetResponse(duel, new byte[8], 8); continue; }
                    List<byte> resp = new List<byte>();
                    resp.AddRange(BitConverter.GetBytes((int)0));
                    resp.AddRange(BitConverter.GetBytes(take));
                    if (pick >= 0) { if (pick == b5Idx && nhwIdx < 0) { targetPicked = true; Console.WriteLine("select -> BABY5"); } resp.AddRange(BitConverter.GetBytes((uint)pick)); }
                    else for (uint i = 0; i < take; ++i) resp.AddRange(BitConverter.GetBytes(i));
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                } else if (lastId == 26) {
                    Reader r = new Reader(lastMsg, 1); r.U8(); r.U8(); r.U8(); r.U32(); r.U32();
                    uint n = r.U32(); int b5Idx = -1;
                    for (uint i = 0; i < n; ++i) { uint code = r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); if (code == BABY5) b5Idx = (int)i; }
                    if (b5Idx >= 0) { targetPicked = true; Console.WriteLine("select(26) -> BABY5"); }
                    RespondI32(duel, b5Idx >= 0 ? b5Idx : -1);
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
                } else if (lastId == 23) { RespondI32(duel, 0); }
                else { Console.WriteLine("FAIL unexpected id=" + lastId); break; }
                if (newTurns >= 4) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (string p in probes) Console.WriteLine("LOG " + p);
        foreach (string s in moves) Console.WriteLine("MOVE " + s);
        Console.WriteLine("--- results ---");
        Console.WriteLine("errors=" + errors.Count + " callbacks=" + callbackErrors.Count);
        foreach (string e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (string e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        Console.WriteLine("attacked=" + attacked + " counter_used=" + counterUsed + " effect_fired=" + chainFired + " target_picked=" + targetPicked
            + " attack_msgs=" + attackMsgs + " redirected=" + redirected + " baby5_died=" + baby5Died);
        bool pass = attacked && counterUsed && targetPicked && redirected && baby5Died
            && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "REDIRECT_COUNTER PASS" : "REDIRECT_COUNTER FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[RedirectCounter]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [RedirectCounter]::Run((Resolve-Path -LiteralPath $Repo).Path)
