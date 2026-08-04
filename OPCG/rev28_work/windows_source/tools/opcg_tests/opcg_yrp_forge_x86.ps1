param([Parameter(Mandatory = $true)][string]$Repo)

# Forge an OLD-format .yrp (re-simulation replay): the whole scenario is
# played through LEGAL responses only (no injected scripts), so the client
# can re-simulate it with its own core + shipped scripts and full knowledge
# (hands visible). Scenario (2026-07-13 battle-restoration proof):
#   T3  P0 plays Tashigi (OP10-032)
#   T4  P1 plays Wakyuri (OP13-089)
#   T5  P0 plays Koshiro (green, cost 2)
#   T6  P1 activates Jigen (EB01-051: KO a cost<=5 character) at Koshiro
#       -> Tashigi rests INSTEAD (REPLACE_KO on the native replacement
#       machinery), Koshiro survives; then Wakyuri attacks the P0 leader
#       through the restored battle steps (counter window answered NO)
#   T7  P0 leader attacks the rested Wakyuri (NEW native declare: idle
#       trailing attackable block, response (idx<<16)|9 - the old desc-1157
#       ignition is gone) -> blocker window (none) -> counter window (NO)
#       -> KO -> P1 activates [On K.O.] (YES) -> draws 1
# Pass 2 re-feeds the recorded responses blindly to prove the yrp re-simulates.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class YrpForge {
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

    const uint LEADER  = 880000634; // OP05-022
    const uint TASHIGI = 880001247; // OP10-032
    const uint KOSHIRO = 880001480; // OP12-027 (the protected green character)
    const uint WAKYURI = 880001661; // OP13-089 ([On K.O.] draw 1)
    const uint JIGEN   = 880000050; // EB01-051 (KO a cost<=5 character)
    const uint FILLER  = 880000881;
    const ulong ATTACK_DESC = 1157;
    // DUEL_OPCG_MODE | DUEL_NO_MAIN_PHASE_2 | DUEL_PSEUDO_SHUFFLE (keeps the
    // stacked deck order so the scripted hands actually arrive)
    const ulong OPT = 0x2000200010UL;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    public static void LoadDb(string csv) {
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
                ulong sc = v[6];
                if (sc != 0) {
                    IntPtr buf = Marshal.AllocHGlobal(10);
                    int off = 0;
                    for (int s = 0; s < 4; ++s) {
                        ushort part = (ushort)((sc >> (16 * s)) & 0xffff);
                        if (part == 0) continue;
                        Marshal.WriteInt16(buf, off, (short)part); off += 2;
                    }
                    Marshal.WriteInt16(buf, off, 0);
                    data.setcodes = buf;
                }
                data.attack = (int)(long)v[7]; data.defense = (int)(long)v[8];
            } else { data.type = 1; data.race = 2; }
            Marshal.StructureToPtr(data, output, false);
        } catch (Exception e) { callbackErrors.Add("card reader: " + e); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        var text = Marshal.PtrToStringAnsi(message) ?? "";
        if (type == 0) errors.Add(text);
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

    // deck lists exactly as fed (the yrp reader re-feeds in this order);
    // the LAST card fed is the deck TOP, so hands live at the end
    static readonly uint[] deck0 = BuildDeck(new uint[] { TASHIGI, KOSHIRO }, LEADER);
    static readonly uint[] deck1 = BuildDeck(new uint[] { WAKYURI, JIGEN }, LEADER);
    static uint[] BuildDeck(uint[] handCards, uint leader) {
        // fed order: seq0..N. Draw takes list_main.back() = TOP, so the LAST
        // fed cards are drawn first. Native opening hand (startingDrawCount=5)
        // takes the top 5 BEFORE OPCG deals life, so put the scripted cards at
        // the very top (fed last) plus filler to round the opening hand out.
        var list = new List<uint>();
        list.Add(leader);
        for (int i = 0; i < 16; ++i) list.Add(FILLER); // life(4) + turn draws
        for (int i = 0; i < (5 - handCards.Length); ++i) list.Add(FILLER); // rest of opening hand
        list.AddRange(handCards);                      // top of deck = opening hand
        return list.ToArray();
    }

    class Reader {
        public byte[] buf; public int pos;
        public Reader(byte[] b, int p) { buf = b; pos = p; }
        public byte U8() { var v = buf[pos]; pos += 1; return v; }
        public uint U32() { var v = BitConverter.ToUInt32(buf, pos); pos += 4; return v; }
        public ulong U64() { var v = BitConverter.ToUInt64(buf, pos); pos += 8; return v; }
    }

    static IntPtr NewDuel() {
        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4,
            flags = OPT,
            team1 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader,
            logHandler = logHandler, cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) return IntPtr.Zero;
        foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
            if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
        for (int p = 0; p < 2; ++p) {
            var deck = p == 0 ? deck0 : deck1;
            for (uint s = 0; s < deck.Length; ++s) {
                var card = new NewCard { team = (byte)p, duelist = 0, code = deck[s], con = (byte)p, loc = 1, seq = s, pos = 8 };
                OCG_DuelNewCard(duel, ref card);
            }
        }
        OCG_StartDuel(duel);
        return duel;
    }

    // ---------- shared observation state ----------
    static int newTurns;
    static int drawLog;
    static bool tashigiRested, koshiroDied, wakyuriKO, koDraw;
    static void ResetObservations() {
        newTurns = 0; tashigiRested = false; koshiroDied = false; wakyuriKO = false; koDraw = false;
    }
    static void Observe(byte msgId, byte[] payload) {
        if (msgId == 40) newTurns++;
        else if (msgId == 53) {
            var r = new Reader(payload, 1);
            uint code = r.U32(); r.U8(); r.U8(); r.U8();
            byte pp = r.U8(), cp = r.U8();
            if (code == TASHIGI && (pp & 0x1) != 0 && (cp & 0x4) != 0) tashigiRested = true;
        } else if (msgId == 50) {
            var r = new Reader(payload, 1);
            uint code = r.U32();
            r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
            r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
            if (code == KOSHIRO && cloc == 0x10) koshiroDied = true;
            if (code == WAKYURI && ploc == 0x4 && cloc == 0x10) wakyuriKO = true;
        } else if (msgId == 90) {
            if (newTurns == 0) {
                try {
                    uint cnt = BitConverter.ToUInt32(payload, 2);
                    var cs = new List<string>();
                    for (uint k = 0; k < cnt && 6 + 8 * k + 4 <= payload.Length; ++k)
                        cs.Add(BitConverter.ToUInt32(payload, (int)(6 + 8 * k)).ToString());
                    Console.WriteLine("draw p" + payload[1] + " x" + cnt + ": " + string.Join(",", cs));
                } catch { }
            }
            if (wakyuriKO && payload[1] == 1 && BitConverter.ToUInt32(payload, 2) == 1 && newTurns <= 7)
                koDraw = true;
        }
    }

    // ---------- pass 1: play the scenario, record every response ----------
    static readonly List<byte[]> responses = new List<byte[]>();
    static void Respond(IntPtr duel, byte[] resp) {
        responses.Add(resp);
        OCG_DuelSetResponse(duel, resp, (uint)resp.Length);
    }
    static void RespondI32(IntPtr duel, int v) { Respond(duel, BitConverter.GetBytes(v)); }

    static bool actedEvent, actedWakyuriAttack, actedLeaderAttack;
    static readonly Dictionary<int, uint> summonPlan = new Dictionary<int, uint> {
        { 3, TASHIGI }, { 4, WAKYURI }, { 5, KOSHIRO }
    };

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");

        // ---------------- PASS 1: drive & record ----------------
        var duel = NewDuel();
        if (duel == IntPtr.Zero) { Console.WriteLine("FAIL create"); return 2; }
        ResetObservations();
        try {
            uint lastMsgId = 0; byte[] lastMsg = null;
            for (int step = 0; step < 30000; ++step) {
                int st = OCG_DuelProcess(duel);
                uint length;
                var ptr = OCG_DuelGetMessage(duel, out length);
                var all = new byte[length];
                if (length > 0) Marshal.Copy(ptr, all, 0, (int)length);
                int off = 0;
                while (off + 4 <= all.Length) {
                    uint pl = BitConverter.ToUInt32(all, off); off += 4;
                    if (pl == 0 || off + pl > all.Length) break;
                    byte id = all[off];
                    var payload = new byte[pl];
                    Array.Copy(all, off, payload, 0, (int)pl);
                    off += (int)pl;
                    lastMsgId = id; lastMsg = payload;
                    Observe(id, payload);
                    if (id == 1) { Console.WriteLine("RETRY at step " + step); }
                    if (id == 90 && drawLog < 6) {
                        drawLog++;
                        try {
                            uint cnt = BitConverter.ToUInt32(payload, 2);
                            var cs = new List<string>();
                            for (uint k = 0; k < cnt && 6 + 8 * k + 4 <= payload.Length; ++k)
                                cs.Add(BitConverter.ToUInt32(payload, (int)(6 + 8 * k)).ToString());
                            Console.WriteLine("DRAW p" + payload[1] + " x" + cnt + ": " + string.Join(",", cs));
                        } catch { }
                    }
                }
                if (st == 0) break;
                if (st != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL no message"); break; }

                if (lastMsgId == 12) { RespondI32(duel, 1); }      // EFFECTYN: Tashigi says yes
                else if (lastMsgId == 13) {
                    // YES only for Wakyuri's own [On K.O.] activation prompt;
                    // NO for mulligan / mill / trigger / blocker / counter.
                    var r13 = new Reader(lastMsg, 1);
                    r13.U8();
                    ulong d13 = r13.U64();
                    RespondI32(duel, (d13 >> 20) == (ulong)WAKYURI ? 1 : 0);
                }
                else if (lastMsgId == 14) { RespondI32(duel, 0); }
                else if (lastMsgId == 16) { RespondI32(duel, -1); }
                else if (lastMsgId == 19) { RespondI32(duel, 0x1); }
                else if (lastMsgId == 11) {
                    var r = new Reader(lastMsg, 1);
                    r.U8();
                    // summonable
                    uint n = r.U32();
                    var summonIdx = new Dictionary<uint, int>();
                    for (uint i = 0; i < n; ++i) { uint c = r.U32(); r.U8(); r.U8(); r.U32(); if (!summonIdx.ContainsKey(c)) summonIdx[c] = (int)i; }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); } // spsummon
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); }  // repos
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); } // mset
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); } // sset
                    n = r.U32();
                    int jigenIdx = -1, wakyuriAtk = -1, leaderAtk = -1;
                    for (uint i = 0; i < n; ++i) {
                        uint c = r.U32(); r.U8(); r.U8(); r.U32();
                        r.U64(); r.U8();
                        if (c == JIGEN && jigenIdx < 0) jigenIdx = (int)i;
                    }
                    // [OPCG new attack] trailing attackable block after the
                    // to_bp/to_ep/shuffle bytes: {code u32, con u8, loc u8,
                    // seq u8, direct u8}; response (idx<<16)|9 declares.
                    r.U8(); r.U8(); r.U8();
                    n = r.U32();
                    for (uint i = 0; i < n; ++i) {
                        uint c = r.U32(); r.U8(); r.U8(); r.U8(); r.U8();
                        if (c == WAKYURI && wakyuriAtk < 0) wakyuriAtk = (int)i;
                        if (c == LEADER && leaderAtk < 0) leaderAtk = (int)i;
                    }
                    if (newTurns <= 7) {
                        var keys = new List<string>();
                        foreach (var kv in summonIdx) keys.Add(kv.Key.ToString());
                        Console.WriteLine("idle T" + newTurns + " summonable=[" + string.Join(",", keys)
                            + "] jigen=" + jigenIdx + " watk=" + wakyuriAtk + " latk=" + leaderAtk);
                    }
                    uint want;
                    if (summonPlan.TryGetValue(newTurns, out want) && summonIdx.ContainsKey(want)) {
                        Console.WriteLine("T" + newTurns + ": play " + want);
                        RespondI32(duel, (summonIdx[want] << 16) | 0);
                    } else if (newTurns == 6 && !actedEvent && jigenIdx >= 0) {
                        actedEvent = true;
                        Console.WriteLine("T6: activate JIGEN");
                        RespondI32(duel, (jigenIdx << 16) | 5);
                    } else if (newTurns == 6 && actedEvent && !actedWakyuriAttack && wakyuriAtk >= 0) {
                        actedWakyuriAttack = true;
                        Console.WriteLine("T6: WAKYURI attacks (t=9)");
                        RespondI32(duel, (wakyuriAtk << 16) | 9);
                    } else if (newTurns == 7 && !actedLeaderAttack && leaderAtk >= 0) {
                        actedLeaderAttack = true;
                        Console.WriteLine("T7: LEADER attacks (t=9)");
                        RespondI32(duel, (leaderAtk << 16) | 9);
                    } else {
                        RespondI32(duel, 7); // end phase
                    }
                }
                else if (lastMsgId == 10) {
                    // BattleCommand window after a battle: [u8 pl][u32 nAct{
                    // code,con,loc,seq u32,desc u64,mode u8}][u32 nAtk{8B}]
                    // [u8 to_m2][u8 to_ep] - no further action, leave battle.
                    var rb = new Reader(lastMsg, 1);
                    rb.U8();
                    uint nb = rb.U32();
                    for (uint i = 0; i < nb; ++i) { rb.U32(); rb.U8(); rb.U8(); rb.U32(); rb.U64(); rb.U8(); }
                    nb = rb.U32();
                    for (uint i = 0; i < nb; ++i) { rb.U32(); rb.U8(); rb.U8(); rb.U8(); rb.U8(); }
                    byte toM2 = rb.U8(); byte toEp = rb.U8();
                    RespondI32(duel, toEp != 0 ? 3 : 2);
                }
                else if (lastMsgId == 15) {
                    var r = new Reader(lastMsg, 1);
                    r.U8(); r.U8();
                    uint smin = r.U32(); r.U32();
                    uint n = r.U32();
                    int pick = 0;
                    var codes = new uint[n];
                    bool allHand = n > 0;
                    for (uint i = 0; i < n; ++i) {
                        uint c = r.U32(); r.U8(); byte loc = r.U8(); r.U32(); r.U32();
                        codes[i] = c;
                        if (loc != 0x2) allHand = false;
                    }
                    // counter batch window = declinable (min0) all-hand select; other
                    // min0 selects (e.g. Jigen's "KO up to 1" target) must still pick
                    if (smin == 0 && allHand) {
                        Console.WriteLine("select_card min0 hand (counter window) -> decline");
                        Respond(duel, new byte[8]);
                        continue;
                    }
                    // preference: kill-target Koshiro > attack-target Wakyuri > leader
                    for (uint i = 0; i < n; ++i) if (codes[i] == KOSHIRO) { pick = (int)i; goto picked; }
                    for (uint i = 0; i < n; ++i) if (codes[i] == WAKYURI) { pick = (int)i; goto picked; }
                    for (uint i = 0; i < n; ++i) if (codes[i] == LEADER) { pick = (int)i; goto picked; }
                picked:
                    Console.WriteLine("select_card n=" + n + " -> " + pick + " (" + codes[pick] + ")");
                    var resp = new byte[12];
                    Array.Copy(BitConverter.GetBytes((int)0), 0, resp, 0, 4);
                    Array.Copy(BitConverter.GetBytes((uint)1), 0, resp, 4, 4);
                    Array.Copy(BitConverter.GetBytes((uint)pick), 0, resp, 8, 4);
                    Respond(duel, resp);
                }
                else if (lastMsgId == 18 || lastMsgId == 24) {
                    var player = lastMsg[1];
                    var flag = BitConverter.ToUInt32(lastMsg, 3);
                    byte con = player, loc = 0x04, seq = 0;
                    bool found = false;
                    for (int bit = 0; bit < 7 && !found; ++bit)
                        if ((flag & (1u << bit)) == 0) { loc = 0x04; seq = (byte)bit; found = true; }
                    for (int bit = 8; bit < 16 && !found; ++bit)
                        if ((flag & (1u << bit)) == 0) { loc = 0x08; seq = (byte)(bit - 8); found = true; }
                    Respond(duel, new byte[] { con, loc, seq });
                }
                else if (lastMsgId == 23) { RespondI32(duel, 0); }
                else if (lastMsgId == 26 || lastMsgId == 25) { RespondI32(duel, -1); }
                else { Console.WriteLine("FAIL unexpected request id=" + lastMsgId); break; }

                if (newTurns >= 9) break;
                if (koDraw && newTurns >= 7) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("--- pass1 ---");
        Console.WriteLine("errors=" + errors.Count + " callbacks=" + callbackErrors.Count
            + " responses=" + responses.Count);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        Console.WriteLine("tashigi_rested=" + tashigiRested + " koshiro_died=" + koshiroDied
            + " wakyuri_ko=" + wakyuriKO + " ko_draw=" + koDraw);
        bool scenario = tashigiRested && !koshiroDied && wakyuriKO && koDraw
            && errors.Count == 0 && callbackErrors.Count == 0;
        if (!scenario) { Console.WriteLine("YRP_FORGE FAIL (scenario)"); return 1; }

        // ---------------- PASS 2: blind re-feed (what the client will do) ----------------
        var duel2 = NewDuel();
        if (duel2 == IntPtr.Zero) { Console.WriteLine("FAIL create2"); return 2; }
        ResetObservations();
        int fed = 0; bool starved = false;
        try {
            for (int step = 0; step < 30000; ++step) {
                int st = OCG_DuelProcess(duel2);
                uint length;
                var ptr = OCG_DuelGetMessage(duel2, out length);
                var all = new byte[length];
                if (length > 0) Marshal.Copy(ptr, all, 0, (int)length);
                int off = 0;
                while (off + 4 <= all.Length) {
                    uint pl = BitConverter.ToUInt32(all, off); off += 4;
                    if (pl == 0 || off + pl > all.Length) break;
                    Observe(all[off], SubArray(all, off, (int)pl));
                    off += (int)pl;
                }
                if (st == 0) break;
                if (st != 1) continue;
                if (fed >= responses.Count) { starved = true; break; }
                var resp = responses[fed++];
                OCG_DuelSetResponse(duel2, resp, (uint)resp.Length);
            }
        } finally { OCG_DestroyDuel(duel2); }
        Console.WriteLine("--- pass2 (blind re-feed) ---");
        Console.WriteLine("fed=" + fed + "/" + responses.Count + " starved=" + starved);
        Console.WriteLine("tashigi_rested=" + tashigiRested + " koshiro_died=" + koshiroDied
            + " wakyuri_ko=" + wakyuriKO + " ko_draw=" + koDraw);
        // the recording is truncated the instant the K.O. draw lands, so pass 2
        // running out of responses (starved) at the very end is EXPECTED — what
        // matters is that the identical scenario re-simulated from responses alone
        bool resim = tashigiRested && !koshiroDied && wakyuriKO && koDraw;
        if (!resim) { Console.WriteLine("YRP_FORGE FAIL (resim)"); return 1; }

        // ---------------- write the .yrp ----------------
        var file = new List<byte>();
        Action<uint> W32 = v => file.AddRange(BitConverter.GetBytes(v));
        Action<ulong> W64 = v => file.AddRange(BitConverter.GetBytes(v));
        W32(0x31707279); // 'yrp1'
        W32(0x0b0029);
        W32(0x330);      // LUA64 | NEWREPLAY | 64BIT_DUELFLAG | EXTENDED_HEADER
        W32(1783682403);
        W32(0); W32(0);
        file.AddRange(new byte[8]);   // lzma props (uncompressed)
        W64(1);                        // extended header version
        W64(1); W64(2); W64(3); W64(4); // seed = the sim's seed
        Action<string> WName = s => {
            var raw = new byte[40];
            var b = System.Text.Encoding.Unicode.GetBytes(s);
            Array.Copy(b, raw, Math.Min(b.Length, 38));
            file.AddRange(raw);
        };
        W32(1); WName("Fable");
        W32(1); WName("Verify");
        W32(5);  // start lp
        W32(0);  // start hand (the OPCG runtime draws its own)
        W32(1);  // draw count
        W64(OPT);
        Action<uint[]> WDeck = deck => {
            W32((uint)deck.Length);
            foreach (var c in deck) W32(c);
            W32(0); // extra deck
        };
        WDeck(deck0);
        WDeck(deck1);
        W32(0); // extra cards
        foreach (var resp in responses) {
            file.Add((byte)resp.Length);
            file.AddRange(resp);
        }
        var outPath = Path.Combine(Directory.GetCurrentDirectory(), "replay", "OPCG_battle_restore_20260713.yrp");
        File.WriteAllBytes(outPath, file.ToArray());
        Console.WriteLine("forged=" + outPath + " bytes=" + file.Count);
        Console.WriteLine("YRP_FORGE PASS");
        return 0;
    }
    static byte[] SubArray(byte[] src, int off, int len) {
        var b = new byte[len];
        Array.Copy(src, off, b, 0, len);
        return b;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[YrpForge]::LoadDb((Join-Path (Resolve-Path -LiteralPath $Repo).Path 'tools\opcg_tests\cdb_dump.csv'))
exit [YrpForge]::Run((Resolve-Path -LiteralPath $Repo).Path)
