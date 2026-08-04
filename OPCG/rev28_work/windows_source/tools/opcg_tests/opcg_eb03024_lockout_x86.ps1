param([Parameter(Mandatory = $true)][string]$Repo)

# EB03-024 비비 「그 후, 이번 턴 자신은 캐릭터 등장 불가」 실측(유저 제보: 제약 미작동).
#  t7(둥7): 비비(5c) 등장 → E1 패에서 조로(4c 밀짚) 효과 등장 →
#  같은 턴 idle에서 야마토(1c, 둥 2 잔여)가 등장 후보에 남아 있으면 = 고장 재현.
#  정상 = 후보 부재. probe: 턴 종료마다 제약 효과(0x7f4f1212) 유효 여부 덤프.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class VivilLock {
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
    [StructLayout(LayoutKind.Sequential)] public struct NewCard { public byte team, duelist; public uint code; public byte con; public uint loc, seq, pos; }
    [StructLayout(LayoutKind.Sequential)] public struct CardData {
        public uint code, alias; public IntPtr setcodes;
        public uint type, level, attribute; public ulong race;
        public int attack, defense; public uint lscale, rscale, link_marker, category;
    }

    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_CreateDuel(out IntPtr duel, ref Options options);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DestroyDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelNewCard(IntPtr duel, ref NewCard info);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_StartDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_DuelProcess(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr OCG_DuelGetMessage(IntPtr duel, out uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelSetResponse(IntPtr duel, byte[] buffer, uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_LoadScript(IntPtr duel, byte[] buffer, uint length, [MarshalAs(UnmanagedType.LPStr)] string name);

    const uint VIVI = 880002127;   // EB03-024 5c
    const uint ZORO = 880002490;   // P-042 4c 밀짚(효과 등장용)
    const uint YAMATO = 880002492; // P-046 1c(제약 시험용)
    const uint LEADER0 = 880000634;
    const uint FILLER = 880000957;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> probes = new List<string>();
    static readonly List<string> log = new List<string>();
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

    class Reader { public byte[] buf; public int pos; public Reader(byte[] b, int p){buf=b;pos=p;} public byte U8(){byte v=buf[pos];pos+=1;return v;} public uint U32(){uint v=BitConverter.ToUInt32(buf,pos);pos+=4;return v;} public ulong U64(){ulong v=BitConverter.ToUInt64(buf,pos);pos+=8;return v;} }
    static void RespondI32(IntPtr duel, int v) { OCG_DuelSetResponse(duel, BitConverter.GetBytes(v), 4); }

    public static int Run(string repo) {
        string release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        LoadDb(Path.Combine(repo, "tools", "opcg_tests", "cdb_dump.csv"));

        Options o = new Options(); o.seed0=1;o.seed1=2;o.seed2=3;o.seed3=4; o.flags=0x2000000000UL;
        Player pl = new Player(); pl.startingLP=5; pl.startingDrawCount=5; pl.drawCountPerTurn=1; o.team1=pl; o.team2=pl;
        o.cardReader=cardReader; o.scriptReader=scriptReader; o.logHandler=logHandler; o.cardReaderDone=cardReaderDone; o.enableUnsafeLibraries=1;
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref o) != 0 || duel == IntPtr.Zero) { Console.WriteLine("OCG_CreateDuel failed"); return 2; }

        bool viviPlayed=false, zoroPlayed=false, yamatoOfferedAfter=false, checkedAfter=false, viviChainDone=false;
        int newTurns = 0;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            string probe =
              "local pr=Effect.GlobalEffect() pr:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pr:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n" +
              "pr:SetOperation(function()\n" +
              "  local n=0 if opcg.EFFECT_CANNOT_PLAY then local r={Duel.IsPlayerAffectedByEffect(0,opcg.EFFECT_CANNOT_PLAY)} n=#r end\n" +
              "  Debug.Message('LOCKFX t='..Duel.GetTurnCount()..' n='..n)\n" +
              "  local s='' local g=Duel.GetFieldGroup(0,LOCATION_MZONE,0)\n" +
              "  for c in aux.Next(g) do s=s..c:GetOriginalCode()..' ' end\n" +
              "  Debug.Message('FIELD t='..Duel.GetTurnCount()..' '..s)\n" +
              "end) Duel.RegisterEffect(pr,0)\n";
            byte[] pb = Encoding.UTF8.GetBytes(probe);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "vivi_probe.lua") != 1) callbackErrors.Add("probe fail");

            Action<int,uint,int> add = delegate(int p, uint code, int copies){ for(int k=0;k<copies;++k){ NewCard c=new NewCard(); c.team=(byte)p;c.duelist=0;c.code=code;c.con=(byte)p;c.loc=1;c.seq=0;c.pos=8; OCG_DuelNewCard(duel, ref c);} };
            // top 12 = 비비4+조로4+야마토4 → 첫 패5+라이프4 소진 후에도 패에 세 종 모두 확보
            add(0, LEADER0, 1); add(0, FILLER, 38); add(0, YAMATO, 4); add(0, ZORO, 4); add(0, VIVI, 4);
            add(1, LEADER0, 1); add(1, FILLER, 45);
            OCG_StartDuel(duel);

            uint lastId=0; byte[] lastMsg=null;
            for (int step=0; step<40000; ++step) {
                int st=OCG_DuelProcess(duel);
                uint length; IntPtr ptr=OCG_DuelGetMessage(duel, out length);
                byte[] all=new byte[length]; if(length>0) Marshal.Copy(ptr, all, 0, (int)length);
                int off=0;
                while(off+4<=all.Length){ uint pl2=BitConverter.ToUInt32(all,off); off+=4; if(pl2==0||off+pl2>all.Length) break; byte id=all[off]; byte[] payload=new byte[pl2]; Array.Copy(all,off,payload,0,(int)pl2); off+=(int)pl2; lastId=id; lastMsg=payload; if(id==40) newTurns++; }
                if(st==0) break; if(st!=1) continue; if(lastMsg==null) break;
                if(newTurns>=9) break;

                if(lastId==11){
                    Reader r=new Reader(lastMsg,1); byte idlePlayer=r.U8();
                    uint n; int sumVivi=-1, sumYam=-1;
                    var sums=new List<uint>();
                    n=r.U32(); for(uint i=0;i<n;++i){uint code=r.U32();r.U8();r.U8();r.U32(); sums.Add(code); if(code==VIVI&&sumVivi<0)sumVivi=(int)i; if(code==YAMATO&&sumYam<0)sumYam=(int)i;}
                    if(idlePlayer==0 && newTurns>=7 && log.Count<12) log.Add("IDLE t"+newTurns+" sum=["+string.Join(",",sums)+"]");
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();r.U64();r.U8();}
                    if(idlePlayer==0 && newTurns>=7){
                        if(!viviPlayed && sumVivi>=0){ viviPlayed=true; log.Add("VIVI play t"+newTurns); RespondI32(duel,(sumVivi<<16)|0); continue; }
                        if(viviPlayed && zoroPlayed && !checkedAfter){
                            checkedAfter=true;
                            if(sumYam>=0){ yamatoOfferedAfter=true; log.Add("POST yamato STILL summonable (고장 재현)"); }
                            else log.Add("POST yamato blocked (정상)");
                        }
                    }
                    RespondI32(duel,7); continue;
                }
                else if(lastId==15){
                    Reader r=new Reader(lastMsg,1); byte p2=r.U8(); r.U8();
                    uint mn=r.U32(); uint mx=r.U32(); uint n=r.U32();
                    if(viviPlayed && p2==0){
                        // 1회차(비비A 효과) = 비비B 선택 → 제약 등록 후 비비B의 효과가 연쇄
                        // 2회차(비비B 효과, 제약下) = 조로 선택 시도 → 수리 후엔 미등장이 정답
                        int zi=-1, vi=-1; var codes=new List<uint>();
                        for(uint i=0;i<n;++i){ uint code=r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); codes.Add(code); if(code==ZORO&&zi<0)zi=(int)i; if(code==VIVI&&vi<0)vi=(int)i; }
                        log.Add("E1_SEL n="+n+" ["+string.Join(",",codes)+"] zoro="+zi+" vivi="+vi);
                        int pick = !viviChainDone && vi>=0 ? vi : zi;
                        if(!viviChainDone && vi>=0) viviChainDone=true;
                        else if(pick>=0) zoroPlayed=true;
                        if(pick>=0){
                            byte[] resp=new byte[12];
                            Array.Copy(BitConverter.GetBytes((int)0),0,resp,0,4);
                            Array.Copy(BitConverter.GetBytes((uint)1),0,resp,4,4);
                            Array.Copy(BitConverter.GetBytes((uint)pick),0,resp,8,4);
                            OCG_DuelSetResponse(duel,resp,12); continue;
                        }
                    }
                    if(mn==0){ OCG_DuelSetResponse(duel,new byte[8],8); }
                    else { byte[] r1=new byte[12]; Array.Copy(BitConverter.GetBytes((int)0),0,r1,0,4); Array.Copy(BitConverter.GetBytes((uint)1),0,r1,4,4); OCG_DuelSetResponse(duel,r1,12); }
                }
                else if(lastId==12||lastId==13||lastId==14){ RespondI32(duel,0); }
                else if(lastId==16){ RespondI32(duel,-1); }
                else if(lastId==26||lastId==25){ RespondI32(duel,-1); }
                else if(lastId==19){ RespondI32(duel,1); }
                else if(lastId==10){ Reader r=new Reader(lastMsg,1); r.U8(); uint n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();r.U64();r.U8();} n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();r.U8();} r.U8(); byte toEp=r.U8(); RespondI32(duel, toEp!=0?3:2); }
                else if(lastId==18||lastId==24){
                    byte pl2b = lastMsg.Length > 1 ? lastMsg[1] : (byte)0;
                    uint flag = lastMsg.Length >= 7 ? BitConverter.ToUInt32(lastMsg, 3) : 0u;
                    byte loc = 4, seq = 0;
                    for (byte i = 0; i < 7; ++i) if ((flag & (1u << i)) == 0) { loc = 4; seq = i; break; }
                    if ((flag & 0x7f) == 0x7f)
                        for (byte i = 0; i < 8; ++i) if ((flag & (1u << (8 + i))) == 0) { loc = 8; seq = i; break; }
                    OCG_DuelSetResponse(duel, new byte[] { pl2b, loc, seq }, 3);
                }
                else RespondI32(duel,0);
            }
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("turns=" + newTurns + " errors=" + errors.Count + " callback=" + callbackErrors.Count);
        foreach(var e in errors) Console.WriteLine("ERR " + e);
        foreach(var e in callbackErrors) Console.WriteLine("CB " + e);
        foreach(var s2 in log) Console.WriteLine("LOG " + s2);
        foreach(var p2 in probes) if(p2.StartsWith("LOCKFX")||p2.StartsWith("FIELD")) Console.WriteLine("PROBE " + p2);
        bool zoroOnField=false;
        foreach(var p2 in probes) if(p2.StartsWith("FIELD t=8") && p2.Contains("880002490")) zoroOnField=true;
        bool pass = viviPlayed && viviChainDone && checkedAfter && !yamatoOfferedAfter && !zoroOnField && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine("viviPlayed=" + viviPlayed + " chainVivi=" + viviChainDone + " zoroTried=" + zoroPlayed + " zoroOnField=" + zoroOnField + " yamatoStillSummonable=" + yamatoOfferedAfter);
        Console.WriteLine(pass ? "EB03024_LOCK PASS" : "EB03024_LOCK FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [VivilLock]::Run((Resolve-Path -LiteralPath $Repo).Path)
