param([Parameter(Mandatory = $true)][string]$Repo)

# PRB01-001 상디 리더 「등장 시 효과 없는 코스트 8 이하 캐릭터에 속공 부여」 실측.
#  유저 제안(OP09-081 티치의 등장 시 판독기 역이용 = opcg.HasOnPlayEffect 필터)의 검증.
#  시나리오: P0 리더 = PRB01-001(880002538).
#   t5(둥5): 야마토 P-046(880002492, 1c, 원문 【등장 시】 라벨 보유·효과 잠금) 등장.
#   t7(둥7): 조로 P-042(880002490, 4c 바닐라) 등장
#     → V1: 등장 직후 idle의 어택 목록에 조로 없어야(등장 턴 어택 불가)
#     → 리더 기동 발동 → V2: 대상 후보 = 조로만(야마토는 등장 시 라벨이라 배제)
#     → 조로 선택 → V3: 어택 목록에 조로 등장(속공 실효) → 어택 선언 접수
#  판정: V1·V2·V3 전부 + 스크립트 오류 0.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class Prb01Rush {
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

    const uint SANJI  = 880002538; // PRB01-001 리더
    const uint ZORO   = 880002490; // P-042 바닐라 4c
    const uint YAMATO = 880002492; // P-046 등장 시 라벨(잠금) 1c
    const uint LEADER2 = 880000634;
    const uint FILLER = 880000881;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();
    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    public static void LoadDb(string csv) {
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
    static readonly List<string> probes = new List<string>();
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

        bool yamatoPlayed=false, zoroPlayed=false, leaderActivated=false, zoroSelected=false;
        int zoroTurn=-1;
        bool preNoAttack=false, postAttackable=false, attackDeclared=false, yamatoOffered=false;
        int candN = -1; string candStr = "";
        int newTurns = 0;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            string probe =
              "local pr=Effect.GlobalEffect() pr:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pr:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n" +
              "pr:SetOperation(function()\n" +
              "  local t=Duel.GetTurnCount() if t>7 then return end\n" +
              "  local s='HAND t='..t..' ' local g=Duel.GetFieldGroup(0,LOCATION_HAND,0)\n" +
              "  for c in aux.Next(g) do s=s..c:GetOriginalCode()..'('..tostring(c:GetLevel())..')' end\n" +
              "  Debug.Message(s)\n" +
              "end) Duel.RegisterEffect(pr,0)\n";
            byte[] pb = Encoding.UTF8.GetBytes(probe);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "hand_probe.lua") != 1) callbackErrors.Add("probe fail");
            Action<int,uint,int> add = delegate(int p, uint code, int copies){ for(int k=0;k<copies;++k){ NewCard c=new NewCard(); c.team=(byte)p;c.duelist=0;c.code=code;c.con=(byte)p;c.loc=1;c.seq=0;c.pos=8; OCG_DuelNewCard(duel, ref c);} };
            // 헤드리스 코어는 셔플 없음 - 덱 맨 위 = 마지막 적재. 야마토/조로를 꼭대기에.
            add(0, SANJI, 1); add(0, FILLER, 42); add(0, ZORO, 4); add(0, YAMATO, 4);
            add(1, LEADER2, 1); add(1, FILLER, 45);
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
                    uint n;
                    var dbg=new StringBuilder("T"+newTurns+" P"+idlePlayer+" ");
                    // 리스트 1: summonable {code,con,loc,seq32}
                    int sumZoro=-1, sumYamato=-1;
                    n=r.U32(); dbg.Append("L1="+n+":"); for(uint i=0;i<n;++i){uint code=r.U32();r.U8();r.U8();r.U32(); dbg.Append(code+","); if(code==ZORO&&sumZoro<0)sumZoro=(int)i; if(code==YAMATO&&sumYamato<0)sumYamato=(int)i;}
                    n=r.U32(); dbg.Append(" L2="+n+":"); for(uint i=0;i<n;++i){uint code=r.U32();r.U8();r.U8();r.U32(); dbg.Append(code+","); if(code==ZORO&&sumZoro<0)sumZoro=(int)(0x1000+i); if(code==YAMATO&&sumYamato<0)sumYamato=(int)(0x1000+i);}
                    n=r.U32(); dbg.Append(" L3="+n); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();}
                    n=r.U32(); dbg.Append(" L4="+n); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); dbg.Append(" L5="+n); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    // 리스트 6: activatable {code,con,loc,seq32,u64,u8}
                    int actLeader=-1;
                    n=r.U32(); dbg.Append(" L6="+n+":"); for(uint i=0;i<n;++i){uint code=r.U32();r.U8();r.U8();r.U32();r.U64();r.U8(); dbg.Append(code+","); if(code==SANJI&&actLeader<0)actLeader=(int)i;}
                    r.U8();r.U8();r.U8();
                    // 어택 목록 {code,u8,u8,u8,u8}
                    int atkZoro=-1; uint nAtk=r.U32();
                    dbg.Append(" ATK="+nAtk);
                    for(uint i=0;i<nAtk;++i){uint code=r.U32();r.U8();r.U8();r.U8();r.U8(); if(code==ZORO&&atkZoro<0)atkZoro=(int)i;}
                    if(idlePlayer==0 && newTurns<=9) Console.WriteLine(dbg.ToString());

                    if(idlePlayer!=0){ RespondI32(duel,7); continue; }
                    if(!yamatoPlayed && newTurns>=3 && sumYamato>=0){ yamatoPlayed=true; RespondI32(duel, sumYamato>=0x1000 ? (((sumYamato-0x1000)<<16)|1) : ((sumYamato<<16)|0)); continue; }
                    if(yamatoPlayed && !zoroPlayed && newTurns>=7 && sumZoro>=0){ zoroPlayed=true; zoroTurn=newTurns; RespondI32(duel, sumZoro>=0x1000 ? (((sumZoro-0x1000)<<16)|1) : ((sumZoro<<16)|0)); continue; }
                    if(zoroPlayed && newTurns==zoroTurn && !leaderActivated){
                        if(atkZoro<0) preNoAttack=true; // V1: 기동 전 조로 어택 불가
                        if(actLeader>=0){ leaderActivated=true; RespondI32(duel,(actLeader<<16)|5); continue; }
                        Console.WriteLine("T"+newTurns+" leader not activatable"); RespondI32(duel,7); continue;
                    }
                    if(zoroSelected && newTurns==zoroTurn){
                        if(atkZoro>=0){ postAttackable=true; attackDeclared=true; RespondI32(duel,(atkZoro<<16)|9); continue; } // V3
                        Console.WriteLine("T"+newTurns+" rush NOT granted (zoro not attackable)"); RespondI32(duel,7); continue;
                    }
                    RespondI32(duel,7); continue;
                }
                else if(lastId==15){
                    Reader r=new Reader(lastMsg,1); r.U8(); r.U8();
                    uint min=r.U32(); uint max=r.U32();
                    uint n=r.U32(); uint[] codes=new uint[n]; int pickZoro=-1;
                    for(uint i=0;i<n;++i){ codes[i]=r.U32(); r.U8(); r.U8(); r.U32(); r.U32(); if(codes[i]==ZORO&&pickZoro<0)pickZoro=(int)i; if(codes[i]==YAMATO)yamatoOffered=true; }
                    if(leaderActivated && !zoroSelected && newTurns==zoroTurn){
                        candN=(int)n; candStr=string.Join(",", Array.ConvertAll(codes, x=>x.ToString()));
                        Console.WriteLine("T7 select candidates n="+n+" ["+candStr+"]");
                        if(pickZoro>=0){
                            zoroSelected=true;
                            byte[] resp=new byte[12];
                            Array.Copy(BitConverter.GetBytes((int)0),0,resp,0,4);
                            Array.Copy(BitConverter.GetBytes((uint)1),0,resp,4,4);
                            Array.Copy(BitConverter.GetBytes((uint)pickZoro),0,resp,8,4);
                            OCG_DuelSetResponse(duel,resp,12); continue;
                        }
                    }
                    if(min==0){ OCG_DuelSetResponse(duel,new byte[8],8); continue; }
                    byte[] r1=new byte[12];
                    Array.Copy(BitConverter.GetBytes((int)0),0,r1,0,4);
                    Array.Copy(BitConverter.GetBytes((uint)1),0,r1,4,4);
                    Array.Copy(BitConverter.GetBytes((uint)0),0,r1,8,4);
                    OCG_DuelSetResponse(duel,r1,12); continue;
                }
                else if(lastId==12||lastId==13||lastId==14){ RespondI32(duel,0); }
                else if(lastId==16){ RespondI32(duel,-1); }
                else if(lastId==26||lastId==25){ RespondI32(duel,-1); }
                else if(lastId==19){ RespondI32(duel,1); }
                else if(lastId==10){ Reader r=new Reader(lastMsg,1); r.U8(); uint n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();r.U64();r.U8();} n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();r.U8();} r.U8(); byte toEp=r.U8(); RespondI32(duel, toEp!=0?3:2); }
                else if(lastId==18||lastId==24){ Reader r=new Reader(lastMsg,1); byte player=r.U8(); byte need=r.U8(); uint flag=r.U32(); uint av=~flag; List<byte> resp=new List<byte>(); int given=0; for(int bit=0;bit<32&&given<Math.Max((int)need,1);++bit){ if((av&(1u<<bit))==0) continue; byte con=(byte)((bit>=16)?(1-player):player); int local=bit&0xf; byte loc=(byte)((local>=8)?8:4); byte seq=(byte)((local>=8)?(local-8):local); resp.Add(con);resp.Add(loc);resp.Add(seq); given++; } if(given==0) break; OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count); }
                else { RespondI32(duel,0); }
            }
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("yamatoPlayed=" + yamatoPlayed + " zoroPlayed=" + zoroPlayed + " leaderActivated=" + leaderActivated);
        Console.WriteLine("V1 preNoAttack=" + preNoAttack + " | V2 candidates n=" + candN + " [" + candStr + "] yamatoOffered=" + yamatoOffered + " | V3 rushAttack=" + postAttackable + " declared=" + attackDeclared);
        Console.WriteLine("errors=" + errors.Count + " callback=" + callbackErrors.Count);
        foreach(var e in errors) Console.WriteLine("ERR " + e);
        foreach(var e in callbackErrors) Console.WriteLine("CB " + e);
        foreach(var p2 in probes) Console.WriteLine("PROBE " + p2);
        bool pass = preNoAttack && leaderActivated && zoroSelected && !yamatoOffered && candN >= 1 && postAttackable && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(pass ? "PRB01_RUSH PASS" : "PRB01_RUSH FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [Prb01Rush]::Run((Resolve-Path -LiteralPath $Repo).Path)
