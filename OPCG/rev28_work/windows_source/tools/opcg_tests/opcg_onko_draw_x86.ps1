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

public static class OnKoDrawVerify {
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
        options.flags = 0x2000000000UL;
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
                "  local turn = Duel.GetTurnCount()\n" +
                "  if turn == 2 and not opcg._ko_probe_placed then\n" +
                "    opcg._ko_probe_placed = true\n" +
                "    local card = Duel.GetMatchingGroup(function(c)\n" +
                "      -- deck order is no longer auto-shuffled after the life deal, so\n" +
                "      -- the fillers may all sit in the opening hand: search both zones\n" +
                "      return c:GetOriginalCode() == 880001661 end, 1, LOCATION_DECK + LOCATION_HAND, 0, nil):GetFirst()\n" +
                "    if card then\n" +
                "      Duel.MoveToField(card, 1, 1, LOCATION_MZONE, POS_FACEUP_ATTACK, true)\n" +
                "      opcg.SetRested(card)\n" +
                "      Debug.Message('PROBE placed rested 880001661 seq=' .. card:GetSequence())\n" +
                "    end\n" +
                "  end\n" +
                "end)\n" +
                "Duel.RegisterEffect(probe, 0)\n" +
                "local spy = Effect.GlobalEffect()\n" +
                "spy:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "spy:SetCode(EVENT_DESTROYED)\n" +
                "spy:SetOperation(function(e,tp,eg,ep,ev,re,r,rp)\n" +
                "  if not eg then return end\n" +
                "  for c in aux.Next(eg) do\n" +
                "    Debug.Message('SPY_DESTROYED code=' .. c:GetOriginalCode() .. ' loc=' .. c:GetLocation()\n" +
                "      .. ' prevMZ=' .. tostring(c:IsPreviousLocation(LOCATION_MZONE))\n" +
                "      .. ' rDESTROY=' .. tostring(c:IsReason(REASON_DESTROY))\n" +
                "      .. ' rBATTLE=' .. tostring(c:IsReason(REASON_BATTLE)))\n" +
                "  end\n" +
                "end)\n" +
                "Duel.RegisterEffect(spy, 0)\n";
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
            addCards(0, 880000881, 45);
            addCards(1, LEADER, 1);
            addCards(1, (uint)JINBE, 40);
            addCards(1, 880001661, 5);
            OCG_StartDuel(duel);

            uint lastMsgId = 0;
            byte[] lastMsg = null;
            int koSeenStep = -1; // step when KO was seen: quitting immediately starves the pending ON_KO resolution
            int step;
            for (step = 0; step < 20000; ++step) {
                status = OCG_DuelProcess(duel);
                uint length;
                IntPtr ptr = OCG_DuelGetMessage(duel, out length);
                byte[] all = new byte[length];
                if (length > 0) Marshal.Copy(ptr, all, 0, (int)length);
                int off = 0;
                while (off + 4 <= all.Length) {
                    uint packetLength = BitConverter.ToUInt32(all, off); off += 4;
                    if (packetLength == 0 || off + packetLength > all.Length) break;
                    byte msgId = all[off];
                    byte[] payload = new byte[packetLength];
                    Array.Copy(all, off, payload, 0, (int)packetLength);
                    off += (int)packetLength;
                    lastMsgId = msgId; lastMsg = payload;

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
                    else if (msgId == 60) {
                        Console.WriteLine("step " + step + ": MSG_ATTACK");
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
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL awaiting with no message"); break; }

                if (lastMsgId == 13 || lastMsgId == 12) {
                    Reader r = new Reader(lastMsg, 1);
                    byte pl_ = r.U8();
                    ulong desc = r.U64();
                    // YES only for life trigger and the KO'd card's own effect prompt
                    // (880001661 [ON_KO] activation); NO for blocker/counter host strings etc.
                    int answer = (desc == TRIGGER_DESC || (desc >> 20) == 880001661UL) ? 1 : 0;
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
                    for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    r.U8(); r.U8(); r.U8(); // to_bp, to_ep, shuffle
                    // [OPCG 신설계] 어택 = idle 말미 attackable 블록, 응답 (idx<<16)|9
                    n = r.U32();
                    int attackIdx = -1;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); r.U8(); r.U8(); r.U8(); r.U8();
                        if (code == LEADER && attackIdx < 0) attackIdx = (int)i;
                    }
                    if (!attacked && attackIdx >= 0) {
                        attacked = true;
                        Console.WriteLine("idle#" + idleCount + ": ATTACK(idle t=9) via index " + attackIdx);
                        RespondI32(duel, (attackIdx << 16) | 9);
                    } else {
                        RespondI32(duel, 7);
                    }
                } else if (lastMsgId == 10) {
                    // [OPCG 신설계] BattleCommand 창: [u8 pl][u32 nAct{... u64 desc u8 mode}]
                    // [u32 nAtk{8B}] [u8 to_m2][u8 to_ep] — 추가 행동 없음 = EP(3)/M2(2)
                    Reader r = new Reader(lastMsg, 1);
                    r.U8();
                    uint n = r.U32();
                    for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); r.U64(); r.U8(); }
                    n = r.U32();
                    for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); r.U8(); }
                    byte toM2 = r.U8(); byte toEp = r.U8();
                    int answer = (toEp != 0) ? 3 : 2;
                    Console.WriteLine("battlecmd -> " + (answer == 3 ? "to_EP" : "to_M2"));
                    RespondI32(duel, answer);
                } else if (lastMsgId == 15) {
                    Reader r = new Reader(lastMsg, 1);
                    r.U8(); r.U8();
                    uint smin = r.U32(); r.U32();
                    uint n = r.U32();
                    int pick = 0;
                    bool allHand = n > 0;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); byte con = r.U8(); byte loc = r.U8(); uint seq = r.U32(); r.U32();
                        if (loc != 0x2) allHand = false;
                        if (code == 880001661 && loc == 0x4 && con == 1) pick = (int)i;
                    }
                    // counter batch window = declinable (min0) all-hand select; other
                    // min0 selects (e.g. "KO up to 1" targets) must still pick
                    if (smin == 0 && allHand) {
                        Console.WriteLine("select_card min0 hand (counter window) -> decline");
                        byte[] none = new byte[8];
                        OCG_DuelSetResponse(duel, none, 8);
                        continue;
                    }
                    Console.WriteLine("select_card n=" + n + " -> " + pick);
                    // 코어 parse_response_cards 규약: [u32 type=0][u32 count][u32 idx...]
                    // (인덱스는 바이트8부터). type1/2는 축약이지만 type0가 정석.
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
                // Quitting right at the KO leaves the awaited ON_KO resolution
                // (activation prompt -> draw) unanswered forever (status=1).
                // Keep pumping through a grace window before ending the loop.
                if (koSeen && koSeenStep < 0) koSeenStep = step;
                if (koSeen && newTurns >= 3 && step >= koSeenStep + 80) break;
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
        // [On K.O.] draw 1: the KO'd character's owner (p1) must draw one card
        // AFTER the KO (a plain "p1x1" would false-match the turn draw)
        bool koDraw = draws.Contains("postko_p1x1");
        Console.WriteLine("draws=" + string.Join(",", draws.ToArray()) + " ko_draw=" + koDraw);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0 && retries == 0
            && attacked && koToTrash && koDraw;
        Console.WriteLine(pass ? "ONKO_DRAW PASS" : "ONKO_DRAW FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[OnKoDrawVerify]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [OnKoDrawVerify]::Run((Resolve-Path -LiteralPath $Repo).Path)
