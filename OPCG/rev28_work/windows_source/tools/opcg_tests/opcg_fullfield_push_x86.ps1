param([Parameter(Mandatory = $true)][string]$Repo)

# Full character area (5) + play a 6th: the official rule trashes one of your
# characters to make room, and that trash is a RULE placement, NOT a K.O.
# Setup: P0 field = OP13-089 Warcury (880001661, [On K.O.] draw 1) + 4 fillers,
# hand has Charlia (880001658, cost 1). Turn 1: play Charlia (blocked entirely
# before the fix), pick Warcury as the push-out victim.
# PASS: Charlia listed as summonable on a full field; Warcury MZONE->TRASH;
# Charlia HAND->MZONE; and NO p0 draw after the push (K.O. trigger silent).
# Run with 32-bit PowerShell (the release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class FullFieldPushVerify {
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

    const uint CHARLIA = 880001658;
    const uint WARCURY = 880001661;
    const uint FILLER = 880000881;
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

    class Reader {
        public byte[] buf; public int pos;
        public Reader(byte[] b, int p) { buf = b; pos = p; }
        public byte U8() { byte v = buf[pos]; pos += 1; return v; }
        public uint U32() { uint v = BitConverter.ToUInt32(buf, pos); pos += 4; return v; }
        public ulong U64() { ulong v = BitConverter.ToUInt64(buf, pos); pos += 8; return v; }
    }

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        LoadDb(Path.Combine(repo, "tools", "opcg_tests", "cdb_dump.csv"));

        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4, flags = 0x2000000010UL,
            team1 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader,
            logHandler = logHandler, cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed"); return 2;
        }

        bool listedOnFullField = false, played = false, pushedToTrash = false;
        bool koMisfire = false;
        int newTurns = 0;

        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);

            // full P0 board: Warcury ([On K.O.] draw 1) + 4 fillers, seq 0-4
            var w = new NewCard { team = 0, duelist = 0, code = WARCURY, con = 0, loc = 0x4, seq = 0, pos = 0x1 };
            OCG_DuelNewCard(duel, ref w);
            for (uint s = 1; s <= 4; ++s) {
                var f = new NewCard { team = 0, duelist = 0, code = FILLER, con = 0, loc = 0x4, seq = s, pos = 0x1 };
                OCG_DuelNewCard(duel, ref f);
            }
            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, LEADER, 1);
            addCards(0, FILLER, 25);
            addCards(0, CHARLIA, 1);   // fed last = deck top = opening hand
            addCards(1, LEADER, 1);
            addCards(1, FILLER, 30);
            OCG_StartDuel(duel);

            uint lastMsgId = 0;
            byte[] lastMsg = null;
            int st = 2;
            for (int step = 0; step < 20000 && st != 0; ++step) {
                st = OCG_DuelProcess(duel);
                uint length;
                IntPtr ptr = OCG_DuelGetMessage(duel, out length);
                var all = new byte[length];
                if (length > 0) Marshal.Copy(ptr, all, 0, (int)length);
                int off = 0;
                while (off + 4 <= all.Length) {
                    uint pl = BitConverter.ToUInt32(all, off); off += 4;
                    if (pl == 0 || off + pl > all.Length) break;
                    byte id = all[off];
                    lastMsg = new byte[pl];
                    Array.Copy(all, off, lastMsg, 0, (int)pl);
                    off += (int)pl;
                    lastMsgId = id;
                    if (id == 40) newTurns++;
                    else if (id == 50) {
                        var r = new Reader(lastMsg, 1);
                        uint code = r.U32();
                        byte pcon = r.U8(); byte ploc = r.U8(); r.U32(); r.U32();
                        byte ccon = r.U8(); byte cloc = r.U8(); r.U32(); r.U32();
                        if (code == WARCURY && ploc == 0x4 && cloc == 0x10) {
                            pushedToTrash = true;
                            Console.WriteLine("step " + step + ": PUSH Warcury MZONE->TRASH");
                        }
                        if (code == CHARLIA && ploc == 0x2 && cloc == 0x4) {
                            played = true;
                            Console.WriteLine("step " + step + ": PLAY Charlia HAND->MZONE");
                        }
                    }
                    else if (id == 90) {
                        byte dp = lastMsg[1];
                        uint dc = BitConverter.ToUInt32(lastMsg, 2);
                        Console.WriteLine("step " + step + ": DRAW p" + dp + " x" + dc);
                        if (pushedToTrash && dp == 0) koMisfire = true; // KO trigger must stay silent
                    }
                }
                if (st == 0) break;
                if (st != 1) continue;
                if (lastMsg == null) break;

                if (lastMsgId == 13 || lastMsgId == 12) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) {
                    var r = new Reader(lastMsg, 1);
                    r.U8();
                    uint n = r.U32();
                    int playIdx = -1;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); r.U8(); r.U8(); r.U32();
                        if (code == CHARLIA && playIdx < 0) playIdx = (int)i;
                    }
                    if (!played && playIdx >= 0) {
                        listedOnFullField = true;
                        Console.WriteLine("idle: Charlia summonable on FULL field, index " + playIdx);
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((playIdx << 16) | 0), 4);
                    } else {
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    }
                }
                else if (lastMsgId == 15) {
                    var r = new Reader(lastMsg, 1);
                    r.U8(); r.U8();
                    uint min = r.U32(); r.U32();
                    uint n = r.U32();
                    int pick = 0;
                    for (uint i = 0; i < n; ++i) {
                        uint code = r.U32(); r.U8(); byte loc = r.U8(); r.U32(); r.U32();
                        if (code == WARCURY && loc == 0x4) pick = (int)i;
                    }
                    Console.WriteLine("select_card n=" + n + " min=" + min + " -> pick " + pick + " (Warcury)");
                    var resp = new byte[12];
                    Array.Copy(BitConverter.GetBytes((int)0), 0, resp, 0, 4);
                    Array.Copy(BitConverter.GetBytes((uint)1), 0, resp, 4, 4);
                    Array.Copy(BitConverter.GetBytes((uint)pick), 0, resp, 8, 4);
                    OCG_DuelSetResponse(duel, resp, 12);
                }
                else if (lastMsgId == 19) OCG_DuelSetResponse(duel, BitConverter.GetBytes(1), 4);
                else if (lastMsgId == 18 || lastMsgId == 24) {
                    byte player = lastMsg[1];
                    uint flag = BitConverter.ToUInt32(lastMsg, 3);
                    uint available = ~flag;
                    byte[] resp = null;
                    for (int bit = 0; bit < 16 && resp == null; ++bit) {
                        if ((available & (1u << bit)) == 0) continue;
                        byte loc = (byte)((bit >= 8) ? 8 : 4);
                        byte seq = (byte)((bit >= 8) ? (bit - 8) : bit);
                        resp = new byte[] { player, loc, seq };
                    }
                    if (resp == null) { Console.WriteLine("select_place: no free zone"); break; }
                    OCG_DuelSetResponse(duel, resp, (uint)resp.Length);
                }
                else { Console.WriteLine("unexpected awaited msg id=" + lastMsgId); break; }
                if (played && pushedToTrash && newTurns >= 2) break;
                if (newTurns >= 3) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        Console.WriteLine("listed_on_full_field=" + listedOnFullField + " played=" + played
            + " pushed_to_trash=" + pushedToTrash + " ko_misfire=" + koMisfire);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0
            && listedOnFullField && played && pushedToTrash && !koMisfire;
        Console.WriteLine(pass ? "FULLFIELD_PUSH PASS" : "FULLFIELD_PUSH FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [FullFieldPushVerify]::Run((Resolve-Path -LiteralPath $Repo).Path)
