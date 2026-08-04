param([Parameter(Mandatory = $true)][string]$Repo)

# P-120 상디 「상대의 라이프가 벗어난 턴 동안 패에서 코스트 -2」 실측.
#  유저 제안: OP12-099 카르가라의 라이프 감소 깔때기 재활용 + 출력만 코스트로.
#  t5(둥5): 어택 전 idle에 P-120(6c) 등장 후보 없어야(음성) → 리더 어택 히트
#  (상대 라이프 감소) → 같은 턴 idle에 P-120 등장 후보 등장(6-2=4≤5) → 등장.
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class P120Cost {
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

    const uint SANJI120 = 880002530; // P-120 6c
    const uint ATTACKER = 880000001; // 바닐라 7000
    const uint LEADER0 = 880000634;
    const uint FILLER = 880000881;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
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

        bool preAbsent=false, attacked=false, postPresent=false, playedAfter=false;
        int newTurns = 0;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            string probe =
              "local pr=Effect.GlobalEffect() pr:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pr:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n" +
              "pr:SetOperation(function()\n" +
              "  if Duel.GetTurnCount()~=1 or opcg._seeded then return end opcg._seeded=true\n" +
              "  local a=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000001 end,0,LOCATION_DECK,0,nil):GetFirst()\n" +
              "  if a then Duel.MoveToField(a,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) end\n" +
              "end) Duel.RegisterEffect(pr,0)\n";
            byte[] pb = Encoding.UTF8.GetBytes(probe);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "p120_probe.lua") != 1) callbackErrors.Add("probe fail");

            Action<int,uint,int> add = delegate(int p, uint code, int copies){ for(int k=0;k<copies;++k){ NewCard c=new NewCard(); c.team=(byte)p;c.duelist=0;c.code=code;c.con=(byte)p;c.loc=1;c.seq=0;c.pos=8; OCG_DuelNewCard(duel, ref c);} };
            add(0, LEADER0, 1); add(0, ATTACKER, 4); add(0, FILLER, 40); add(0, SANJI120, 4);
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
                if(newTurns>=7) break;

                if(lastId==11){
                    Reader r=new Reader(lastMsg,1); byte idlePlayer=r.U8();
                    uint n; int sum120=-1;
                    n=r.U32(); for(uint i=0;i<n;++i){uint code=r.U32();r.U8();r.U8();r.U32(); if(code==SANJI120&&sum120<0)sum120=(int)i;}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();r.U64();r.U8();}
                    r.U8();r.U8();r.U8();
                    int atkIdx=-1; uint nAtk=r.U32();
                    for(uint i=0;i<nAtk;++i){uint code=r.U32();r.U8();r.U8();r.U8();r.U8(); if(code==ATTACKER&&atkIdx<0)atkIdx=(int)i;}
                    if(idlePlayer==0 && newTurns==5){
                        if(!attacked){
                            if(sum120<0){ preAbsent=true; log.Add("PRE absent ok"); }
                            else log.Add("PRE PRESENT?! idx="+sum120);
                            if(atkIdx>=0){ attacked=true; log.Add("ATTACK"); RespondI32(duel,(atkIdx<<16)|9); continue; }
                        } else {
                            if(sum120>=0 && !playedAfter){ postPresent=true; playedAfter=true; log.Add("POST present -> play"); RespondI32(duel,(sum120<<16)|0); continue; }
                            if(sum120<0 && !playedAfter) log.Add("POST still absent");
                        }
                    }
                    RespondI32(duel,7); continue;
                }
                else if(lastId==12||lastId==13||lastId==14){ RespondI32(duel,0); }
                else if(lastId==16){ RespondI32(duel,-1); }
                else if(lastId==15){ Reader r=new Reader(lastMsg,1); r.U8(); r.U8(); uint mn=r.U32(); if(mn==0){ OCG_DuelSetResponse(duel,new byte[8],8); } else { byte[] r1=new byte[12]; Array.Copy(BitConverter.GetBytes((int)0),0,r1,0,4); Array.Copy(BitConverter.GetBytes((uint)1),0,r1,4,4); OCG_DuelSetResponse(duel,r1,12); } }
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
        bool pass = preAbsent && attacked && postPresent && errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine("preAbsent=" + preAbsent + " attacked=" + attacked + " postPresent=" + postPresent);
        Console.WriteLine(pass ? "P120_COST PASS" : "P120_COST FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [P120Cost]::Run((Resolve-Path -LiteralPath $Repo).Path)
