param([Parameter(Mandatory = $true)][string]$Repo)

# OP14-041 보아 행콕 E2 실측(유저 리플레이 제보: 둥×1 효과 무발동):
#  【둥!!×1】【턴 1회】 자신의 원래 파워 5000+ 《아마존 릴리》/《구사 해적단》
#  캐릭터가 KO되었을 때 → 상대 라이프 위 1장을 주인의 패로.
#  수술 검증: 배틀 KO의 ON_ANY_CHARACTER_KO가 event_target 실린 정제 문맥을
#  받는지. 시나리오: t5 행콕(880002206) 등장, t7 희생양 행콕(880001623,
#  3c/5000 구사·아마존) 등장+리스너에 둥 1 부여, t8 P1 리더가 희생양 KO →
#  E2 프롬프트 YES → P1 라이프 4→3. 판정: t9 life1==3.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class HancockKoHeadless {
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

    const uint HANCOCK = 880002206;  // OP14-041 (리스너)
    const uint VICTIM = 880001623;   // 3c/5000 구사·아마존 행콕(희생양)
    const uint DONCARD = 879999997;
    const uint LEADER2 = 880000634;
    const uint FILLER = 880002322;   // 불주먹(무트리거 이벤트)
    const uint FILLER2 = 880000881;  // 징베(바닐라)

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
    Debug.Message('HKPROBE t=' .. Duel.GetTurnCount() ..
        ' life0=' .. Duel.GetFieldGroupCount(0, LOCATION_EXTRA, 0) ..
        ' life1=' .. Duel.GetFieldGroupCount(1, LOCATION_EXTRA, 0) ..
        ' grave0=' .. Duel.GetFieldGroupCount(0, LOCATION_GRAVE, 0))
    local tt = Duel.GetTurnCount()
    if tt == 7 or tt == 8 then
        local lead = opcg.GetLeader(0)
        local okc, ok, why = pcall(opcg.runtime.can_resolve, lead, 'E2',
            {card=lead, player=0, timing='ON_ANY_CHARACTER_KO'})
        Debug.Message('HKE2 t=' .. tt .. ' don=' .. tostring(opcg.GetAttachedDon(lead)) ..
            ' can=' .. tostring(ok) .. ' why=' .. tostring(why))
    end
    if Duel.GetTurnCount() == 5 then
        local names = {}
        local g = Duel.GetFieldGroup(0, LOCATION_HAND, 0)
        for c in aux.Next(g) do names[#names + 1] = c:GetOriginalCode() end
        Debug.Message('HKHAND ' .. table.concat(names, ','))
        for c in aux.Next(g) do
            if c:GetOriginalCode() == 880002206 then
                local d = opcg.runtime.get_definition and opcg.runtime.get_definition(c)
                local rev = opcg.runtime._review_definitions and opcg.runtime._review_definitions[c]
                Debug.Message('HKREG def=' .. tostring(d ~= nil) .. ' review=' .. tostring(rev ~= nil))
                local cost = opcg.EffectivePlayCost and opcg.EffectivePlayCost(c, 0) or opcg.GetCost(c)
                Debug.Message('HKPLAY cost=' .. tostring(cost) ..
                    ' rawcost=' .. tostring(opcg.GetCost(c)) ..
                    ' canrest=' .. tostring(opcg.CanRestDon(0, cost)) ..
                    ' cannotplay=' .. tostring(opcg.contract_ops.player_has(0, opcg.EFFECT_CANNOT_PLAY, c)) ..
                    ' zone=' .. tostring(Duel.GetLocationCount(0, LOCATION_MZONE)) ..
                    ' ischar=' .. tostring(opcg.IsCharacter(c)))
                break
            end
        end
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
        bool playedVictim = false, donGiven = false, p0Attacked = false, attacked = false, e2Asked = false;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var pb = Encoding.UTF8.GetBytes(probeLua);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "hk_probe.lua") != 1)
                callbackErrors.Add("probe script failed to load");
            Action<int, uint, int> addCards = delegate(int p, uint code, int copies) {
                for (int k = 0; k < copies; ++k) {
                    var card = new NewCard { team = (byte)p, duelist = 0, code = code, con = (byte)p, loc = 1, seq = 0, pos = 8 };
                    OCG_DuelNewCard(duel, ref card);
                }
            };
            addCards(0, HANCOCK, 1);
            for (int k2 = 0; k2 < 15; ++k2) { addCards(0, VICTIM, 1); addCards(0, FILLER, 1); }
            addCards(1, LEADER2, 1);
            addCards(1, FILLER2, 30);
            OCG_StartDuel(duel);

            uint lastMsgId = 0;
            byte[] lastMsg = null;
            int st = 2;
            for (int step = 0; step < 80000 && st != 0; ++step) {
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
                    Console.WriteLine("YESNO@" + newTurns + " code=" + code);
                    if (code == HANCOCK) { e2Asked = true; OCG_DuelSetResponse(duel, BitConverter.GetBytes(1), 4); }
                    else OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                }
                else if (lastMsgId == 12) {
                    uint c12 = BitConverter.ToUInt32(lastMsg, 2);
                    Console.WriteLine("EFFYN@" + newTurns + " code=" + c12);
                    if (c12 == HANCOCK) { e2Asked = true; OCG_DuelSetResponse(duel, BitConverter.GetBytes(1), 4); }
                    else OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                }
                else if (lastMsgId == 14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if (lastMsgId == 16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if (lastMsgId == 11) {
                    int p = 2;
                    Func<int> u32 = delegate { int v = BitConverter.ToInt32(lastMsg, p); p += 4; return v; };
                    int playIdx = -1; uint playWant = 0;
                    int actDonIdx = -1, atkIdx = -1;
                    try {
                        int n0 = u32();
                        if (!playedVictim && newTurns == 5) playWant = VICTIM;
                        var d0 = new StringBuilder("L0@" + newTurns + ":");
                        for (int i = 0; i < n0; ++i) {
                            uint code = BitConverter.ToUInt32(lastMsg, p); p += 10;
                            if (newTurns == 5) d0.Append(code).Append(",");
                            if (playWant != 0 && code == playWant && playIdx < 0) playIdx = i;
                        }
                        if (newTurns == 5 && n0 > 0) Console.WriteLine(d0.ToString());
                        for (int list = 1; list < 5; ++list) { int n1 = u32(); p += n1 * ((list == 2) ? 7 : 10); }
                        int nAct = u32();
                        for (int i = 0; i < nAct; ++i) {
                            uint code = BitConverter.ToUInt32(lastMsg, p); p += 19;
                            if (code == DONCARD && actDonIdx < 0) actDonIdx = i;
                        }
                        p += 3;
                        int nAtk = u32();
                        uint atkWant = newTurns == 7 ? VICTIM : (newTurns == 8 ? LEADER2 : 0);
                        for (int i = 0; i < nAtk; ++i) {
                            uint code = BitConverter.ToUInt32(lastMsg, p); p += 8;
                            if (atkWant != 0 && code == atkWant && atkIdx < 0) atkIdx = i;
                        }
                    } catch (Exception) { }
                    if (playIdx >= 0) {
                        playedVictim = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((playIdx << 16) | 0), 4);
                    } else if (p0Attacked && !donGiven && newTurns == 7 && actDonIdx >= 0) {
                        donGiven = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((actDonIdx << 16) | 5), 4);
                    } else if (!p0Attacked && newTurns == 7 && atkIdx >= 0) {
                        p0Attacked = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((atkIdx << 16) | 9), 4);
                    } else if (!attacked && newTurns == 8 && atkIdx >= 0) {
                        attacked = true;
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes((atkIdx << 16) | 9), 4);
                    } else {
                        OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                    }
                }
                else if (lastMsgId == 15) {
                    // [id][player][?][min][max][n][entries(code u32 + 10B)] — 코드 우선 선택
                    int p = 3;
                    Func<uint> u32u = delegate { uint v = BitConverter.ToUInt32(lastMsg, p); p += 4; return v; };
                    uint smin = u32u(); u32u();
                    uint n = u32u();
                    int want = -1;
                    uint prefer = attacked ? VICTIM : HANCOCK;
                    var d15 = new StringBuilder("SEL15@" + newTurns + " min=" + smin + " n=" + n + ":");
                    for (uint i = 0; i < n; ++i) {
                        uint code = BitConverter.ToUInt32(lastMsg, p); p += 14;
                        d15.Append(code).Append(",");
                        if (want < 0 && code == prefer) want = (int)i;
                    }
                    Console.WriteLine(d15.ToString());
                    var resp = new List<byte>();
                    resp.AddRange(BitConverter.GetBytes(0));
                    if (want >= 0) {
                        resp.AddRange(BitConverter.GetBytes(1));
                        resp.AddRange(BitConverter.GetBytes(want));
                    } else if (smin > 0) {
                        resp.AddRange(BitConverter.GetBytes(smin));
                        for (uint i2 = 0; i2 < smin; ++i2) resp.AddRange(BitConverter.GetBytes(i2));
                    } else {
                        resp.AddRange(BitConverter.GetBytes(0));
                    }
                    OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count);
                }
                else if (lastMsgId == 26) {
                    // SELECT_UNSELECT: 헤더[1id 1pl 1fin 1can][min][max][n], 엔트리 14B
                    int p2 = 4;
                    uint mn = BitConverter.ToUInt32(lastMsg, p2); p2 += 4;
                    p2 += 4;
                    uint n2 = BitConverter.ToUInt32(lastMsg, p2); p2 += 4;
                    int pick = -1;
                    uint prefer2 = attacked ? VICTIM : HANCOCK;
                    var d26 = new StringBuilder("SEL26@" + newTurns + " min=" + mn + " n=" + n2 + ":");
                    for (uint i = 0; i < n2 && p2 + 4 <= lastMsg.Length; ++i) {
                        uint code = BitConverter.ToUInt32(lastMsg, p2); p2 += 14;
                        d26.Append(code).Append(",");
                        if (pick < 0 && code == prefer2) pick = (int)i;
                    }
                    Console.WriteLine(d26.ToString());
                    int chosen = pick >= 0 ? pick : (n2 > 0 ? 0 : -1);
                    if (chosen >= 0) {
                        var r26 = new byte[8];
                        BitConverter.GetBytes(1).CopyTo(r26, 0);
                        BitConverter.GetBytes(chosen).CopyTo(r26, 4);
                        OCG_DuelSetResponse(duel, r26, 8);
                    } else OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
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
                if (newTurns >= 10) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        foreach (var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach (var e in errors) Console.WriteLine("SCRIPT: " + e);
        var life1 = new Dictionary<int, int>();
        var grave0 = new Dictionary<int, int>();
        foreach (var pr in probes) {
            if (!pr.Contains("HKPROBE") && !pr.Contains("HKHAND") && !pr.Contains("HKREG") && !pr.Contains("HKPLAY") && !pr.Contains("HKE2")) continue;
            Console.WriteLine("PROBE: " + pr);
            int t = 0, l1 = -1, g0 = -1;
            foreach (var part in pr.Split(' ')) {
                if (part.StartsWith("t=")) t = int.Parse(part.Substring(2));
                if (part.StartsWith("life1=")) l1 = int.Parse(part.Substring(6));
                if (part.StartsWith("grave0=")) g0 = int.Parse(part.Substring(7));
            }
            if (t > 0) { life1[t] = l1; grave0[t] = g0; }
        }
        Console.WriteLine("playedVictim=" + playedVictim + " donGiven=" + donGiven +
            " p0Attacked=" + p0Attacked + " p1Attacked=" + attacked + " e2_asked=" + e2Asked);
        bool lifeTaken = life1.ContainsKey(9) && life1[9] == 2;
        bool victimDead = grave0.ContainsKey(9) && grave0[9] >= 1;
        Console.WriteLine("opp_life_taken=" + lifeTaken + " victim_dead=" + victimDead);
        bool pass = errors.Count == 0 && callbackErrors.Count == 0 && playedVictim
            && donGiven && attacked && lifeTaken && victimDead;
        Console.WriteLine(pass ? "HANCOCK_KO PASS" : "HANCOCK_KO FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [HancockKoHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
