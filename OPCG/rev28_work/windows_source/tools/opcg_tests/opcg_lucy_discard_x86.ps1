param([Parameter(Mandatory = $true)][string]$Repo)

# OP15-002 루시 리더 E1 실측(유저 제보 "이벤트 버리고 파워 업 안 됨" 재발 방지):
#  【어택 시】/【상대의 어택 시】 패에서 이벤트/스테이지를 원하는 만큼 버리고
#  1장당 이번 배틀 파워 +1000 (기존 부품 DISCARD_HAND_FOR_POWER + 선례
#  c880000367 동일 IR로 교체 후 검증).
#  시나리오: P1(880000634, 5000)이 t2에 P0 루시(5000)를 어택 → 루시 발동 →
#  패(불주먹 이벤트)에서 2장 버림 → 5000+2000=7000 > 5000 → 어택 실패.
#  판정: t3 시점 P0 라이프 4장 유지(버프 실패면 3장) + 트래시 2장.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class LucyDiscardHeadless {
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

    const uint LUCY = 880002304;    // OP15-002
    const uint FIREFIST = 880002322; // OP15-020 불주먹(트리거 없는 이벤트)
    const uint LEADER2 = 880000634;
    const uint FILLER = 880000881;  // 징베(바닐라)

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> probes = new List<string>();
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
                ulong sc = v[6];
                if (sc != 0) {
                    IntPtr buf = Marshal.AllocHGlobal(10); int off = 0;
                    for (int s = 0; s < 4; ++s) {
                        ushort part = (ushort)((sc >> (16 * s)) & 0xffff);
                        if (part == 0) continue;
                        Marshal.WriteInt16(buf, off, (short)part); off += 2;
                    }
                    Marshal.WriteInt16(buf, off, 0); data.setcodes = buf;
                }
            } else { data.type = 1; data.race = 2; }
            Marshal.StructureToPtr(data, output, false);
        } catch (Exception e) { callbackErrors.Add("card reader: " + e); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        var text = Marshal.PtrToStringAnsi(message) ?? "";
        if (type == 0) errors.Add(text); else probes.Add(text);
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

    const string probeLua = @"
local probe = Effect.GlobalEffect()
probe:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
probe:SetCode(EVENT_PHASE_START + PHASE_MAIN1)
probe:SetOperation(function()
    Debug.Message('LUCYPROBE t=' .. Duel.GetTurnCount() ..
        ' life0=' .. Duel.GetFieldGroupCount(0, LOCATION_EXTRA, 0) ..
        ' grave0=' .. Duel.GetFieldGroupCount(0, LOCATION_GRAVE, 0) ..
        ' hand0=' .. Duel.GetFieldGroupCount(0, LOCATION_HAND, 0))
end)
Duel.RegisterEffect(probe, 0)
";

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        LoadDb(Path.Combine(repo, "tools", "opcg_tests", "cdb_dump.csv"));

        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4, flags = 0x2000000000UL,
            team1 = new Player { startingLP = 4, startingDrawCount = 5, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 4, startingDrawCount = 5, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader,
            logHandler = logHandler, cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed"); return 2;
        }
        int newTurns = 0;
        bool attacked = false, lucyAnswered = false, handPicked = false;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var pb = Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "lucy_probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");
            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, LUCY, 1);
            addCards(0, FIREFIST, 30);
            addCards(1, LEADER2, 1);
            addCards(1, FILLER, 30);
            OCG_StartDuel(duel);

            uint lastMsgId = 0;
            byte[] lastMsg = null;
            int st = 2;
            for (int step = 0; step < 60000 && st != 0; ++step) {
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
                    lastMsgId = id;
                    lastMsg = new byte[pl];
                    Array.Copy(all, off, lastMsg, 0, (int)pl);
                    off += (int)pl;
                    if (id == 40) newTurns++;
                }
                if (st == 0) break;
                if (st != 1) continue;
                if (lastMsg == null) break;
                if (lastMsgId == 13) {
                    // YESNO: desc>>20 == 카드코드로 정밀 응답(루시만 YES)
                    ulong desc = BitConverter.ToUInt64(lastMsg, 2);
                    uint code = (uint)(desc >> 20);
                    if (code == LUCY) { lucyAnswered = true; OCG_DuelSetResponse(duel, BitConverter.GetBytes(1), 4); }
                    else OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                }
                else if (lastMsgId == 12) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) {
                    if (!attacked && newTurns >= 2) {
                        // P1 리더로 어택: 7번째(attackable) 리스트에서 LEADER2 탐색
                        int p = 2;
                        Func<int> u32 = delegate { int v = BitConverter.ToInt32(lastMsg, p); p += 4; return v; };
                        int idx = -1;
                        var dbg = new StringBuilder("IDLE" + newTurns + " ");
                        try {
                            for (int list = 0; list < 5; ++list) { int n0 = u32(); dbg.Append("L").Append(list).Append("=").Append(n0).Append(" "); p += n0 * ((list == 2) ? 7 : 10); }
                            int nAct = u32(); dbg.Append("act=").Append(nAct).Append(" "); p += nAct * 19;
                            p += 3;
                            int nAtk = u32(); dbg.Append("atk=").Append(nAtk).Append(":");
                            for (int i = 0; i < nAtk; ++i) {
                                uint code = BitConverter.ToUInt32(lastMsg, p); p += 8;
                                dbg.Append(code).Append(",");
                                if (code == LEADER2 && idx < 0) idx = i;
                            }
                        } catch (Exception ex) { idx = -1; dbg.Append("EX:").Append(ex.Message); }
                        Console.WriteLine(dbg.ToString());
                        if (idx >= 0) {
                            attacked = true;
                            OCG_DuelSetResponse(duel, BitConverter.GetBytes((idx << 16) | 9), 4);
                        } else OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    } else {
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    }
                }
                else if (lastMsgId == 15) {
                    // SELECT_CARD 응답 = [i32 0(cancel아님)][u32 개수][u32 인덱스...]
                    if (lucyAnswered && !handPicked) {
                        handPicked = true;
                        var resp = new byte[16];
                        BitConverter.GetBytes(0).CopyTo(resp, 0);
                        BitConverter.GetBytes(2).CopyTo(resp, 4);
                        BitConverter.GetBytes(0).CopyTo(resp, 8);
                        BitConverter.GetBytes(1).CopyTo(resp, 12);
                        OCG_DuelSetResponse(duel, resp, 16);
                    } else {
                        var resp = new byte[12];
                        BitConverter.GetBytes(0).CopyTo(resp, 0);
                        BitConverter.GetBytes(1).CopyTo(resp, 4);
                        BitConverter.GetBytes(0).CopyTo(resp, 8);
                        OCG_DuelSetResponse(duel, resp, 12);
                    }
                }
                else if (lastMsgId == 26) {
                    // SELECT_UNSELECT 경로로 올 경우: 루시 픽 2회 후 종료
                    OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                }
                else if (lastMsgId == 143) {
                    int count = lastMsg[2];
                    OCG_DuelSetResponse(duel, BitConverter.GetBytes(count - 1), 4);
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
                if (newTurns >= 6) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        var life = new Dictionary<int, int>();
        var grave = new Dictionary<int, int>();
        foreach (var p in probes) {
            if (!p.Contains("LUCYPROBE")) continue;
            Console.WriteLine("PROBE: " + p);
            int t = 0, l = -1, g = -1;
            foreach (var part in p.Split(' ')) {
                if (part.StartsWith("t=")) t = int.Parse(part.Substring(2));
                if (part.StartsWith("life0=")) l = int.Parse(part.Substring(6));
                if (part.StartsWith("grave0=")) g = int.Parse(part.Substring(7));
            }
            if (t > 0) { life[t] = l; grave[t] = g; }
        }
        Console.WriteLine("attacked=" + attacked + " lucy_yes=" + lucyAnswered + " hand_picked=" + handPicked);
        bool lifeHeld = life.ContainsKey(5) && life[5] == 4;
        bool discarded = grave.ContainsKey(5) && grave[5] >= 2;
        Console.WriteLine("life_held=" + lifeHeld + " discarded2=" + discarded);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0
            && attacked && lucyAnswered && handPicked && lifeHeld && discarded;
        Console.WriteLine(pass ? "LUCY_DISCARD PASS" : "LUCY_DISCARD FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [LucyDiscardHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
