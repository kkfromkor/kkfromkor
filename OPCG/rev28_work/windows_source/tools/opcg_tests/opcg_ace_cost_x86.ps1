param([Parameter(Mandatory = $true)][string]$Repo)

# OP15-021 「지켜봐! 에이스!!!」 패 코스트 감소 실측(유저 제보 "깡통"):
#  정적 효과 = "패의 이 카드는 자신의 트래시에 이벤트가 4장 이상 있는 경우,
#  코스트 -3" — 이벤트(비몬스터 프레임)는 코어 get_level이 효과 조회 전에
#  0을 반환(card.cpp:997)해 EFFECT_UPDATE_LEVEL 채널이 통째로 무효였다.
#  수리 = 상주 등록부가 전용 채널(EFFECT_MODIFY_HAND_COST)을 쌍둥이 발신
#  + opcg.GetCost 비몬스터 폴백이 그걸 합산.
#  시나리오: P0 루시 리더, 트래시에 이벤트 3장 사전 적재.
#   t1(둥1, 트래시3): 021은 코스트 4 그대로 → 발동 목록에 없어야 함(음성)
#   t5(둥5): 돌진우(3c) 먼저 발동해 둥 3 소모+트래시 이벤트 4장째 →
#            잔여 둥 2에서 021이 발동 목록에 떠야 함(미수리=코스트 4라 불가,
#            수리=1이라 가능 - 진짜 판별점) → 발동 → 루시 E2 기동 →
#            원래 코스트(4) 기준 집계로 드로우 1 (유저 지시: 021 발동 후에도
#            루시 리더 드로우 성립 검증)
#  판정: t1 음성 + t5 둥2 창에서 021 발동 + 루시 발동 +
#        deck(t6)=deck(t5)-2(돌진우+루시 드로우) + 오류 0.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class AceCostHeadless {
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

    const uint LUCY = 880002304;    // OP15-002 리더
    const uint ACE = 880002323;     // OP15-021 지켜봐! 에이스!!! (4c 이벤트, 트래시 이벤트 4+면 -3)
    const uint BARRIER = 880002321; // OP15-019 배리어 돌진우(3c 이벤트)
    const uint FIREFIST = 880002322;// OP15-020 불주먹(트래시 적재용 이벤트)
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
    Debug.Message('ACEPROBE t=' .. Duel.GetTurnCount() ..
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
        int newTurns = 0;
        bool aceSeenT1 = false, barrierPlayed = false, aceActivated = false, lucyActivated = false;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var pb = Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "ace_probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");
            Action<int, uint, int, uint, uint> addCards = delegate(int p, uint code, int copies, uint loc, uint pos) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = loc, seq = 0, pos = pos };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, LUCY, 1, 1, 8);
            for (int k = 0; k < 25; ++k) { addCards(0, ACE, 1, 1, 8); addCards(0, BARRIER, 1, 1, 8); }
            addCards(0, FIREFIST, 3, 0x10, 1); // 트래시 사전 적재(이벤트 3장)
            addCards(1, LEADER2, 1, 1, 8);
            addCards(1, FILLER, 30, 1, 8);
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
                if (lastMsgId == 13) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 12) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) {
                    int p = 2;
                    int actAce = -1, actBarrier = -1, actLucy = -1;
                    var dbg = new StringBuilder("IDLE" + newTurns + " ");
                    try {
                        for (int list = 0; list < 5; ++list) {
                            int n0 = BitConverter.ToInt32(lastMsg, p); p += 4;
                            p += n0 * ((list == 2) ? 7 : 10);
                        }
                        int nAct = BitConverter.ToInt32(lastMsg, p); p += 4;
                        dbg.Append("act=").Append(nAct).Append(":");
                        for (int i = 0; i < nAct; ++i) {
                            uint code = BitConverter.ToUInt32(lastMsg, p); p += 19;
                            dbg.Append(code).Append(",");
                            if (code == ACE && actAce < 0) actAce = i;
                            if (code == BARRIER && actBarrier < 0) actBarrier = i;
                            if (code == LUCY && actLucy < 0) actLucy = i;
                        }
                    } catch (Exception ex) { dbg.Append("EX:").Append(ex.Message); }
                    bool myTurn = newTurns == 1 || newTurns == 3 || newTurns == 5;
                    if (myTurn) Console.WriteLine(dbg.ToString());
                    if (newTurns == 1) {
                        if (actAce >= 0) aceSeenT1 = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    } else if (newTurns == 5 && !barrierPlayed && actBarrier >= 0) {
                        // 둥 5 → 돌진우가 3을 소모(트래시 이벤트 4장째): 이후
                        // 잔여 둥 2 창이 진짜 판별점(코스트 4면 절대 못 뜬다)
                        barrierPlayed = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((actBarrier << 16) | 5), 4);
                    } else if (newTurns == 5 && barrierPlayed && !aceActivated && actAce >= 0) {
                        aceActivated = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((actAce << 16) | 5), 4);
                    } else if (newTurns == 5 && aceActivated && !lucyActivated && actLucy >= 0) {
                        lucyActivated = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((actLucy << 16) | 5), 4);
                    } else {
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    }
                }
                else if (lastMsgId == 15) {
                    // [i32 0][u32 개수][u32 인덱스...] — 최소 요구 장수만(0=취소)
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
                if (newTurns >= 7) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        var deck = new Dictionary<int, int>();
        var grave = new Dictionary<int, int>();
        foreach (var p in probes) {
            if (!p.Contains("ACEPROBE")) continue;
            Console.WriteLine("PROBE: " + p);
            int t = 0, d = -1, g = -1;
            foreach (var part in p.Split(' ')) {
                if (part.StartsWith("t=")) t = int.Parse(part.Substring(2));
                if (part.StartsWith("deck0=")) d = int.Parse(part.Substring(6));
                if (part.StartsWith("grave0=")) g = int.Parse(part.Substring(7));
            }
            if (t > 0) { deck[t] = d; grave[t] = g; }
        }
        Console.WriteLine("ace_seen_t1=" + aceSeenT1 + " barrier_t5=" + barrierPlayed
            + " ace_don2_window=" + aceActivated + " lucy_t5=" + lucyActivated);
        bool seeded = grave.ContainsKey(1) && grave[1] == 3;
        bool drew2 = deck.ContainsKey(5) && deck.ContainsKey(6) && deck[6] == deck[5] - 2;
        Console.WriteLine("grave_seeded=" + seeded + " draws_ok=" + drew2);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0
            && seeded && !aceSeenT1 && barrierPlayed && aceActivated && lucyActivated && drew2;
        Console.WriteLine(pass ? "ACE_COST PASS" : "ACE_COST FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [AceCostHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
