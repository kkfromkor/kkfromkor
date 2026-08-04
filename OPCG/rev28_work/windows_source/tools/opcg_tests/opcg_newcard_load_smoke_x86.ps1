param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Codes  # comma-separated card codes
)

# Generic new-card smoke: builds a headless duel with the given codes in a
# deck (plus a known-good leader), boots it, and pumps a few turns with
# pass-through responses. Any lua syntax error, RegisterCard schema failure,
# or missing script surfaces as a [script-error] line -> FAIL.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
public static class LoadSmoke {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReader(IntPtr payload, uint code, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void DataReaderDone(IntPtr payload, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int ScriptReader(IntPtr payload, IntPtr duel, IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate void LogHandler(IntPtr payload, IntPtr message, int type);
    [StructLayout(LayoutKind.Sequential)] public struct Player { public uint startingLP, startingDrawCount, drawCountPerTurn; }
    [StructLayout(LayoutKind.Sequential)] public struct Options { public ulong seed0, seed1, seed2, seed3, flags; public Player team1, team2; public DataReader cardReader; public IntPtr payload1; public ScriptReader scriptReader; public IntPtr payload2; public LogHandler logHandler; public IntPtr payload3; public DataReaderDone cardReaderDone; public IntPtr payload4; public byte enableUnsafeLibraries; }
    [StructLayout(LayoutKind.Sequential)] public struct NewCard { public byte team, duelist; public uint code; public byte con; public uint loc, seq, pos; }
    [StructLayout(LayoutKind.Sequential)] public struct CardData { public uint code, alias; public IntPtr setcodes; public uint type, level, attribute; public ulong race; public int attack, defense; public uint lscale, rscale, link_marker, category; }
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_CreateDuel(out IntPtr duel, ref Options options);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DestroyDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelNewCard(IntPtr duel, ref NewCard info);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_StartDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_DuelProcess(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr OCG_DuelGetMessage(IntPtr duel, out uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelSetResponse(IntPtr duel, byte[] buffer, uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_LoadScript(IntPtr duel, byte[] buffer, uint length, [MarshalAs(UnmanagedType.LPStr)] string name);
    const uint LEADER=880000634;
    static string standardScripts, expansionScripts;
    static int scriptErrors = 0;
    static readonly List<string> callbackErrors=new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb=new Dictionary<uint, ulong[]>();
    static readonly DataReader cardReader=ReadCard; static readonly DataReaderDone cardReaderDone=DoneCard; static readonly ScriptReader scriptReader=ReadScript; static readonly LogHandler logHandler=Log;
    public static void LoadDb(string csv){ foreach(string line in File.ReadAllLines(csv)){ string[] f=line.Split(','); if(f.Length<9) continue; ulong[] v=new ulong[9]; for(int i=0;i<9;++i) v[i]=unchecked((ulong)long.Parse(f[i])); cardDb[(uint)v[0]]=v; } }
    static void ReadCard(IntPtr payload, uint code, IntPtr output){ try{ CardData data=new CardData(); data.code=code; ulong[] v; if(cardDb.TryGetValue(code,out v)){ data.type=(uint)v[1];data.race=v[2];data.level=(uint)v[3];data.attribute=(uint)v[4];data.category=(uint)v[5];data.attack=(int)(long)v[7];data.defense=(int)(long)v[8]; ulong sc=v[6]; if(sc!=0){ IntPtr buf=Marshal.AllocHGlobal(10); int off=0; for(int s=0;s<4;++s){ ushort part=(ushort)((sc>>(16*s))&0xffff); if(part==0) continue; Marshal.WriteInt16(buf,off,(short)part); off+=2; } Marshal.WriteInt16(buf,off,0); data.setcodes=buf; } } else { data.type=1; data.race=2; callbackErrors.Add("NO CDB ROW for "+code); } Marshal.StructureToPtr(data,output,false);} catch(Exception e){ callbackErrors.Add("card: "+e.Message); } }
    static void DoneCard(IntPtr payload, IntPtr data){}
    static void Log(IntPtr payload, IntPtr message, int type){ string t=Marshal.PtrToStringAnsi(message); if(t==null) t=""; if(type==0){ scriptErrors++; Console.WriteLine("  [script-error] "+t); } }
    static int Load(IntPtr duel, string name){ foreach(string d in new string[]{expansionScripts,standardScripts,Path.Combine(standardScripts,"unofficial")}){ string path=Path.Combine(d,name); if(File.Exists(path)){ byte[] bb=File.ReadAllBytes(path); return OCG_LoadScript(duel,bb,(uint)bb.Length,name); } } if(name!="c0.lua") callbackErrors.Add("missing script: "+name); return 0; }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name){ try{ return Load(duel, Marshal.PtrToStringAnsi(name)); } catch(Exception e){ callbackErrors.Add("scr: "+e.Message); return 0; } }
    public static int Run(string repo, string codesCsv){
        string release=Path.Combine(repo,"bin","release"); Directory.SetCurrentDirectory(release);
        standardScripts=Path.Combine(release,"script"); expansionScripts=Path.Combine(release,"expansions","script");
        uint[] codes=Array.ConvertAll(codesCsv.Split(new char[]{','},StringSplitOptions.RemoveEmptyEntries), uint.Parse);
        Options o=new Options(); o.seed0=7;o.seed1=8;o.seed2=9;o.seed3=10; o.flags=0x2000000000UL;
        Player pl=new Player(); pl.startingLP=5;pl.startingDrawCount=5;pl.drawCountPerTurn=1; o.team1=pl;o.team2=pl;
        o.cardReader=cardReader;o.scriptReader=scriptReader;o.logHandler=logHandler;o.cardReaderDone=cardReaderDone;o.enableUnsafeLibraries=1;
        IntPtr duel; if(OCG_CreateDuel(out duel, ref o)!=0||duel==IntPtr.Zero){ Console.WriteLine("FAIL create"); return 2; }
        try {
            foreach(string name in new string[]{"constant.lua","utility.lua"}) if(Load(duel,name)!=1) Console.WriteLine("BOOT FAIL: "+name);
            NewCard c=new NewCard();
            for(int p=0;p<2;++p){
                c.team=(byte)p; c.duelist=0; c.con=(byte)p; c.pos=0x8; c.seq=0; c.loc=0x01;
                c.code=LEADER; OCG_DuelNewCard(duel,ref c);
                foreach(uint code in codes){ c.code=code; for(int k=0;k<4;++k) OCG_DuelNewCard(duel,ref c); }
                c.code=880000881; for(int k=0;k<40;++k) OCG_DuelNewCard(duel,ref c);
            }
            OCG_StartDuel(duel);
            int turns=0;
            for(int step=0; step<4000; ++step){
                int st=OCG_DuelProcess(duel);
                uint length; IntPtr ptr=OCG_DuelGetMessage(duel,out length);
                byte[] all=new byte[length]; if(length>0) Marshal.Copy(ptr,all,0,(int)length);
                int off=0; byte lastId=0; byte[] lastMsg=null;
                while(off+4<=all.Length){ uint pl2=BitConverter.ToUInt32(all,off); off+=4; if(pl2==0||off+pl2>all.Length) break; byte id=all[off]; byte[] m=new byte[pl2]; Array.Copy(all,off,m,0,(int)pl2); off+=(int)pl2; lastId=id; lastMsg=m; if(id==40) turns++; }
                if(st==0){ Console.WriteLine("duel ended, turns="+turns); break; }
                if(st!=1) continue; if(lastMsg==null) break;
                if(lastId==11||lastId==10){ OCG_DuelSetResponse(duel,BitConverter.GetBytes(7),4); }
                else if(lastId==15||lastId==20||lastId==26){ byte smin=0; if(lastMsg.Length>6) smin=lastMsg[3+0]; OCG_DuelSetResponse(duel,new byte[8],8); }
                else if(lastId==12||lastId==13){ OCG_DuelSetResponse(duel,BitConverter.GetBytes(0),4); }
                else if(lastId==14){ OCG_DuelSetResponse(duel,BitConverter.GetBytes(0),4); }
                else if(lastId==16){ OCG_DuelSetResponse(duel,BitConverter.GetBytes(-1),4); }
                else if(lastId==19){ OCG_DuelSetResponse(duel,BitConverter.GetBytes(1),4); }
                else if(lastId==18||lastId==24){ byte player=lastMsg[1]; byte need=lastMsg[2]; uint flag=BitConverter.ToUInt32(lastMsg,3); uint aw=~flag; List<byte> resp=new List<byte>(); int given=0; for(int bit=0;bit<32&&given<Math.Max((int)need,1);++bit){ if((aw&(1u<<bit))==0) continue; byte con=(byte)((bit>=16)?(1-player):player); int local=bit&0xf; byte loc=(byte)((local>=8)?8:4); byte seq=(byte)((local>=8)?(local-8):local); resp.Add(con);resp.Add(loc);resp.Add(seq); given++; } if(given==0) break; OCG_DuelSetResponse(duel,resp.ToArray(),(uint)resp.Count); }
                else if(lastId==25){ OCG_DuelSetResponse(duel,BitConverter.GetBytes(-1),4); }
                else break;
                if(turns>=6) break;
            }
        } finally { OCG_DestroyDuel(duel); }
        foreach(string e in callbackErrors) Console.WriteLine("CB/"+e);
        bool pass = scriptErrors==0 && callbackErrors.Count==0;
        Console.WriteLine("script_errors="+scriptErrors+" cb_errors="+callbackErrors.Count);
        Console.WriteLine(pass ? "NEWCARD_LOAD_SMOKE: PASS" : "NEWCARD_LOAD_SMOKE: FAIL");
        return pass ? 0 : 1;
    }
}
'@
Add-Type -TypeDefinition $source -Language CSharp
[LoadSmoke]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [LoadSmoke]::Run((Resolve-Path -LiteralPath $Repo).Path, $Codes)
