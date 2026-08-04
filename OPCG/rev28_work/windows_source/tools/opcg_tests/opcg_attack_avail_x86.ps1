param([Parameter(Mandatory = $true)][string]$Repo)

# Attack-availability probe. Both players get a leader + a vanilla character
# seated ACTIVE on an early turn. For each idle command we DUMP the turn number,
# the turn player, and the size of the trailing attackable block (n). This maps
# exactly which player can declare an attack on which turn - to catch the
# reported "second player (going second) cannot declare an attack" case.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class AtkAvail {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReader(IntPtr payload, uint code, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReaderDone(IntPtr payload, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int ScriptReader(IntPtr payload, IntPtr duel, IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void LogHandler(IntPtr payload, IntPtr message, int type);

    [StructLayout(LayoutKind.Sequential)] public struct Player { public uint startingLP, startingDrawCount, drawCountPerTurn; }
    [StructLayout(LayoutKind.Sequential)] public struct Options {
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

    const uint LEADER = 880000634;
    const uint CHAR   = 880000001; // vanilla power 7000
    const uint FILLER = 880000881;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> avail = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();
    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    public static void LoadDb(string csv) {
        foreach (string line in File.ReadAllLines(csv)) { string[] f = line.Split(','); if (f.Length < 9) continue; ulong[] v = new ulong[9]; for (int i = 0; i < 9; ++i) v[i] = unchecked((ulong)long.Parse(f[i])); cardDb[(uint)v[0]] = v; }
    }
    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try { CardData data = new CardData(); data.code = code; ulong[] v;
            if (cardDb.TryGetValue(code, out v)) { data.type=(uint)v[1]; data.race=v[2]; data.level=(uint)v[3]; data.attribute=(uint)v[4]; data.category=(uint)v[5]; data.attack=(int)(long)v[7]; data.defense=(int)(long)v[8];
                ulong sc=v[6]; if(sc!=0){ IntPtr buf=Marshal.AllocHGlobal(10); int off=0; for(int s=0;s<4;++s){ ushort part=(ushort)((sc>>(16*s))&0xffff); if(part==0) continue; Marshal.WriteInt16(buf,off,(short)part); off+=2; } Marshal.WriteInt16(buf,off,0); data.setcodes=buf; } }
            else { data.type=1; data.race=2; }
            Marshal.StructureToPtr(data, output, false);
        } catch (Exception e) { callbackErrors.Add("card reader: " + e); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) { string t = Marshal.PtrToStringAnsi(message); if (t == null) t = ""; if (type == 0) errors.Add(t); }
    static int Load(IntPtr duel, string name) {
        foreach (string d in new string[] { expansionScripts, standardScripts, Path.Combine(standardScripts, "unofficial") }) { string path = Path.Combine(d, name); if (File.Exists(path)) { byte[] b = File.ReadAllBytes(path); return OCG_LoadScript(duel, b, (uint)b.Length, name); } }
        if (name != "c0.lua") callbackErrors.Add("missing script: " + name); return 0;
    }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name) { try { return Load(duel, Marshal.PtrToStringAnsi(name)); } catch (Exception e) { callbackErrors.Add("script reader: " + e); return 0; } }
    class Reader { public byte[] buf; public int pos; public Reader(byte[] b, int p){buf=b;pos=p;} public byte U8(){byte v=buf[pos];pos+=1;return v;} public uint U32(){uint v=BitConverter.ToUInt32(buf,pos);pos+=4;return v;} public ulong U64(){ulong v=BitConverter.ToUInt64(buf,pos);pos+=8;return v;} }
    static void RespondI32(IntPtr duel, int v) { OCG_DuelSetResponse(duel, BitConverter.GetBytes(v), 4); }

    public static int Run(string repo) {
        string release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        Options o = new Options(); o.seed0=1;o.seed1=2;o.seed2=3;o.seed3=4; o.flags=0x2000000000UL;
        Player pl = new Player(); pl.startingLP=5; pl.startingDrawCount=5; pl.drawCountPerTurn=1; o.team1=pl; o.team2=pl;
        o.cardReader=cardReader; o.scriptReader=scriptReader; o.logHandler=logHandler; o.cardReaderDone=cardReaderDone; o.enableUnsafeLibraries=1;
        IntPtr duel;
        if (OCG_CreateDuel(out duel, ref o) != 0 || duel == IntPtr.Zero) { Console.WriteLine("FAIL create"); return 2; }
        try {
            foreach (string name in new string[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" }) if (Load(duel, name) != 1) callbackErrors.Add("boot fail: " + name);
            // seat an ACTIVE character for BOTH players on turn 1 so it is un-sick from turn 2+
            string probe =
              "local pr=Effect.GlobalEffect() pr:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pr:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n" +
              "pr:SetOperation(function()\n" +
              "  if Duel.GetTurnCount()~=1 or opcg._seated then return end opcg._seated=true\n" +
              "  for p=0,1 do local c=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000001 end,p,LOCATION_DECK+LOCATION_HAND,0,nil):GetFirst()\n" +
              "    if c then Duel.MoveToField(c,p,p,LOCATION_MZONE,POS_FACEUP_ATTACK,true) end end\n" +
              "end) Duel.RegisterEffect(pr,0)\n";
            byte[] pb = System.Text.Encoding.UTF8.GetBytes(probe);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "probe.lua") != 1) callbackErrors.Add("probe fail");

            Action<int,uint,int> add = delegate(int p, uint code, int copies){ for(int k=0;k<copies;++k){ NewCard c=new NewCard(); c.team=(byte)p;c.duelist=0;c.code=code;c.con=(byte)p;c.loc=1;c.seq=0;c.pos=8; OCG_DuelNewCard(duel, ref c);} };
            add(0, LEADER, 1); add(0, CHAR, 1); add(0, FILLER, 44);
            add(1, LEADER, 1); add(1, CHAR, 1); add(1, FILLER, 44);
            OCG_StartDuel(duel);

            uint lastId=0; byte[] lastMsg=null; int newTurns=0; byte turnPlayer=0;
            for (int step=0; step<20000; ++step) {
                int st=OCG_DuelProcess(duel);
                uint length; IntPtr ptr=OCG_DuelGetMessage(duel, out length);
                byte[] all=new byte[length]; if(length>0) Marshal.Copy(ptr, all, 0, (int)length);
                int off=0;
                while(off+4<=all.Length){ uint pl2=BitConverter.ToUInt32(all,off); off+=4; if(pl2==0||off+pl2>all.Length) break; byte id=all[off]; byte[] payload=new byte[pl2]; Array.Copy(all,off,payload,0,(int)pl2); off+=(int)pl2; lastId=id; lastMsg=payload; if(id==40){ newTurns++; turnPlayer=payload[1]; } }
                if(st==0) break; if(st!=1) continue; if(lastMsg==null){ Console.WriteLine("FAIL no msg"); break; }
                if(lastId==11){ // idle: parse to the attackable block, record its size, then pass(7)
                    Reader r=new Reader(lastMsg,1); byte idlePlayer=r.U8();
                    uint n;
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();r.U64();r.U8();}
                    r.U8();r.U8();r.U8();
                    uint nAtk=r.U32();
                    string who = (idlePlayer==0)?"P0(first)":"P1(second)";
                    avail.Add("T"+newTurns+" "+who+" attackable="+nAtk);
                    RespondI32(duel, 7); // end phase, never attack (we only measure availability)
                }
                else if(lastId==12||lastId==13){ RespondI32(duel,0); }
                else if(lastId==14){ RespondI32(duel,0); }
                else if(lastId==16){ RespondI32(duel,-1); }
                else if(lastId==10){ Reader r=new Reader(lastMsg,1); r.U8(); uint n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();r.U64();r.U8();} n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();r.U8();} r.U8(); byte toEp=r.U8(); RespondI32(duel, toEp!=0?3:2); }
                else if(lastId==15){ Reader r=new Reader(lastMsg,1); r.U8();r.U8(); uint smin=r.U32(); r.U32(); if(smin==0){ OCG_DuelSetResponse(duel,new byte[8],8); continue; } byte[] resp=new byte[12]; Array.Copy(BitConverter.GetBytes((int)0),0,resp,0,4); Array.Copy(BitConverter.GetBytes((uint)1),0,resp,4,4); Array.Copy(BitConverter.GetBytes((uint)0),0,resp,8,4); OCG_DuelSetResponse(duel,resp,12); }
                else if(lastId==26){ RespondI32(duel,-1); }
                else if(lastId==25){ RespondI32(duel,-1); }
                else if(lastId==19){ RespondI32(duel,0x1); }
                else if(lastId==18||lastId==24){ Reader r=new Reader(lastMsg,1); byte player=r.U8(); byte need=r.U8(); uint flag=r.U32(); uint av=~flag; List<byte> resp=new List<byte>(); int given=0; for(int bit=0;bit<32&&given<Math.Max((int)need,1);++bit){ if((av&(1u<<bit))==0) continue; byte con=(byte)((bit>=16)?(1-player):player); int local=bit&0xf; byte loc=(byte)((local>=8)?8:4); byte seq=(byte)((local>=8)?(local-8):local); resp.Add(con);resp.Add(loc);resp.Add(seq); given++; } if(given==0){ Console.WriteLine("FAIL no zone"); break; } OCG_DuelSetResponse(duel, resp.ToArray(), (uint)resp.Count); }
                else { Console.WriteLine("FAIL unexpected id="+lastId); break; }
                if(newTurns>=5) break;
            }
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("--- attack availability by turn ---");
        foreach(string s in avail) Console.WriteLine(s);
        Console.WriteLine("errors="+errors.Count+" callbacks="+callbackErrors.Count);
        foreach(string e in errors) Console.WriteLine("SCRIPT: "+e);
        // P1 (second player) first acts on global turn 2; official OPCG lets the
        // second player attack on their first turn. Expect T2 P1 attackable>=1.
        bool p1t2 = false;
        foreach(string s in avail) if(s.StartsWith("T2 P1(second)") && !s.EndsWith("attackable=0")) p1t2 = true;
        Console.WriteLine(p1t2 ? "SECOND_PLAYER_T2_ATTACK: available (OK)" : "SECOND_PLAYER_T2_ATTACK: BLOCKED (bug)");
        return 0;
    }
}
'@
Add-Type -TypeDefinition $source -Language CSharp
[AtkAvail]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [AtkAvail]::Run((Resolve-Path -LiteralPath $Repo).Path)
