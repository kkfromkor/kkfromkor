param([Parameter(Mandatory = $true)][string]$Repo)

# OP15-022 브룩 리더 유예 덱아웃 실측(유저 리플레이 제보 2026-07-29):
#  룰 텍스트 = "덱이 0장이어도 패배하지 않으며, 덱이 0장이 된 턴 종료 시에 패배".
#  종전 구현이 EVENT_PHASE+PHASE_END 연속효과라 PhaseEvent 수집 루프에 매번
#  다시 잡혀 SELECT_CHAIN 무한 공회전(실전에서는 항복으로만 탈출) — 발화를
#  EVENT_TURN_END(턴 경계 1회, 즉석 해결)로 이관한 수리를 검증한다.
#  시나리오: P0 브룩 리더 + 덱 12장(개시 5드로 + 라이프 4장 장전 후 잔여 3).
#   t1: 브룩 E2 기동(덱 위 4장 트래시 = 잔여 3장 전부) → 덱 0, 즉사하지 않고
#       아이들이 돌아와야 함(유예 확인) → 턴 종료 선언
#   턴 종료 시: P0 패배 = MSG_WIN(승자 P1) — 무한 루프 없이 유한 스텝 내 도착.
#  판정: win_player==1 AND 턴2 미도달 AND 턴 종료 선언 후 승리 AND 오류 0.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class BrookDeckoutHeadless {
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

    const uint BROOK = 880002324;   // OP15-022 리더
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
    Debug.Message('BROOKPROBE t=' .. Duel.GetTurnCount() ..
        ' deck0=' .. Duel.GetFieldGroupCount(0, LOCATION_DECK, 0) ..
        ' grave0=' .. Duel.GetFieldGroupCount(0, LOCATION_GRAVE, 0))
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
        int newTurns = 0, winPlayer = -1, winReason = -1, winTurn = -1;
        bool milled = false, idleAfterMill = false, endedTurn = false;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var pb = Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "brook_probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");
            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, BROOK, 1);
            addCards(0, FILLER, 12);
            addCards(1, LEADER2, 1);
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
                    lastMsgId = id;
                    lastMsg = new byte[pl];
                    Array.Copy(all, off, lastMsg, 0, (int)pl);
                    off += (int)pl;
                    if (id == 40) newTurns++;
                    if (id == 5 && winPlayer < 0) {
                        winPlayer = lastMsg[1];
                        winReason = pl >= 3 ? lastMsg[2] : -1;
                        winTurn = newTurns;
                        Console.WriteLine("MSG_WIN player=" + winPlayer + " reason=" + winReason
                            + " turn=" + winTurn + " ended_turn=" + endedTurn);
                    }
                }
                // 승리 선언 후에도 헤드리스 코어는 턴을 계속 돌린다(세션 종료는
                // 서버 몫) — 판정에 필요한 건 다 모였으니 여기서 끊는다
                if (winPlayer >= 0) break;
                if (st == 0) break;
                if (st != 1) continue;
                if (lastMsg == null) break;
                if (lastMsgId == 13) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 12) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) {
                    int p = 2;
                    int actBrook = -1;
                    var dbg = new StringBuilder("IDLE" + newTurns + " ");
                    try {
                        for (int list = 0; list < 5; ++list) {
                            int n0 = BitConverter.ToInt32(lastMsg, p); p += 4;
                            dbg.Append("L").Append(list).Append("=").Append(n0).Append(" ");
                            p += n0 * ((list == 2) ? 7 : 10);
                        }
                        int nAct = BitConverter.ToInt32(lastMsg, p); p += 4;
                        dbg.Append("act=").Append(nAct).Append(":");
                        for (int i = 0; i < nAct; ++i) {
                            uint code = BitConverter.ToUInt32(lastMsg, p); p += 19;
                            dbg.Append(code).Append(",");
                            if (code == BROOK && actBrook < 0) actBrook = i;
                        }
                    } catch (Exception ex) { dbg.Append("EX:").Append(ex.Message); }
                    if (newTurns == 1) Console.WriteLine(dbg.ToString());
                    if (newTurns == 1 && milled) idleAfterMill = true;
                    if (newTurns == 1 && !milled && actBrook >= 0) {
                        milled = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((actBrook << 16) | 5), 4);
                    } else {
                        if (newTurns == 1 && milled) endedTurn = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    }
                }
                else if (lastMsgId == 15) {
                    // [i32 0][u32 개수][u32 인덱스...] — 최소 요구 장수만 응답(0이면 취소)
                    uint mn = BitConverter.ToUInt32(lastMsg, 3);
                    var resp = new byte[8 + 4 * mn];
                    BitConverter.GetBytes(0).CopyTo(resp, 0);
                    BitConverter.GetBytes(mn).CopyTo(resp, 4);
                    for (uint i = 0; i < mn; ++i) BitConverter.GetBytes(i).CopyTo(resp, 8 + 4 * (int)i);
                    OCG_DuelSetResponse(duel, resp, (uint)resp.Length);
                }
                else if (lastMsgId == 26) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
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
                if (newTurns >= 3) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        foreach (var p in probes) if (p.Contains("BROOKPROBE")) Console.WriteLine("PROBE: " + p);
        Console.WriteLine("milled=" + milled + " idle_after_mill=" + idleAfterMill
            + " ended_turn=" + endedTurn + " win_player=" + winPlayer + " win_turn=" + winTurn);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0
            && milled && idleAfterMill && endedTurn && winPlayer == 1 && winTurn == 1;
        Console.WriteLine(pass ? "BROOK_DECKOUT PASS" : "BROOK_DECKOUT FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [BrookDeckoutHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
