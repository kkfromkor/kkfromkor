param([Parameter(Mandatory = $true)][string]$Repo)

# cdb_dump.csv (same directory) feeds the card reader; regenerate with:
#   python -c "import sqlite3; con=sqlite3.connect('bin/release/expansions/cards-opcg.cdb');
#     print(chr(10).join(','.join(str(x) for x in r) for r in
#     con.execute('select id,type,race,level,attribute,category,setcode,atk,def from datas')))"

# Damage-step procedure audit with OP07-102 Jinbe (880000957, [Trigger]:
# bounce a cost<=4 enemy character + add this card to hand).
# P0 leader attacks P1 leader; P1's life is all Jinbe. Expected wire trail:
#   EXTRA(0x40) -> REMOVED(0x20, trigger limbo) -> HAND(0x02)
# plus attacker rest at declaration, correct damage accounting, no errors.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class ReplayForge {
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
        public DataReader cardReader;
        public IntPtr payload1;
        public ScriptReader scriptReader;
        public IntPtr payload2;
        public LogHandler logHandler;
        public IntPtr payload3;
        public DataReaderDone cardReaderDone;
        public IntPtr payload4;
        public byte enableUnsafeLibraries;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct NewCard { public byte team, duelist; public uint code; public byte con; public uint loc, seq, pos; }
    [StructLayout(LayoutKind.Sequential)]
    public struct CardData {
        public uint code, alias;
        public IntPtr setcodes;
        public uint type, level, attribute;
        public ulong race;
        public int attack, defense;
        public uint lscale, rscale, link_marker, category;
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
    [StructLayout(LayoutKind.Sequential)]
    public struct QueryInfo { public uint flags; public byte con; public uint loc, seq, overlay_seq; }
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr OCG_DuelQueryLocation(IntPtr duel, out uint length, ref QueryInfo info);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int OCG_LoadScript(IntPtr duel, byte[] buffer, uint length, [MarshalAs(UnmanagedType.LPStr)] string name);

    const uint JINBE = 880000957;
    const uint LEADER = 880000634;
    const ulong TRIGGER_DESC = ((ulong)879999998 << 20) + 1;
    const ulong ATTACK_DESC = 1157;

    static string standardScripts;
    static string expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> jinbeMoves = new List<string>();
    static readonly List<string> draws = new List<string>();
    static readonly List<byte[]> recorded = new List<byte[]>(); // full chunks: [type][payload...]

    // a streamed replay learns card knowledge (hand codes, positions, stats)
    // from MSG_UPDATE_DATA query packets — real recordings interleave them
    // after every message batch, so the forge must too
    static void EmitLocationQuery(IntPtr duel, byte player, uint loc) {
        var info = new QueryInfo { flags = 0x3F81FFF, con = player, loc = loc, seq = 0, overlay_seq = 0 };
        uint qlen;
        var ptr = OCG_DuelQueryLocation(duel, out qlen, ref info);
        if (ptr == IntPtr.Zero || qlen == 0) return;
        var chunk = new byte[3 + qlen];
        chunk[0] = 6; // MSG_UPDATE_DATA
        chunk[1] = player;
        chunk[2] = (byte)loc;
        Marshal.Copy(ptr, chunk, 3, (int)qlen);
        recorded.Add(chunk);
    }
    static void EmitRefreshSet(IntPtr duel, bool full) {
        for (byte p = 0; p < 2; ++p) {
            if (full) EmitLocationQuery(duel, p, 0x01);  // deck
            EmitLocationQuery(duel, p, 0x02);            // hand
            EmitLocationQuery(duel, p, 0x04);            // mzone
            EmitLocationQuery(duel, p, 0x08);            // szone
            EmitLocationQuery(duel, p, 0x10);            // grave
            EmitLocationQuery(duel, p, 0x40);            // extra (life)
        }
    }

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();
    public static void LoadDb(string csvPath) {
        foreach (string line in File.ReadAllLines(csvPath)) {
            string[] f = line.Split(',');
            if (f.Length < 9) continue;
            ulong[] v = new ulong[9];
            for (int i = 0; i < 9; ++i) v[i] = unchecked((ulong)long.Parse(f[i]));
            cardDb[(uint)v[0]] = v;
        }
    }
    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            CardData data = new CardData();
            data.code = code;
            ulong[] v;
            if (cardDb.TryGetValue(code, out v)) {
                data.type = (uint)v[1];
                data.race = v[2];
                data.level = (uint)v[3];
                data.attribute = (uint)v[4];
                data.category = (uint)v[5];
                data.attack = (int)(long)v[7];
                data.defense = (int)(long)v[8];
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
            } else { data.type = 1; data.race = 2; }
            Marshal.StructureToPtr(data, output, false);
        } catch (Exception exception) { callbackErrors.Add("card reader: " + exception); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        string text = Marshal.PtrToStringAnsi(message);
        if (text == null) text = "";
        if (type == 0) errors.Add(text);
        else probes.Add("type" + type + ": " + text);
    }
    static int Load(IntPtr duel, string name) {
        string[] dirs = new string[] { expansionScripts, standardScripts, Path.Combine(standardScripts, "unofficial") };
        foreach (string directory in dirs) {
            string path = Path.Combine(directory, name);
            if (File.Exists(path)) {
                byte[] bytes = File.ReadAllBytes(path);
                return OCG_LoadScript(duel, bytes, (uint)bytes.Length, name);
            }
        }
        if (name != "c0.lua") callbackErrors.Add("missing script: " + name);
        return 0;
    }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name) {
        try { return Load(duel, Marshal.PtrToStringAnsi(name)); }
        catch (Exception exception) { callbackErrors.Add("script reader: " + exception); return 0; }
    }

    class Reader {
        public byte[] buf; public int pos;
        public Reader(byte[] b, int p) { buf = b; pos = p; }
        public byte U8() { byte v = buf[pos]; pos += 1; return v; }
        public ushort U16() { ushort v = BitConverter.ToUInt16(buf, pos); pos += 2; return v; }
        public uint U32() { uint v = BitConverter.ToUInt32(buf, pos); pos += 4; return v; }
        public ulong U64() { ulong v = BitConverter.ToUInt64(buf, pos); pos += 8; return v; }
    }

    static void RespondI32(IntPtr duel, int value) {
        OCG_DuelSetResponse(duel, BitConverter.GetBytes(value), 4);
    }

    public static int Run(string repo) {
        string release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");

        Options options = new Options();
        options.seed0 = 1; options.seed1 = 2; options.seed2 = 3; options.seed3 = 4;
        options.flags = 0x2000200000UL; // OPCG + NO_MAIN_PHASE_2, matching the replay header's opt
        Player pl = new Player(); pl.startingLP = 5; pl.startingDrawCount = 5; pl.drawCountPerTurn = 1;
        options.team1 = pl; options.team2 = pl;
        options.cardReader = cardReader; options.scriptReader = scriptReader;
        options.logHandler = logHandler; options.cardReaderDone = cardReaderDone;
        options.enableUnsafeLibraries = 1;

        IntPtr duel;
        int status = OCG_CreateDuel(out duel, ref options);
        if (status != 0 || duel == IntPtr.Zero) { Console.WriteLine("FAIL OCG_CreateDuel: " + status); return 2; }

        int retries = 0, idleCount = 0, newTurns = 0;
        bool attacked = false, attackerRested = false;

        try {
            string[] boot = new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" };
            foreach (string name in boot)
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local probe = Effect.GlobalEffect()\n" +
                "probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "probe:SetOperation(function()\n" +
                "  if Duel.GetTurnCount() ~= 2 or opcg._forge_done then return end\n" +
                "  opcg._forge_done = true\n" +
                "  local function fetch(p, code)\n" +
                "    return Duel.GetMatchingGroup(function(c) return c:GetOriginalCode() == code end,\n" +
                "      p, LOCATION_DECK + LOCATION_HAND, 0, nil):GetFirst()\n" +
                "  end\n" +
                "  local tashigi = fetch(0, 880001247)\n" +
                "  local koshiro = fetch(0, 880001480)\n" +
                "  local wakyuri = fetch(1, 880001661)\n" +
                "  if tashigi then Duel.MoveToField(tashigi, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true) end\n" +
                "  if koshiro then Duel.MoveToField(koshiro, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true) end\n" +
                "  if wakyuri then\n" +
                "    Duel.MoveToField(wakyuri, 1, 1, LOCATION_MZONE, POS_FACEUP_ATTACK, true)\n" +
                "    opcg.SetRested(wakyuri)\n" +
                "  end\n" +
                "  Debug.Message('FORGE placed t=' .. tostring(tashigi ~= nil)\n" +
                "    .. ' k=' .. tostring(koshiro ~= nil) .. ' w=' .. tostring(wakyuri ~= nil))\n" +
                "  -- scene A: the opponent's effect K.O.s the green Koshiro; Tashigi\n" +
                "  -- (OP10-032) may rest instead and the character survives\n" +
                "  if koshiro then\n" +
                "    local destroyed = Duel.Destroy(koshiro, REASON_EFFECT, LOCATION_GRAVE, 1)\n" +
                "    Debug.Message('FORGE sceneA destroy_returned=' .. tostring(destroyed)\n" +
                "      .. ' koshiro_saved=' .. tostring(koshiro:IsLocation(LOCATION_MZONE))\n" +
                "      .. ' tashigi_rested=' .. tostring(opcg.IsRested(tashigi)))\n" +
                "  end\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe, 0)\n";
            byte[] probeBytes = System.Text.Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, probeBytes, (uint)probeBytes.Length, "probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");

            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    NewCard card = new NewCard();
                    card.team = (byte)p; card.duelist = 0; card.code = code; card.con = (byte)p;
                    card.loc = 1; card.seq = 0; card.pos = 8;
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, LEADER, 1);
            addCards(0, 880001247, 1); // Tashigi (OP10-032)
            addCards(0, 880001480, 1); // Koshiro: the protected green character
            addCards(0, 880000881, 12);
            addCards(1, LEADER, 1);
            addCards(1, 880001661, 1); // Wakyuri (OP13-089): [On K.O.] draw 1
            addCards(1, 880000881, 12);
            OCG_StartDuel(duel);
            EmitRefreshSet(duel, true); // initial full-knowledge snapshot after MSG_START

            uint lastMsgId = 0;
            byte[] lastMsg = null;
            int step;
            for (step = 0; step < 20000; ++step) {
                status = OCG_DuelProcess(duel);
                uint length;
                IntPtr ptr = OCG_DuelGetMessage(duel, out length);
                byte[] all = new byte[length];
                if (length > 0) Marshal.Copy(ptr, all, 0, (int)length);
                int off = 0;
                var pending = new List<byte[]>();
                while (off + 4 <= all.Length) {
                    uint packetLength = BitConverter.ToUInt32(all, off); off += 4;
                    if (packetLength == 0 || off + packetLength > all.Length) break;
                    byte msgId = all[off];
                    byte[] payload = new byte[packetLength];
                    Array.Copy(all, off, payload, 0, (int)packetLength);
                    off += (int)packetLength;
                    lastMsgId = msgId; lastMsg = payload;
                    pending.Add(payload);

                    if (msgId == 1) retries++;
                    else if (msgId == 40) { newTurns++; Console.WriteLine("step " + step + ": NEW_TURN #" + newTurns); }
                    else if (msgId == 41) Console.WriteLine("step " + step + ": NEW_PHASE 0x" + BitConverter.ToUInt16(payload, 1).ToString("x"));
                    else if (msgId == 5) Console.WriteLine("step " + step + ": MSG_WIN player=" + payload[1] + " reason=" + payload[2]);
                    else if (msgId == 53) {
                        Reader r = new Reader(payload, 1);
                        uint code = r.U32(); byte cc = r.U8(); byte cl = r.U8(); byte cs = r.U8();
                        byte pp = r.U8(); byte cp = r.U8();
                        if (code == LEADER && cc == 0 && (pp & 0x1) != 0 && (cp & 0x4) != 0 && attacked)
                            attackerRested = true;
                        Console.WriteLine("step " + step + ": POS code=" + code + " con=" + cc +
                            " " + pp.ToString("x") + "->" + cp.ToString("x"));
                    }
                    else if (msgId == 50) {
                        Reader r = new Reader(payload, 1);
                        uint code = r.U32();
                        byte pcon = r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        byte ccon = r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if ((code == JINBE || code == 880001661) && (ploc != cloc || pcon != ccon)) {
                            string s = code + ": 0x" + ploc.ToString("x") + "(p" + pcon + ")->0x" + cloc.ToString("x") + "(p" + ccon + ")";
                            jinbeMoves.Add(s);
                            Console.WriteLine("step " + step + ": MOVE " + s);
                        }
                    }
                    else if (msgId == 90) {
                        byte dplayer = payload[1];
                        uint dcount = BitConverter.ToUInt32(payload, 2);
                        bool koSeenNow = false;
                        foreach (string s in jinbeMoves) if (s.Contains("->0x10(p1)")) koSeenNow = true;
                        koSeenNow = koSeenNow && newTurns <= 3; // same-turn resolution only
                        draws.Add((koSeenNow ? "postko_" : "") + "p" + dplayer + "x" + dcount);
                        Console.WriteLine("step " + step + ": DRAW p" + dplayer + " x" + dcount + (koSeenNow ? " (post-KO)" : ""));
                    }
                }
                // a request message ends the drain and is never part of a
                // recorded stream: keep everything before it
                if (status == 1 && pending.Count > 0) pending.RemoveAt(pending.Count - 1);
                recorded.AddRange(pending);
                if (pending.Count > 0) EmitRefreshSet(duel, false);
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL awaiting with no message"); break; }

                if (lastMsgId == 12) {
                    // EFFECTYN: Tashigi's replacement decision — always YES
                    Console.WriteLine("EFFECTYN -> 1");
                    RespondI32(duel, 1);
                } else if (lastMsgId == 13) {
                    Reader r = new Reader(lastMsg, 1);
                    byte pl_ = r.U8();
                    ulong desc = r.U64();
                    int answer = (desc == TRIGGER_DESC) ? 1 : 0;
                    Console.WriteLine("YESNO player=" + pl_ + " desc=" + desc +
                        (desc == TRIGGER_DESC ? " (TRIGGER)" : "") + " -> " + answer);
                    RespondI32(duel, answer);
                } else if (lastMsgId == 14) { RespondI32(duel, 0); }
                else if (lastMsgId == 16) { RespondI32(duel, -1); }
                else if (lastMsgId == 11) {
                    idleCount++;
                    Reader r = new Reader(lastMsg, 1);
                    r.U8();
                    uint n;
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32();
                    int attackIdx = -1;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); r.U8(); r.U8(); r.U32();
                        ulong desc = r.U64(); r.U8();
                        if (code == LEADER && desc == ATTACK_DESC && attackIdx < 0) attackIdx = (int)i;
                    }
                    if (!attacked && attackIdx >= 0) {
                        attacked = true;
                        Console.WriteLine("idle#" + idleCount + ": ATTACK via index " + attackIdx);
                        RespondI32(duel, (attackIdx << 16) | 5);
                    } else {
                        RespondI32(duel, 7);
                    }
                } else if (lastMsgId == 15) {
                    Reader r = new Reader(lastMsg, 1);
                    r.U8(); r.U8(); r.U32(); r.U32();
                    uint n = r.U32();
                    int pick = 0;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); byte con = r.U8(); byte loc = r.U8(); uint seq = r.U32(); r.U32();
                        if (code == 880001661 && loc == 0x4 && con == 1) pick = (int)i;
                    }
                    Console.WriteLine("select_card n=" + n + " -> " + pick);
                    byte[] resp = new byte[12];
                    Array.Copy(BitConverter.GetBytes((int)0), 0, resp, 0, 4);
                    Array.Copy(BitConverter.GetBytes((uint)1), 0, resp, 4, 4);
                    Array.Copy(BitConverter.GetBytes((uint)pick), 0, resp, 8, 4);
                    OCG_DuelSetResponse(duel, resp, 12);
                } else if (lastMsgId == 26) { RespondI32(duel, -1); }
                else if (lastMsgId == 25) { RespondI32(duel, -1); }
                else if (lastMsgId == 19) { RespondI32(duel, 0x1); }
                else if (lastMsgId == 18 || lastMsgId == 24) {
                    Reader r = new Reader(lastMsg, 1);
                    byte player = r.U8(); byte need = r.U8(); uint flag = r.U32();
                    uint available = ~flag;
                    List<byte> resp = new List<byte>();
                    int given = 0;
                    for (int bit = 0; bit < 32 && given < Math.Max((int)need, 1); ++bit) {
                        if ((available & (1u << bit)) == 0) continue;
                        byte con = (byte)((bit >= 16) ? (1 - player) : player);
                        int local = bit & 0xf;
                        byte loc = (byte)((local >= 8) ? 8 : 4);
                        byte seq = (byte)((local >= 8) ? (local - 8) : local);
                        resp.Add(con); resp.Add(loc); resp.Add(seq);
                        given++;
                    }
                    if (given == 0) { Console.WriteLine("FAIL select_place no free zone"); break; }
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                } else {
                    Console.WriteLine("FAIL unexpected awaited msg id=" + lastMsgId);
                    break;
                }
                if (newTurns >= 6) break;
                bool koSeen = false;
                foreach (string s in jinbeMoves) if (s.StartsWith("880001661") && s.EndsWith("0x10(p1)")) koSeen = true;
                if (koSeen && newTurns >= 3) break;
            }
            Console.WriteLine("loop done: steps=" + step + " status=" + status + " idles=" + idleCount + " turns=" + newTurns);
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("--- results ---");
        Console.WriteLine("retries=" + retries + " script_errors=" + errors.Count + " callback_failures=" + callbackErrors.Count);
        foreach (string error in callbackErrors) Console.WriteLine("CALLBACK: " + error);
        foreach (string error in errors) Console.WriteLine("SCRIPT: " + error);
        foreach (string probe in probes) Console.WriteLine("LOG " + probe);
        Console.WriteLine("attacked=" + attacked + " attacker_rested=" + attackerRested);
        Console.WriteLine("jinbe_moves=" + string.Join(" | ", jinbeMoves.ToArray()));
        // correct trigger procedure: life(0x40) -> limbo(0x20) -> hand(0x2)
        bool koToTrash = false;
        foreach (string s in jinbeMoves) {
            if (s.StartsWith("880001661") && s.Contains("0x4(p1)->0x10(p1)")) koToTrash = true;
        }
        Console.WriteLine("ko_to_trash=" + koToTrash);
        bool koDraw = draws.Contains("postko_p1x1");
        bool sceneA = false;
        foreach (string p in probes)
            if (p.Contains("koshiro_saved=true") && p.Contains("tashigi_rested=true")) sceneA = true;
        Console.WriteLine("draws=" + string.Join(",", draws.ToArray()) + " ko_draw=" + koDraw + " sceneA=" + sceneA);

        // ---- forge the .yrpX (mirrors Replay::WriteHeader/preamble/WritePacket) ----
        var file = new List<byte>();
        Action<uint> W32 = v => file.AddRange(BitConverter.GetBytes(v));
        Action<ulong> W64 = v => file.AddRange(BitConverter.GetBytes(v));
        W32(0x58707279); // 'yrpX'
        W32(0x0b0029);   // client version (matches this build's recordings)
        W32(0x330);      // LUA64 | NEWREPLAY | 64BIT_DUELFLAG | EXTENDED_HEADER (uncompressed)
        W32(1783682403); // timestamp
        W32(0); W32(0);  // datasize / hash: unchecked for uncompressed streams
        file.AddRange(new byte[8]);           // lzma props (unused)
        W64(1);                                // extended header version
        W64(1); W64(2); W64(3); W64(4);        // seed (unused in streamed playback)
        Action<string> WName = s => {
            var raw = new byte[40];
            var b = System.Text.Encoding.Unicode.GetBytes(s);
            Array.Copy(b, raw, Math.Min(b.Length, 38));
            file.AddRange(raw);
        };
        W32(1); WName("Fable");
        W32(1); WName("Verify");
        W64(0x2000200000UL); // DUEL_OPCG_MODE | DUEL_NO_MAIN_PHASE_2
        // the hand-built MSG_START every real recording starts with
        file.Add(4);
        W32(17);
        file.Add(0);
        W32(5); W32(5);
        file.AddRange(BitConverter.GetBytes((ushort)15)); file.AddRange(BitConverter.GetBytes((ushort)0));
        file.AddRange(BitConverter.GetBytes((ushort)14)); file.AddRange(BitConverter.GetBytes((ushort)0));
        foreach (var chunk in recorded) {
            file.Add(chunk[0]);
            W32((uint)(chunk.Length - 1));
            for (int i = 1; i < chunk.Length; ++i) file.Add(chunk[i]);
        }
        var outPath = Path.Combine(Directory.GetCurrentDirectory(), "replay", "OPCG_verify_2cards.yrpX");
        File.WriteAllBytes(outPath, file.ToArray());
        Console.WriteLine("forged=" + outPath + " bytes=" + file.Count + " packets=" + (recorded.Count + 1));

        bool pass = errors.Count == 0 && callbackErrors.Count == 0 && retries == 0
            && attacked && koToTrash && koDraw && sceneA;
        Console.WriteLine(pass ? "REPLAY_FORGE PASS" : "REPLAY_FORGE FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[ReplayForge]::LoadDb((Join-Path (Resolve-Path -LiteralPath $Repo).Path 'tools\opcg_tests\cdb_dump.csv'))
exit [ReplayForge]::Run((Resolve-Path -LiteralPath $Repo).Path)
