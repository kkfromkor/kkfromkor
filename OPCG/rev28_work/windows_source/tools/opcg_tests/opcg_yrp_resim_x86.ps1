param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$InputFile
)

# Bit-exact re-simulation of a real Multirole game from its inner-yrp data
# (seeds + flags + post-shuffle deck order + accepted responses). Mirrors the
# server duel creation 1:1 (Dueling.cpp): constant+utility only, decks fed in
# recorded order, POS_FACEDOWN_DEFENSE. Feeds recorded responses sequentially
# and logs every request the core makes; when a fed response draws MSG_RETRY,
# dumps the request and the response bytes. When responses run out, dumps the
# pending request in full - that is the exact moment the real duel died.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
public static class Resim {
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
    static string standardScripts, expansionScripts;
    static readonly List<string> callbackErrors = new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb = new Dictionary<uint, ulong[]>();
    static readonly DataReader cardReader = ReadCard; static readonly DataReaderDone cardReaderDone = DoneCard; static readonly ScriptReader scriptReader = ReadScript; static readonly LogHandler logHandler = Log;
    public static void LoadDb(string csv){ foreach(string line in File.ReadAllLines(csv)){ string[] f=line.Split(','); if(f.Length<9) continue; ulong[] v=new ulong[9]; for(int i=0;i<9;++i) v[i]=unchecked((ulong)long.Parse(f[i])); cardDb[(uint)v[0]]=v; } }
    static void ReadCard(IntPtr payload, uint code, IntPtr output){ try{ CardData data=new CardData(); data.code=code; ulong[] v; if(cardDb.TryGetValue(code,out v)){ data.type=(uint)v[1];data.race=v[2];data.level=(uint)v[3];data.attribute=(uint)v[4];data.category=(uint)v[5];data.attack=(int)(long)v[7];data.defense=(int)(long)v[8]; ulong sc=v[6]; if(sc!=0){ IntPtr buf=Marshal.AllocHGlobal(10); int off=0; for(int s=0;s<4;++s){ ushort part=(ushort)((sc>>(16*s))&0xffff); if(part==0) continue; Marshal.WriteInt16(buf,off,(short)part); off+=2; } Marshal.WriteInt16(buf,off,0); data.setcodes=buf; } } else { data.type=1; data.race=2; } Marshal.StructureToPtr(data,output,false);} catch(Exception e){ callbackErrors.Add("card: "+e.Message); } }
    static void DoneCard(IntPtr payload, IntPtr data){}
    static void Log(IntPtr payload, IntPtr message, int type){ string t=Marshal.PtrToStringAnsi(message); if(t==null) t=""; if(type==0||t.StartsWith("PROBE|")) Console.WriteLine("  [lua"+type+"] "+t); }
    static int Load(IntPtr duel, string name){ foreach(string d in new string[]{expansionScripts,standardScripts,Path.Combine(standardScripts,"unofficial")}){ string path=Path.Combine(d,name); if(File.Exists(path)){ byte[] bb=File.ReadAllBytes(path); return OCG_LoadScript(duel,bb,(uint)bb.Length,name); } } if(name!="c0.lua") callbackErrors.Add("missing: "+name); return 0; }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name){ try{ return Load(duel, Marshal.PtrToStringAnsi(name)); } catch(Exception e){ callbackErrors.Add("scr: "+e.Message); return 0; } }
    class Rd { public byte[] b; public int p; public Rd(byte[] bb,int pp){b=bb;p=pp;} public byte U8(){return b[p++];} public uint U32(){uint v=BitConverter.ToUInt32(b,p);p+=4;return v;} public ulong U64(){ulong v=BitConverter.ToUInt64(b,p);p+=8;return v;} }
    static readonly string[] IDLEACT = {"summon","spsummon","repos","mset","sset","activate","TO_BP","TO_EP","shuffle","ATTACK_t9"};
    static string Anno(byte[] r){
        if(r.Length==4){ int v=BitConverter.ToInt32(r,0); int act=v&0xffff; int idx=(v>>16)&0xffff; string s="i32="+v;
            if(v!=-1 && act>=0 && act<=9 && idx<200) s+=" [act="+IDLEACT[act]+" idx="+idx+"]"; if(v==-1) s+=" [decline/-1]"; return s; }
        if(r.Length==3) return "[place con="+r[0]+" loc="+r[1]+" seq="+r[2]+"]";
        return "";
    }
    static string DumpIdle(byte[] m){
        Rd r=new Rd(m,1); byte ip=r.U8();
        uint ns=r.U32(); for(uint i=0;i<ns;++i){r.U32();r.U8();r.U8();r.U32();}
        uint nsp=r.U32(); for(uint i=0;i<nsp;++i){r.U32();r.U8();r.U8();r.U32();}
        uint nr=r.U32(); for(uint i=0;i<nr;++i){r.U32();r.U8();r.U8();r.U8();}
        uint nm=r.U32(); for(uint i=0;i<nm;++i){r.U32();r.U8();r.U8();r.U32();}
        uint nss=r.U32(); for(uint i=0;i<nss;++i){r.U32();r.U8();r.U8();r.U32();}
        uint na=r.U32(); List<string> acts=new List<string>();
        for(uint i=0;i<na;++i){uint c=r.U32();r.U8();r.U8();r.U32();ulong d=r.U64();r.U8(); acts.Add(c+"/d"+(d&0xfffff));}
        byte bp=r.U8(); byte ep=r.U8(); byte sh=r.U8();
        uint natk=r.U32(); List<string> atks=new List<string>();
        for(uint i=0;i<natk;++i){uint c=r.U32();byte con=r.U8();byte loc=r.U8();byte seq=r.U8();byte dir=r.U8(); atks.Add(c+"@P"+con+"/"+loc+"/"+seq+(dir!=0?"/direct":""));}
        return "IDLE P"+ip+" summon="+ns+" sp="+nsp+" repos="+nr+" act="+nact(acts)+" to_bp="+bp+" to_ep="+ep+" ATTACKABLE="+natk+(natk>0?" ["+string.Join(", ",atks.ToArray())+"]":"");
    }
    static string nact(List<string> a){ return a.Count+(a.Count>0?" ["+string.Join(", ",a.ToArray())+"]":""); }
    static string DumpChain(byte[] m){
        Rd r=new Rd(m,1); byte ip=r.U8(); byte spe=r.U8(); byte forced=r.U8(); uint h0=r.U32(); uint h1=r.U32(); uint n=r.U32();
        List<string> es=new List<string>();
        for(uint i=0;i<n;++i){ uint code=r.U32(); byte con=r.U8(); byte loc=r.U8(); uint seq=r.U32(); uint pos=r.U32(); ulong desc=r.U64(); byte mode=r.U8();
            es.Add(code+"@P"+con+"/"+loc+"/"+seq+" desc="+desc+" mode="+mode); }
        return "SELECT_CHAIN P"+ip+" spe="+spe+" FORCED="+forced+" hint0=0x"+h0.ToString("x")+" hint1=0x"+h1.ToString("x")+" count="+n+(n>0?" { "+string.Join(" | ",es.ToArray())+" }":"");
    }
    static string DumpCardSel(byte[] m,byte id){
        Rd r=new Rd(m,1); byte ip=r.U8(); byte cancelable=r.U8(); uint mn=r.U32(); uint mx=r.U32(); uint n=r.U32();
        List<string> cs=new List<string>();
        for(uint i=0;i<n && i<24;++i){ uint code=r.U32(); byte con=r.U8(); byte loc=r.U8(); uint seq=r.U32(); uint pos=r.U32(); cs.Add(code+"@P"+con+"/"+loc+"/"+seq); }
        return (id==15?"SELECT_CARD":"SELECT_TRIBUTE")+" P"+ip+" cancelable="+cancelable+" min="+mn+" max="+mx+" n="+n+" { "+string.Join(", ",cs.ToArray())+" }";
    }
    static string MsgName(byte id){
        switch(id){ case 1:return "HINT"; case 10:return "SELECT_BATTLECMD"; case 11:return "SELECT_IDLECMD"; case 12:return "SELECT_EFFECTYN"; case 13:return "SELECT_YESNO"; case 14:return "SELECT_OPTION"; case 15:return "SELECT_CARD"; case 16:return "SELECT_CHAIN"; case 18:return "SELECT_PLACE"; case 19:return "SELECT_POSITION"; case 20:return "SELECT_TRIBUTE"; case 23:return "SORT_CARD"; case 24:return "SELECT_DISFIELD"; case 25:return "SELECT_SUM"; case 26:return "SELECT_UNSELECT_CARD"; case 31:return "RETRY"; case 40:return "NEW_TURN"; case 41:return "NEW_PHASE"; case 50:return "MOVE"; case 53:return "POS"; case 60:return "SET"; case 90:return "DRAW"; case 110:return "ATTACK"; case 111:return "BATTLE"; case 112:return "ATTACK_DISABLED"; case 132:return "ROCK_PAPER_SCISSORS"; case 133:return "HAND_RES"; default:return "msg"+id; } }
    static bool RequiresAnswer(byte id){ switch(id){ case 10:case 11:case 12:case 13:case 14:case 15:case 16:case 18:case 19:case 20:case 21:case 23:case 24:case 25:case 26:case 132:case 140:case 141:case 142:case 143:return true; default:return false; } }
    public static int Run(string repo, string inputFile){
        string release=Path.Combine(repo,"bin","release"); Directory.SetCurrentDirectory(release);
        standardScripts=Path.Combine(release,"script"); expansionScripts=Path.Combine(release,"expansions","script");
        string[] lines=File.ReadAllLines(inputFile);
        string[] seedS=lines[0].Split(' ');
        Options o=new Options();
        o.seed0=ulong.Parse(seedS[0]); o.seed1=ulong.Parse(seedS[1]); o.seed2=ulong.Parse(seedS[2]); o.seed3=ulong.Parse(seedS[3]);
        o.flags=ulong.Parse(lines[1]);
        string[] pp=lines[2].Split(' ');
        Player pl=new Player(); pl.startingLP=uint.Parse(pp[0]); pl.startingDrawCount=uint.Parse(pp[1]); pl.drawCountPerTurn=uint.Parse(pp[2]);
        o.team1=pl; o.team2=pl;
        o.cardReader=cardReader;o.scriptReader=scriptReader;o.logHandler=logHandler;o.cardReaderDone=cardReaderDone;o.enableUnsafeLibraries=1;
        Console.WriteLine("seeds="+o.seed0.ToString("x")+","+o.seed1.ToString("x")+","+o.seed2.ToString("x")+","+o.seed3.ToString("x")+" flags=0x"+o.flags.ToString("x")+" lp="+pl.startingLP);
        List<byte[]> resps=new List<byte[]>();
        for(int i=7;i<lines.Length;++i){ string h=lines[i].Trim(); if(h.Length==0) continue; byte[] r=new byte[h.Length/2]; for(int k=0;k<r.Length;++k) r[k]=Convert.ToByte(h.Substring(k*2,2),16); resps.Add(r); }
        Console.WriteLine("responses loaded: "+resps.Count);
        IntPtr duel; if(OCG_CreateDuel(out duel, ref o)!=0||duel==IntPtr.Zero){ Console.WriteLine("FAIL create"); return 2; }
        try {
            foreach(string name in new string[]{"constant.lua","utility.lua"}) if(Load(duel,name)!=1) Console.WriteLine("BOOT FAIL: "+name);
            string probe =
              "for _,fn in ipairs({'enqueue','enqueue_direct'}) do\n"+
              "  local orig=opcg.effect_queue[fn]\n"+
              "  if orig then opcg.effect_queue[fn]=function(handler,effect,...)\n"+
              "    local code=(handler and handler.GetOriginalCode) and handler:GetOriginalCode() or '?'\n"+
              "    local eid=(type(effect)=='table' and effect.effect_id) or '?'\n"+
              "    Debug.Message('PROBE|Q.'..fn..' '..tostring(code)..' '..tostring(eid))\n"+
              "    return orig(handler,effect,...)\n"+
              "  end end\n"+
              "end\n"+
              "if opcg.effect_queue and opcg.effect_queue.take then\n"+
              "  local otake=opcg.effect_queue.take\n"+
              "  opcg.effect_queue.take=function(ev,e)\n"+
              "    local item=otake(ev,e)\n"+
              "    if item and item.card and item.card.GetOriginalCode then\n"+
              "      Debug.Message('PROBE|TAKE '..item.card:GetOriginalCode()..' '..tostring(item.effect and item.effect.effect_id))\n"+
              "    end\n"+
              "    return item\n"+
              "  end\n"+
              "end\n"+
              "if opcg.effect_queue and opcg.effect_queue.EVENT_RESOLVE then\n"+
              "  local orse=Duel.RaiseSingleEvent\n"+
              "  Duel.RaiseSingleEvent=function(c,code,...)\n"+
              "    if code==opcg.effect_queue.EVENT_RESOLVE and c and c.GetOriginalCode then\n"+
              "      Debug.Message('PROBE|RESOLVE_RAISE '..c:GetOriginalCode())\n"+
              "    end\n"+
              "    return orse(c,code,...)\n"+
              "  end\n"+
              "end\n"+
              "local ap=Effect.GlobalEffect() ap:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) ap:SetCode(EVENT_ATTACK_ANNOUNCE)\n"+
              "ap:SetOperation(function()\n"+
              "  local a=Duel.GetAttacker()\n"+
              "  if a then local ok,err=pcall(function()\n"+
              "    local trig='?' if a.GetCardEffect then trig=tostring(a:GetCardEffect(EVENT_ATTACK_ANNOUNCE)~=nil) end\n"+
              "    local don='?' if opcg.GetAttachedDon then don=tostring(opcg.GetAttachedDon(a)) end\n"+
              "    local def='?' if opcg._definitions then def=tostring(opcg._definitions[a]~=nil) end\n"+
              "    Debug.Message('PROBE|ANNOUNCE atk='..a:GetOriginalCode()..' don='..don..' trig='..trig..' def='..def)\n"+
              "    if opcg.runtime and opcg.runtime.can_resolve then\n"+
              "      local okr,reason=opcg.runtime.can_resolve(a,'E1',{timing='WHEN_ATTACKING'})\n"+
              "      Debug.Message('PROBE|CANRESOLVE E1 ok='..tostring(okr)..' reason='..(type(reason)=='string' and reason or type(reason)))\n"+
              "    end\n"+
              "  end) if not ok then Debug.Message('PROBE|ANNOUNCE ERR '..tostring(err)) end end\n"+
              "end) Duel.RegisterEffect(ap,0)\n"+
              "local pr=Effect.GlobalEffect() pr:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pr:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
              "pr:SetOperation(function()\n"+
              "  local tc=Duel.GetTurnCount()\n"+
              "  Debug.Message('PROBE|turn='..tc..' tp='..Duel.GetTurnPlayer()..' tc0='..Duel.GetTurnCount(0)..' tc1='..Duel.GetTurnCount(1)..' atkr='..tostring(Duel.GetAttacker()))\n"+
              "  for p=0,1 do local ld=opcg.GetLeader(p)\n"+
              "    if ld then Debug.Message('PROBE|leaderdef P'..p..' code='..ld:GetOriginalCode()..' registered='..tostring(opcg._definitions~=nil and opcg._definitions[ld]~=nil)) end\n"+
              "  end\n"+
              "  for p=0,1 do\n"+
              "    local g=Duel.GetMatchingGroup(aux.TRUE,p,LOCATION_MZONE+LOCATION_FZONE,0,nil)\n"+
              "    for c in aux.Next(g) do\n"+
              "      local ok,err=pcall(function()\n"+
              "        local req='-' if opcg.battle and opcg.battle.required_attack_discard then req=tostring(opcg.battle.required_attack_discard(c,c:GetControler())) end\n"+
              "        Debug.Message('PROBE|P'..p..' '..c:GetOriginalCode()..' seq='..c:GetSequence()..' ldr='..tostring(opcg.IsLeader(c))..' chr='..tostring(opcg.IsCharacter(c))..' rested='..tostring(opcg.IsRested(c))..' tid='..tostring(c.GetTurnID and c:GetTurnID() or -1)..' noatk='..tostring(c:IsHasEffect(EFFECT_CANNOT_ATTACK)~=nil)..' noann='..tostring(c:IsHasEffect(EFFECT_CANNOT_ATTACK_ANNOUNCE)~=nil)..' atkdis='..tostring(c:IsHasEffect(EFFECT_ATTACK_DISABLED)~=nil)..' notgt='..tostring(c:IsHasEffect(EFFECT_CANNOT_BE_BATTLE_TARGET)~=nil)..' reqdisc='..req)\n"+
              "      end)\n"+
              "      if not ok then Debug.Message('PROBE|ERR '..tostring(err)) end\n"+
              "    end\n"+
              "  end\n"+
              "end) Duel.RegisterEffect(pr,0)\n";
            byte[] pb=System.Text.Encoding.UTF8.GetBytes(probe);
            if(OCG_LoadScript(duel,pb,(uint)pb.Length,"probe_resim.lua")!=1) Console.WriteLine("PROBE LOAD FAIL");
            for(int d=0; d<2; ++d){
                uint[] main=Array.ConvertAll(lines[3+d*2].Split(new char[]{' '},StringSplitOptions.RemoveEmptyEntries), uint.Parse);
                uint[] extra=Array.ConvertAll(lines[4+d*2].Split(new char[]{' '},StringSplitOptions.RemoveEmptyEntries), uint.Parse);
                NewCard c=new NewCard(); c.team=(byte)d; c.duelist=0; c.con=(byte)d; c.pos=0x8; c.seq=0;
                c.loc=0x01; foreach(uint code in main){ c.code=code; OCG_DuelNewCard(duel,ref c); }
                c.loc=0x40; foreach(uint code in extra){ c.code=code; OCG_DuelNewCard(duel,ref c); }
            }
            OCG_StartDuel(duel);
            int respIdx=0; int turn=0; byte lastReqId=0; byte[] lastReq=null; int fedForReq=-1;
            for(int step=0; step<200000; ++step){
                int st=OCG_DuelProcess(duel);
                uint length; IntPtr ptr=OCG_DuelGetMessage(duel,out length);
                byte[] all=new byte[length]; if(length>0) Marshal.Copy(ptr,all,0,(int)length);
                int off=0;
                while(off+4<=all.Length){
                    uint pl2=BitConverter.ToUInt32(all,off); off+=4; if(pl2==0||off+pl2>all.Length) break;
                    byte id=all[off]; byte[] m=new byte[pl2]; Array.Copy(all,off,m,0,(int)pl2); off+=(int)pl2;
                    if(id==40){ turn++; Console.WriteLine("\n=== TURN "+turn+" (P"+m[1]+") ==="); }
                    else if(id==41){ uint ph=(pl2>=3)?BitConverter.ToUInt16(m,1):(uint)m[1]; string pn; switch(ph){case 0x1:pn="DRAW";break;case 0x2:pn="STANDBY";break;case 0x4:pn="MAIN1";break;case 0x8:pn="BATTLE_START";break;case 0x10:pn="BATTLE_STEP";break;case 0x20:pn="DAMAGE";break;case 0x40:pn="DAMAGE_CAL";break;case 0x80:pn="BATTLE";break;case 0x100:pn="MAIN2";break;case 0x200:pn="END";break;default:pn="0x"+ph.ToString("x");break;} Console.WriteLine("  phase -> "+pn); }
                    else if(id==31){ Console.WriteLine("  *** RETRY *** core rejected resp["+fedForReq+"] for "+MsgName(lastReqId)); if(lastReqId==16&&lastReq!=null) Console.WriteLine("      pending was: "+DumpChain(lastReq)); else if(lastReqId==11&&lastReq!=null) Console.WriteLine("      pending was: "+DumpIdle(lastReq)); }
                    else if(id==110){ Console.WriteLine("  >>> ATTACK P"+m[1]+"/loc"+m[2]+"/"+BitConverter.ToUInt32(m,3)); }
                    else if(id==112){ Console.WriteLine("  !!! ATTACK_DISABLED"); }
                    else if(id==60){ Console.WriteLine("  SET"); }
                    else if(id==11){ lastReqId=11; lastReq=m; Console.WriteLine("  ? "+DumpIdle(m)); }
                    else if(id==16){ lastReqId=16; lastReq=m; Console.WriteLine("  ? "+DumpChain(m)); }
                    else if(id==15||id==20){ lastReqId=id; lastReq=m; Console.WriteLine("  ? "+DumpCardSel(m,id)); }
                    else if(RequiresAnswer(id)){ lastReqId=id; lastReq=m; Console.WriteLine("  ? "+MsgName(id)+" len="+pl2+(pl2<=48?" hex="+BitConverter.ToString(m).Replace("-",""):"")); }
                }
                if(st==0){ Console.WriteLine("\n[DUEL ENDED normally] fed "+respIdx+"/"+resps.Count); break; }
                if(st!=1) continue;
                if(respIdx<resps.Count){
                    byte[] r=resps[respIdx];
                    Console.WriteLine("  <- feed resp["+respIdx+"] len="+r.Length+" "+BitConverter.ToString(r).Replace("-","")+" "+Anno(r)+"  (answering "+MsgName(lastReqId)+")");
                    fedForReq=respIdx;
                    OCG_DuelSetResponse(duel,r,(uint)r.Length); respIdx++;
                } else {
                    Console.WriteLine("\n===== RESPONSES EXHAUSTED =====");
                    Console.WriteLine("pending request: "+MsgName(lastReqId));
                    if(lastReq!=null){
                        if(lastReqId==16) Console.WriteLine(DumpChain(lastReq));
                        else if(lastReqId==11) Console.WriteLine(DumpIdle(lastReq));
                        else if(lastReqId==15||lastReqId==20) Console.WriteLine(DumpCardSel(lastReq,lastReqId));
                        Console.WriteLine("raw: "+BitConverter.ToString(lastReq).Replace("-",""));
                    }
                    break;
                }
            }
        } finally { OCG_DestroyDuel(duel); }
        foreach(string e in callbackErrors) Console.WriteLine("CB/"+e);
        return 0;
    }
}
'@
Add-Type -TypeDefinition $source -Language CSharp
[Resim]::LoadDb("$PSScriptRoot\cdb_dump.csv")
exit [Resim]::Run((Resolve-Path -LiteralPath $Repo).Path, (Resolve-Path -LiteralPath $InputFile).Path)
