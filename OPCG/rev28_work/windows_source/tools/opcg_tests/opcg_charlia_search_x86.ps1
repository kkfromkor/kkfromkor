param([Parameter(Mandatory = $true)][string]$Repo)

# OP13-086 Charlia (880001658) errata verification. The KR official site
# misprinted the search exclusion as "샤를로스 궁" (a name that exists on NO
# card in the pool -> dead filter, even Charlia copies were searchable).
# Corrected to the JP original: self-exclusion ("샤를리아 궁" 이외).
#
# Scenario: P0 plays Charlia on turn 1 (cost 1 = the single turn-1 DON).
# Deck is stacked (PSEUDO_SHUFFLE) so the [On Play] look-3 is exactly
#   [Charlia #2 (880001658), Charloss (880001659), Jinbe filler (880000881)].
# PASS requires the causal pair:
#   1. the private look (MSG_CONFIRM_CARDS on deck cards) contained Charlia #2
#   2. the reveal-select offered ONLY Charloss (self excluded, trait respected)
# plus the full effect trail: Charloss deck->hand, 2 rest cards deck->trash,
# then 1 hand card discarded.
# Run with 32-bit PowerShell (the release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class CharliaSearchVerify {
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

    const uint CHARLIA = 880001658;
    const uint CHARLOSS = 880001659;
    const uint FILLER = 880000881;
    const uint LEADER = 880000634;

    static string standardScripts;
    static string expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> moves = new List<string>();

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
        // OPCG_MODE + PSEUDO_SHUFFLE: the stacked feed order must survive startup
        options.flags = 0x2000000010UL;
        Player pl = new Player(); pl.startingLP = 5; pl.startingDrawCount = 5; pl.drawCountPerTurn = 1;
        options.team1 = pl; options.team2 = pl;
        options.cardReader = cardReader; options.scriptReader = scriptReader;
        options.logHandler = logHandler; options.cardReaderDone = cardReaderDone;
        options.enableUnsafeLibraries = 1;

        IntPtr duel;
        int status = OCG_CreateDuel(out duel, ref options);
        if (status != 0 || duel == IntPtr.Zero) { Console.WriteLine("FAIL OCG_CreateDuel: " + status); return 2; }

        int retries = 0, idleCount = 0, newTurns = 0;
        bool played = false;
        bool lookHadSelf = false, lookHadCharloss = false, lookHadFiller = false;
        bool searchSelectSeen = false, selfOffered = false, charlossOffered = false;
        int searchCandidateCount = -1;
        bool searchedToHand = false, discardSeen = false;
        int restToTrash = 0;

        try {
            string[] boot = new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" };
            foreach (string name in boot)
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    NewCard card = new NewCard();
                    card.team = (byte)p; card.duelist = 0; card.code = code; card.con = (byte)p;
                    card.loc = 1; card.seq = 0; card.pos = 8;
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            // last fed = deck top = first consumed. Top-down layout:
            //   pos1 Charlia#1 (opening hand), pos2-5 filler,
            //   pos6-9 filler (life, leader level 4), pos10-12 = the look trio
            //   [Charlia#2, Charloss, filler], pos13+ filler body.
            addCards(0, LEADER, 1);
            addCards(0, FILLER, 20);      // deck body (bottom)
            addCards(0, FILLER, 1);       // pos12 look #3
            addCards(0, CHARLOSS, 1);     // pos11 look #2
            addCards(0, CHARLIA, 1);      // pos10 look #1 (the self copy)
            addCards(0, FILLER, 8);       // pos9..pos2 (life 4 + hand filler 4)
            addCards(0, CHARLIA, 1);      // pos1  (top -> opening hand)
            addCards(1, LEADER, 1);
            addCards(1, FILLER, 30);
            OCG_StartDuel(duel);

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
                    else if (msgId == 31) {
                        // MSG_CONFIRM_CARDS: the private look. Only deck-located
                        // confirms count (skips the reveal-to-opponent confirm of
                        // the picked card, which fires while still in deck too --
                        // a 1-card confirm can never set all three flags anyway).
                        Reader r = new Reader(payload, 1);
                        r.U8();
                        uint n = r.U32();
                        bool self = false, closs = false, fill = false;
                        List<string> codes = new List<string>();
                        for (uint i = 0; i < n; ++i) {
                            uint code = r.U32(); byte con = r.U8(); byte loc = r.U8(); r.U32();
                            codes.Add(code + "@0x" + loc.ToString("x"));
                            if (loc != 0x01) continue;
                            if (code == CHARLIA) self = true;
                            if (code == CHARLOSS) closs = true;
                            if (code == FILLER) fill = true;
                        }
                        Console.WriteLine("step " + step + ": CONFIRM n=" + n + " [" + string.Join(",", codes.ToArray()) + "]");
                        if (n == 3 && self && closs && fill) { lookHadSelf = true; lookHadCharloss = true; lookHadFiller = true; }
                    }
                    else if (msgId == 50) {
                        Reader r = new Reader(payload, 1);
                        uint code = r.U32();
                        byte pcon = r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        byte ccon = r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if (code == CHARLIA || code == CHARLOSS || code == FILLER) {
                            string s = code + ": 0x" + ploc.ToString("x") + "(p" + pcon + ")->0x" + cloc.ToString("x") + "(p" + ccon + ")";
                            moves.Add(s);
                            if (ploc != cloc) Console.WriteLine("step " + step + ": MOVE " + s);
                            if (code == CHARLOSS && ploc == 0x01 && cloc == 0x02 && ccon == 0) searchedToHand = true;
                            if (ploc == 0x01 && cloc == 0x10 && pcon == 0) restToTrash++;
                            if (ploc == 0x02 && cloc == 0x10 && pcon == 0) discardSeen = true;
                        }
                    }
                    else if (msgId == 90) {
                        Console.WriteLine("step " + step + ": DRAW p" + payload[1] + " x" + BitConverter.ToUInt32(payload, 2));
                    }
                }
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL awaiting with no message"); break; }

                if (lastMsgId == 13 || lastMsgId == 12) {
                    // only expected yes/no here is the opening redraw prompt: keep the stacked hand
                    Reader r = new Reader(lastMsg, 1);
                    byte pl_ = r.U8();
                    ulong desc = r.U64();
                    Console.WriteLine("YESNO player=" + pl_ + " desc=" + desc + " -> 0");
                    RespondI32(duel, 0);
                } else if (lastMsgId == 14) { RespondI32(duel, 0); }
                else if (lastMsgId == 16) { RespondI32(duel, -1); }
                else if (lastMsgId == 11) {
                    idleCount++;
                    Reader r = new Reader(lastMsg, 1);
                    r.U8();
                    uint n;
                    int playIdx = -1;
                    n = r.U32();
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); r.U8(); r.U8(); r.U32();
                        if (code == CHARLIA && playIdx < 0) playIdx = (int)i;
                    }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U8(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    n = r.U32(); for (uint i = 0; i < n; ++i) { r.U32(); r.U8(); r.U8(); r.U32(); }
                    if (!played && playIdx >= 0) {
                        played = true;
                        Console.WriteLine("idle#" + idleCount + ": PLAY Charlia via index " + playIdx);
                        RespondI32(duel, (playIdx << 16) | 0);
                    } else {
                        RespondI32(duel, 7);
                    }
                } else if (lastMsgId == 15) {
                    Reader r = new Reader(lastMsg, 1);
                    r.U8(); r.U8();
                    uint min = r.U32(); uint max = r.U32();
                    uint n = r.U32();
                    uint[] codes = new uint[n];
                    byte[] locs = new byte[n];
                    bool anyDeck = false;
                    for (uint i = 0; i < n; ++i) {
                        codes[i] = r.U32(); r.U8(); locs[i] = r.U8(); r.U32(); r.U32();
                        if (locs[i] == 0x01) anyDeck = true;
                    }
                    Console.WriteLine("select_card min=" + min + " max=" + max + " n=" + n +
                        " codes=[" + string.Join(",", Array.ConvertAll(codes, x => x.ToString())) + "]");
                    List<uint> picks = new List<uint>();
                    if (anyDeck && played && !searchSelectSeen) {
                        // THE search reveal-select: assert the filter shape
                        searchSelectSeen = true;
                        searchCandidateCount = (int)n;
                        for (uint i = 0; i < n; ++i) {
                            if (codes[i] == CHARLIA) selfOffered = true;
                            if (codes[i] == CHARLOSS) { charlossOffered = true; picks.Add(i); }
                        }
                    } else {
                        for (uint i = 0; i < Math.Min(Math.Max(min, (uint)(min == 0 ? 0 : min)), n); ++i) picks.Add(i);
                        if (min > 0 && picks.Count == 0 && n > 0) picks.Add(0);
                    }
                    byte[] resp = new byte[8 + 4 * picks.Count];
                    Array.Copy(BitConverter.GetBytes((int)0), 0, resp, 0, 4);
                    Array.Copy(BitConverter.GetBytes((uint)picks.Count), 0, resp, 4, 4);
                    for (int i = 0; i < picks.Count; ++i)
                        Array.Copy(BitConverter.GetBytes(picks[i]), 0, resp, 8 + 4 * i, 4);
                    OCG_DuelSetResponse(duel, resp, (uint)resp.Length);
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
                if (searchSelectSeen && discardSeen && restToTrash >= 2) break;
                if (newTurns >= 2) break;
            }
            Console.WriteLine("loop done: steps=" + step + " status=" + status + " idles=" + idleCount + " turns=" + newTurns);
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("--- results ---");
        Console.WriteLine("retries=" + retries + " script_errors=" + errors.Count + " callback_failures=" + callbackErrors.Count);
        foreach (string error in callbackErrors) Console.WriteLine("CALLBACK: " + error);
        foreach (string error in errors) Console.WriteLine("SCRIPT: " + error);
        Console.WriteLine("moves=" + string.Join(" | ", moves.ToArray()));
        bool lookComplete = lookHadSelf && lookHadCharloss && lookHadFiller;
        Console.WriteLine("played=" + played + " look_complete=" + lookComplete);
        Console.WriteLine("search_select_seen=" + searchSelectSeen + " candidates=" + searchCandidateCount +
            " self_offered=" + selfOffered + " charloss_offered=" + charlossOffered);
        Console.WriteLine("searched_to_hand=" + searchedToHand + " rest_to_trash=" + restToTrash + " discard_seen=" + discardSeen);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0 && retries == 0
            && played && lookComplete
            && searchSelectSeen && searchCandidateCount == 1 && !selfOffered && charlossOffered
            && searchedToHand && restToTrash == 2 && discardSeen;
        Console.WriteLine(pass ? "CHARLIA_SEARCH PASS" : "CHARLIA_SEARCH FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[CharliaSearchVerify]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [CharliaSearchVerify]::Run((Resolve-Path -LiteralPath $Repo).Path)
