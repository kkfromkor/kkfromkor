param([Parameter(Mandatory = $true)][string]$Repo)

# OP15-058 에넬 리더 축 검증(유저 지시: "058이랑 관련 카드들은 좀 꼼꼼히"):
#  ① 룰 개변 — 두웅!! 덱이 6장: 두웅 페이즈 충전이 6장에서 멈춰야 한다.
#     통상 리더면 t1=1, t3=3, t5=5, t7=7 … 10까지 차오른다. 에넬은
#     t1=1, t3=3 이후 E2(기동)로 잔여를 전부 흡수해 t5부터 6에 고정.
#  ② E2 기동(제2턴 이후): 두웅 덱에서 액티브 1 + 레스트 4까지 추가.
#     t3(자신의 제2턴) 메인에서 발동 → 두웅 덱(잔여 3) 전량 추가되어
#     필드 6/두웅 덱 0. 이후 두웅 페이즈는 아무것도 놓지 못한다.
#  기대 계열: t1=1, t3=3(발동 전 프로브), t5=6, t7=6, t9=6.
# 32-bit PowerShell로 구동(릴리스 ocgcore.dll이 Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class EnelDon6Headless {
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

    const uint ENEL = 880002360;   // OP15-058
    const uint LEADER2 = 880000634;
    const uint FILLER = 880000881; // 징베 OP07-027 (바닐라)

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
    Debug.Message('ENELPROBE t=' .. Duel.GetTurnCount() ..
        ' p=' .. Duel.GetTurnPlayer() ..
        ' field=' .. tostring(opcg.FieldDon(0)) ..
        ' max=' .. tostring(opcg.GetDonMax and opcg.GetDonMax(0) or -1))
    if Duel.GetTurnCount() == 3 then
        local lead = opcg.GetLeader(0)
        local okc, ok, why = pcall(opcg.runtime.can_resolve, lead, 'E2',
            {card=lead, player=0, ignition=true, timing='ACTIVATE_MAIN'})
        Debug.Message('ENELCAN pcall=' .. tostring(okc) ..
            ' ok=' .. tostring(ok) .. ' why=' .. tostring(why))
        local all = {lead:GetCardEffect(0)}
        local total, ignition = 0, 0
        for _, eff in ipairs(all) do
            total = total + 1
            if eff.GetType and (eff:GetType() & EFFECT_TYPE_IGNITION) ~= 0 then
                ignition = ignition + 1
            end
        end
        Debug.Message('ENELEFF total=' .. total .. ' ignition=' .. ignition)
    end
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
            team1 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 5, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader,
            logHandler = logHandler, cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed"); return 2;
        }
        int newTurns = 0;
        bool activated = false;
        int announceSeen = 0;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var pb = Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "enel_probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");
            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, ENEL, 1);
            addCards(0, FILLER, 30);
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
                if (lastMsgId == 13 || lastMsgId == 12) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) {
                    // idle 목록에서 리더(에넬) 기동 항목을 코드로 짚는다. 코스트존
                    // 두웅!!마다 자체 부여 기동이 함께 나열되므로 인덱스 0 금지.
                    int enelIdx = -1;
                    try {
                        int p = 2; // [0]=id, [1]=player
                        Func<int> u32 = delegate { int v = BitConverter.ToInt32(lastMsg, p); p += 4; return v; };
                        for (int list = 0; list < 5; ++list) {
                            int n = u32();
                            int entry = (list == 2) ? 7 : 10;
                            p += n * entry;
                        }
                        int actN = u32();
                        var dbg = new StringBuilder();
                        for (int i = 0; i < actN; ++i) {
                            uint code = BitConverter.ToUInt32(lastMsg, p);
                            p += 19; // U32 code + U8 + U8 + U32 + U64 desc + U8
                            if (newTurns == 3) dbg.Append(code).Append(' ');
                            if (code == ENEL && enelIdx < 0) enelIdx = i;
                        }
                        if (newTurns == 3 && !activated) Console.WriteLine("IDLE_T3 activatable codes: " + dbg);
                    } catch (Exception) { enelIdx = -1; }
                    if (!activated && newTurns == 3 && enelIdx >= 0) {
                        activated = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((enelIdx << 16) | 5), 4);
                    } else {
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    }
                }
                else if (lastMsgId == 143) {
                    // AnnounceNumber(0..max): 항상 최대치 선택 = 마지막 인덱스
                    int count = lastMsg[2];
                    announceSeen++;
                    OCG_DuelSetResponse(duel, BitConverter.GetBytes(count - 1), 4);
                }
                else if (lastMsgId == 26) {
                    // SELECT_UNSELECT_CARD: 선택 종료(빈 후보/임의 선택 마감)
                    OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                }
                else if (lastMsgId == 15) {
                    var resp = new byte[8];
                    OCG_DuelSetResponse(duel, resp, 8);
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
                if (newTurns >= 10) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        var field = new Dictionary<int, string>();
        var max = new Dictionary<int, string>();
        foreach (var p in probes) {
            if (!p.Contains("ENEL")) continue;
            Console.WriteLine("PROBE: " + p);
            if (!p.Contains("ENELPROBE")) continue;
            var parts = p.Split(' ');
            int t = 0; string f = null, m = null;
            foreach (var part in parts) {
                if (part.StartsWith("t=")) t = int.Parse(part.Substring(2));
                if (part.StartsWith("field=")) f = part.Substring(6);
                if (part.StartsWith("max=")) m = part.Substring(4);
            }
            if (t > 0) { field[t] = f; max[t] = m; }
        }
        Console.WriteLine("announce_prompts=" + announceSeen + " activated=" + activated);
        Func<int, string, bool> expect = (t, v) => field.ContainsKey(t) && field[t] == v;
        bool maxSix = max.ContainsKey(1) && max[1] == "6";
        bool preSeries = expect(1, "1") && expect(3, "3");
        bool postBurst = expect(5, "6") && expect(7, "6") && expect(9, "6");
        Console.WriteLine("max_six=" + maxSix + " pre_ok=" + preSeries + " burst_cap_ok=" + postBurst);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0
            && maxSix && preSeries && postBurst && activated && announceSeen >= 2;
        Console.WriteLine(pass ? "ENEL_DON6 PASS" : "ENEL_DON6 FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [EnelDon6Headless]::Run((Resolve-Path -LiteralPath $Repo).Path)
