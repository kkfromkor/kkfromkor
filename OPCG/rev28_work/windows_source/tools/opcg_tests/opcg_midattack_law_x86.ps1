param([Parameter(Mandatory = $true)][string]$Repo)

# Mid-attack play audit with OP13-114 S-Snake (880001686):
#   [Trigger] discard 1: play this card  -> enters MZONE during the attack
#   [On Play] flip own top life face-up: opponent character -2000 this turn
# The ON_PLAY is engine-queued and must resolve after the attack chain ends
# (rule 8-6-2). Verdict reads the -2000 on P0's character at turn-3 end phase.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class St17LawVerify {
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

    const uint SNAKE = 880002084;  // ST17-002 Trafalgar Law
    const uint LEADER0 = 880000183;  // OP01-060 Doflamingo leader
    const uint LEADER1 = 880000634;
    const uint FILLER = 880000881;
    const ulong TRIGGER_DESC = ((ulong)879999998 << 20) + 1;

    static string standardScripts;
    static string expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> snakeMoves = new List<string>();

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
        else {
            probes.Add("type" + type + ": " + text);
            Console.WriteLine("  [live] " + text);
        }
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
        bool attacked = false;

        try {
            string[] boot = new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" };
            foreach (string name in boot)
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            string probeLua =
                "local place = Effect.GlobalEffect()\n" +
                "place:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "place:SetCode(EVENT_PHASE_START + PHASE_MAIN1)\n" +
                "place:SetOperation(function()\n" +
                "  if not opcg._probe_placed then\n" +
                "    opcg._probe_placed = true\n" +
                "    local card = Duel.GetMatchingGroup(function(c)\n" +
                "      return c:GetOriginalCode() == 880000881 end, 0, LOCATION_DECK, 0, nil):GetFirst()\n" +
                "    if card then\n" +
                "      Duel.MoveToField(card, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true)\n" +
                "      Debug.Message('PROBE placed p0 char seq=' .. card:GetSequence())\n" +
                "    end\n" +
                "  end\n" +
                "  if Duel.GetTurnCount() == 3 and not opcg._don_given then\n" +
                "    opcg._don_given = true\n" +
                "    local leader = Duel.GetFieldCard(0, LOCATION_MZONE, 5)\n" +
                "    if leader and opcg.GiveDon then\n" +
                "      local given = opcg.GiveDon(0, leader, 2, 'ACTIVE')\n" +
                "      Debug.Message('PROBE don_given=' .. tostring(given))\n" +
                "    end\n" +
                "  end\n" +
                "end)\n" +
                "Duel.RegisterEffect(place, 0)\n" +
                "local chainwatch = Effect.GlobalEffect()\n" +
                "chainwatch:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "chainwatch:SetCode(EVENT_CHAIN_END)\n" +
                "chainwatch:SetOperation(function()\n" +
                "  if Duel.GetTurnCount() ~= 3 then return end\n" +
                "  local char = Duel.GetMatchingGroup(function(c)\n" +
                "    return c:GetOriginalCode() == 880000881 end, 0, LOCATION_MZONE, 0, nil):GetFirst()\n" +
                "  Debug.Message('CHAINEND atk=' .. tostring(char and char:GetAttack() or 'gone'))\n" +
                "end)\n" +
                "Duel.RegisterEffect(chainwatch, 0)\n" +
                "local watch = Effect.GlobalEffect()\n" +
                "watch:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
                "watch:SetCode(EVENT_PHASE_START + PHASE_END)\n" +
                "watch:SetOperation(function()\n" +
                "  local turn = Duel.GetTurnCount()\n" +
                "  if turn ~= 3 then return end\n" +
                "  local char = Duel.GetMatchingGroup(function(c)\n" +
                "    return c:GetOriginalCode() == 880000881 end, 0, LOCATION_MZONE, 0, nil):GetFirst()\n" +
                "  local snake = Duel.GetMatchingGroup(function(c)\n" +
                "    return c:GetOriginalCode() == 880001686 end, 1, LOCATION_MZONE, 0, nil):GetFirst()\n" +
                "  Debug.Message('VERDICT p0_char_power=' .. tostring(char and char:GetAttack() or 'gone')\n" +
                "    .. ' snake_on_field=' .. tostring(snake ~= nil)\n" +
                "    .. ' queue_pending=' .. tostring(opcg.effect_queue and opcg.effect_queue.pending_count() or -1)\n" +
                "    .. ' direct_pending=' .. tostring(opcg.effect_queue and opcg.effect_queue.direct_pending_count() or -1))\n" +
                "end)\n" +
                "Duel.RegisterEffect(watch, 0)\n";
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
            addCards(0, LEADER0, 1);
            addCards(0, FILLER, 1);   // unique cost fodder the probe pulls out
            addCards(0, SNAKE, 44);   // rest of the deck is all Law: any top works
            addCards(1, LEADER1, 1);
            addCards(1, FILLER, 45);
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
                    else if (msgId == 41) Console.WriteLine("step " + step + ": NEW_PHASE 0x" + BitConverter.ToUInt16(payload, 1).ToString("x"));
                    else if (msgId == 5) Console.WriteLine("step " + step + ": MSG_WIN player=" + payload[1] + " reason=" + payload[2]);
                    else if (msgId == 53) {
                        Reader r = new Reader(payload, 1);
                        uint code = r.U32(); byte cc = r.U8(); byte cl = r.U8(); byte cs = r.U8();
                        byte pp = r.U8(); byte cp = r.U8();
                        Console.WriteLine("step " + step + ": POS code=" + code + " con=" + cc +
                            " loc=0x" + cl.ToString("x") + " " + pp.ToString("x") + "->" + cp.ToString("x"));
                    }
                    else if (msgId == 50) {
                        Reader r = new Reader(payload, 1);
                        uint code = r.U32();
                        byte pcon = r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        byte ccon = r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if ((code == SNAKE || code == FILLER) && (ploc != cloc || pcon != ccon)) {
                            string s = code + ": 0x" + ploc.ToString("x") + "->0x" + cloc.ToString("x");
                            snakeMoves.Add(s);
                            Console.WriteLine("step " + step + ": SNAKE MOVE " + s);
                        }
                    }
                }
                if (status == 0) break;
                if (status != 1) continue;
                if (lastMsg == null) { Console.WriteLine("FAIL awaiting with no message"); break; }

                if (lastMsgId == 13 || lastMsgId == 12) {
                    Reader r = new Reader(lastMsg, 1);
                    byte pl_ = r.U8();
                    ulong desc = r.U64();
                    int answer = (lastMsgId == 12 || desc == TRIGGER_DESC || desc == 222) ? 1 : 0;
                    Console.WriteLine((lastMsgId == 12 ? "EFFECTYN" : "YESNO") + " player=" + pl_ + " desc=" + desc + " -> " + answer);
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
                        if (code == LEADER0 && desc == 1157 && attackIdx < 0) attackIdx = (int)i;
                    }
                    if (!attacked && attackIdx >= 0 && newTurns >= 3) {
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
                    string detail = "";
                    int pick = 0;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); byte con = r.U8(); byte loc = r.U8(); uint seq = r.U32(); r.U32();
                        detail += "[" + i + "]" + code + "@0x" + loc.ToString("x") + " ";
                        if (loc == 0x4 && seq == 5 && con == 1) pick = (int)i;
                    }
                    Console.WriteLine("select_card n=" + n + " {" + detail + "} -> " + pick);
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
                if (newTurns >= 4) break;
            }
            Console.WriteLine("loop done: steps=" + step + " status=" + status + " idles=" + idleCount + " turns=" + newTurns);
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("--- results ---");
        Console.WriteLine("retries=" + retries + " script_errors=" + errors.Count + " callback_failures=" + callbackErrors.Count);
        foreach (string error in callbackErrors) Console.WriteLine("CALLBACK: " + error);
        foreach (string error in errors) Console.WriteLine("SCRIPT: " + error);
        foreach (string probe in probes) Console.WriteLine("LOG " + probe);
        Console.WriteLine("snake_moves=" + string.Join(" | ", snakeMoves.ToArray()));
        bool played = false;
        int returns = 0, lastReturnIdx = -1, damageIdx = -1;
        for (int k = 0; k < snakeMoves.Count; ++k) {
            string s = snakeMoves[k];
            if (s.StartsWith("880002084") && s.Contains("0x1->0x4")) played = true;
            if (s.Contains("0x4->0x2")) { returns++; lastReturnIdx = k; }
            if (s.Contains("0x40->0x2")) damageIdx = k;
        }
        // rule 8-6-3: the on-play must fully resolve BEFORE the damage step
        bool beforeDamage = returns >= 2 && damageIdx > lastReturnIdx;
        bool queueDrained = false;
        foreach (string probe in probes)
            if (probe.Contains("queue_pending=0") && probe.Contains("direct_pending=0")) queueDrained = true;
        Console.WriteLine("law_played_from_deck=" + played + " returns_to_hand=" + returns +
            " onplay_before_damage=" + beforeDamage + " queue_drained=" + queueDrained);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0 && retries == 0
            && attacked && played && returns >= 2 && beforeDamage && queueDrained;
        Console.WriteLine(pass ? "ST17_LAW PASS" : "ST17_LAW FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
[St17LawVerify]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [St17LawVerify]::Run((Resolve-Path -LiteralPath $Repo).Path)
