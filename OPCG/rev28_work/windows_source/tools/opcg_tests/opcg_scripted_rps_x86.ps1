param([Parameter(Mandatory = $true)][string]$Repo)

# Scripted rock-paper-scissors (DUEL_OPCG_SCRIPTED_RPS, bit 38): leaders enter
# REVEALED (리더 보고 시작), both players throw the NATIVE Duel.RockPaperScissors
# (MSG 132, real client hand dialog), the winner picks first/second,
# and Duel.SetTurnPlayer applies it. Leaders never sit face-down.
# Drives: P0=rock(2), P1=scissors(1) -> P0 wins -> picks 후공(1) -> P1 first.
# Asserts: leaders placed face-up from the start (no flips at all);
# turn 1 belongs to P1. Run with 32-bit PowerShell.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgScriptedRpsHeadless {
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

    const uint LEADER = 880000634;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static void LoadDb(string csv) {
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
        if (name.StartsWith("c999")) {
            var stub = Encoding.UTF8.GetBytes("local s,id=GetID()\nfunction s.initial_effect(c)\nend\n");
            return OCG_LoadScript(duel, stub, (uint)stub.Length, name);
        }
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

    static int optionCount = 0;
    static int rpsCount = 0;
    static int revealsBeforeOptions = 0;
    static int revealsAfterOptions = 0;
    static int facedownPlacements = 0;
    static int faceupPlacements = 0;
    static int firstTurnPlayer = -1;
    static byte lastMsgId = 0;
    static byte[] lastSelectPlace;
    // MSG_SELECT_PLACE payload: type u8, player u8, count u8, flag u32
    // (set bit = disabled). self: mzone bits 0-6, szone bits 8-15.
    static byte[] AnswerSelectPlace() {
        var player = lastSelectPlace[1];
        var flag = BitConverter.ToUInt32(lastSelectPlace, 3);
        for (int bit = 0; bit < 7; ++bit)
            if ((flag & (1u << bit)) == 0)
                return new byte[] { player, 0x04, (byte)bit };
        for (int bit = 8; bit < 16; ++bit)
            if ((flag & (1u << bit)) == 0)
                return new byte[] { player, 0x08, (byte)(bit - 8) };
        return new byte[] { player, 0x04, 0 };
    }

    static void Drain(IntPtr duel) {
        uint len; var buf = OCG_DuelGetMessage(duel, out len);
        if (buf == IntPtr.Zero || len == 0) return;
        var bytes = new byte[len]; Marshal.Copy(buf, bytes, 0, (int)len);
        int off = 0;
        while (off + 4 <= bytes.Length) {
            uint pl = BitConverter.ToUInt32(bytes, off); off += 4;
            if (pl == 0 || off + pl > bytes.Length) break;
            byte id = bytes[off];
            lastMsgId = id;
            if (id == 18) {
                lastSelectPlace = new byte[pl];
                Array.Copy(bytes, off, lastSelectPlace, 0, (int)pl);
            } else if (id == 50 && pl >= 25) { // MSG_MOVE: leader arriving face-down?
                uint code = BitConverter.ToUInt32(bytes, off + 1);
                byte cloc = bytes[off + 16];
                int cpos = BitConverter.ToInt32(bytes, off + 21);
                if (code == LEADER && cloc == 0x4) { if ((cpos & 0x2) != 0) facedownPlacements++; else faceupPlacements++; }
            } else if (id == 53 && pl >= 10) { // MSG_POS_CHANGE
                uint code = BitConverter.ToUInt32(bytes, off + 1);
                byte prev = bytes[off + 8], cur = bytes[off + 9];
                if (code == LEADER && (prev & 0x2) != 0 && (cur & 0x1) != 0) {
                    if (rpsCount < 2 || optionCount < 1) revealsBeforeOptions++; else revealsAfterOptions++;
                }
            } else if (id == 40 && firstTurnPlayer < 0) { // MSG_NEW_TURN
                firstTurnPlayer = bytes[off + 1];
            }
            off += (int)pl;
        }
    }

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        LoadDb(Path.Combine(repo, "tools", "opcg_tests", "cdb_dump.csv"));

        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4,
            flags = 0x6000000000UL, // OPCG + SCRIPTED_RPS
            team1 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader,
            logHandler = logHandler, cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed"); return 2;
        }
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            for (int p = 0; p < 2; ++p) {
                var leader = new NewCard { team = (byte)p, duelist = 0, code = LEADER, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                OCG_DuelNewCard(duel, ref leader);
                for (uint k = 0; k < 12; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = 999000001 + k, con = (byte)p, loc = 1, seq = 1 + k, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            }
            OCG_StartDuel(duel);
            int st = 2;
            for (int step = 0; step < 3000 && st != 0 && firstTurnPlayer < 0; ++step) {
                st = OCG_DuelProcess(duel); Drain(duel);
                if (st == 1) {
                    if (lastMsgId == 132) { // native ROCK_PAPER_SCISSORS: P0 rock(2), P1 scissors(1) -> P0 wins
                        int answer = (rpsCount == 0) ? 2 : 1;
                        ++rpsCount;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(answer), 4);
                    } else if (lastMsgId == 14) { // SELECT_OPTION: winner (P0) picks 후공
                        ++optionCount;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(1), 4);
                    } else if (lastMsgId == 13 || lastMsgId == 12) {
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                    } else if (lastMsgId == 18 && lastSelectPlace != null) {
                        var answer = AnswerSelectPlace();
                        OCG_DuelSetResponse(duel, answer, (uint)answer.Length);
                    } else {
                        break; // first unhandled request past turn start ends the probe
                    }
                    st = 2;
                }
            }
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("rps=" + rpsCount + " options=" + optionCount
            + " fd_placements=" + facedownPlacements + " fu_placements=" + faceupPlacements
            + " reveals_before=" + revealsBeforeOptions
            + " reveals_after=" + revealsAfterOptions
            + " first_turn_player=" + firstTurnPlayer);
        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0
            && rpsCount == 2 && optionCount == 1 && facedownPlacements == 0 && faceupPlacements == 2
            && revealsBeforeOptions == 0 && revealsAfterOptions == 0
            && firstTurnPlayer == 1;
        Console.WriteLine(pass ? "SCRIPTED_RPS PASS" : "SCRIPTED_RPS FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgScriptedRpsHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
