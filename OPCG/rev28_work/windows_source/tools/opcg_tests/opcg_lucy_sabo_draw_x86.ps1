param([Parameter(Mandatory = $true)][string]$Repo)

# OP15-002 루시 E2 × OP15-046 사보 연동 실측(유저 제보):
#  루시 E2 【기동: 메인】 = "이번 턴 동안, 자신이 원래 코스트가 3 이상인 이벤트를
#  발동했을 경우, 카드를 1장 뽑는다" — 사보의 등장 시 효과(패에서 드레스로자
#  이벤트를 발동)로 발동한 이벤트도 집계돼야 한다(ACTIVATE_CARD_EFFECT 경로에
#  RecordEventActivated 시공 검증).
#  시나리오: P0 루시 리더, 덱 = 사보(7c)×25 + 배리어 돌진우(3c 이벤트)×25 교호.
#   t5: 루시 E2 단독 발동 → 이벤트 미발동 턴이라 드로우 0 (음성 대조)
#   t7: 사보 등장 → 등장 시 패의 돌진우 발동(드로우1+리더 버프) → 루시 E2 → 드로우1
#  판정: deck0(t7)=deck0(t5)-1(턴 드로우만) AND deck0(t8)=deck0(t7)-2(돌진우+E2)
#        + grave0(t8)>=1(돌진우 트래시) + 스크립트 오류 0.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class LucySaboHeadless {
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
    const uint SABO = 880002348;    // OP15-046 사보(7c, 등장 시 패의 드레스로자 이벤트 발동)
    const uint BARRIER = 880002321; // OP15-019 배리어 돌진우(3c 이벤트: 드로우1+리더 버프)
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
    Debug.Message('SABOPROBE t=' .. Duel.GetTurnCount() ..
        ' deck0=' .. Duel.GetFieldGroupCount(0, LOCATION_DECK, 0) ..
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
        bool saboPlayed = false, e2AtT5 = false, e2AtT7 = false, eventPicked = false;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var pb = Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "sabo_probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");
            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, LUCY, 1);
            for (int k = 0; k < 25; ++k) { addCards(0, SABO, 1); addCards(0, BARRIER, 1); }
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
                    ulong desc = BitConverter.ToUInt64(lastMsg, 2);
                    uint code = (uint)(desc >> 20);
                    OCG_DuelSetResponse(duel, BitConverter.GetBytes((code == SABO || code == LUCY || code == BARRIER) ? 1 : 0), 4);
                }
                else if (lastMsgId == 12) {
                    uint code = BitConverter.ToUInt32(lastMsg, 2);
                    OCG_DuelSetResponse(duel, BitConverter.GetBytes((code == SABO || code == LUCY || code == BARRIER) ? 1 : 0), 4);
                }
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) {
                    // 아이들 파서: L0=플레이 목록에서 사보, L5=발동 목록에서 루시 탐색
                    int p = 2;
                    int playSabo = -1, actLucy = -1;
                    var dbg = new StringBuilder("IDLE" + newTurns + " ");
                    try {
                        for (int list = 0; list < 5; ++list) {
                            int n0 = BitConverter.ToInt32(lastMsg, p); p += 4;
                            dbg.Append("L").Append(list).Append("=").Append(n0).Append(" ");
                            for (int i = 0; i < n0; ++i) {
                                uint code = BitConverter.ToUInt32(lastMsg, p);
                                if (list == 0 && code == SABO && playSabo < 0) playSabo = i;
                                p += (list == 2) ? 7 : 10;
                            }
                        }
                        int nAct = BitConverter.ToInt32(lastMsg, p); p += 4;
                        dbg.Append("act=").Append(nAct).Append(":");
                        for (int i = 0; i < nAct; ++i) {
                            uint code = BitConverter.ToUInt32(lastMsg, p); p += 19;
                            dbg.Append(code).Append(",");
                            if (code == LUCY && actLucy < 0) actLucy = i;
                        }
                    } catch (Exception ex) { dbg.Append("EX:").Append(ex.Message); }
                    bool myTurn = newTurns == 5 || newTurns == 7;
                    if (myTurn) Console.WriteLine(dbg.ToString());
                    if (newTurns == 5 && !e2AtT5 && actLucy >= 0) {
                        e2AtT5 = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((actLucy << 16) | 5), 4);
                    } else if (newTurns == 7 && !saboPlayed && playSabo >= 0) {
                        saboPlayed = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((playSabo << 16) | 0), 4);
                    } else if (newTurns == 7 && saboPlayed && !e2AtT7 && actLucy >= 0) {
                        e2AtT7 = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((actLucy << 16) | 5), 4);
                    } else {
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    }
                }
                else if (lastMsgId == 15) {
                    // SELECT_CARD 응답 = [i32 0][u32 개수][u32 인덱스...] — 첫 후보 1장
                    if (newTurns == 7 && saboPlayed && !eventPicked) eventPicked = true;
                    var resp = new byte[12];
                    BitConverter.GetBytes(0).CopyTo(resp, 0);
                    BitConverter.GetBytes(1).CopyTo(resp, 4);
                    BitConverter.GetBytes(0).CopyTo(resp, 8);
                    OCG_DuelSetResponse(duel, resp, 12);
                }
                else if (lastMsgId == 26) {
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
                if (newTurns >= 9) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        var deck = new Dictionary<int, int>();
        var grave = new Dictionary<int, int>();
        foreach (var p in probes) {
            if (!p.Contains("SABOPROBE")) continue;
            Console.WriteLine("PROBE: " + p);
            int t = 0, d = -1, g = -1;
            foreach (var part in p.Split(' ')) {
                if (part.StartsWith("t=")) t = int.Parse(part.Substring(2));
                if (part.StartsWith("deck0=")) d = int.Parse(part.Substring(6));
                if (part.StartsWith("grave0=")) g = int.Parse(part.Substring(7));
            }
            if (t > 0) { deck[t] = d; grave[t] = g; }
        }
        Console.WriteLine("sabo_played=" + saboPlayed + " e2_t5=" + e2AtT5 + " e2_t7=" + e2AtT7 + " event_picked=" + eventPicked);
        bool negativeOk = deck.ContainsKey(5) && deck.ContainsKey(7) && deck[7] == deck[5] - 1;
        bool positiveOk = deck.ContainsKey(7) && deck.ContainsKey(8) && deck[8] == deck[7] - 2;
        bool graveOk = grave.ContainsKey(8) && grave[8] >= 1;
        Console.WriteLine("negative_no_draw=" + negativeOk + " positive_two_draws=" + positiveOk + " event_in_trash=" + graveOk);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0
            && saboPlayed && e2AtT5 && e2AtT7 && eventPicked && negativeOk && positiveOk && graveOk;
        Console.WriteLine(pass ? "LUCY_SABO PASS" : "LUCY_SABO FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [LucySaboHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
