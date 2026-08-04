param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Scenario = ""
)

# OP13-002 Ace E2 repro: [DON!!x1][once/turn] "when you take damage OR your
# 6000+ base power character is KO'd, draw 1". Friend report: no draw on
# battle damage. Scenario: P1 leader = Ace with 1 DON attached (probe attaches
# at T2, DON persists until owner's next refresh), P0 leader attacks Ace at
# T3 -> P1 takes 1 damage -> expect a P1 draw during turn 3.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
public static class AceDraw {
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
    const uint LEADER0=880000634; const uint ACE=880001574; const uint FILLER=880000881;
    const uint KALGARA=880001074; const uint SHANDORA=880000847; const uint SAMURAI_EVT=880000178; const uint LAW=880002101;
    const uint REIJU=880000776; const uint KID=880000687; const uint KUZAN=880001493;
    const uint NEWKAL=880001552; const uint ZEPHYR=880001499; const uint EVT38=880000038;
    const uint PLANPE=880000055; // EB01-056: on-play [take 1 life to hand]: draw 1 -- cost => optional
    const uint ZOROL=880001473; const uint EVT1492=880001492; // OP12-020 Zoro leader / OP12-039 set-active event
    const uint TSURU=880000785; // OP06-051: on-play [trash 2]: OPPONENT returns one of THEIR chars to hand (opponent chooses)
    const uint ARAMAKI=880000777; // OP06-043: main ignition [trash 1 + return ANY cost<=2 char to owner deck bottom]: +3000
    const uint ZORO065=880001161; // OP09-065: on-play [return 1+ field DON (AT_LEAST)]: rush + rest -- proves 2-DON return
    static bool windowSeen=false; static int samuraiCand=-1; static bool lawListed=false;
    static bool orderSeen=false; static bool orderPicked=false; static int orderDraw=0;
    static bool kalgaraPlayed=false; static bool kalgaraLife=false;
    static bool kuzanArmed=false; static int kuzanDraw=0;
    static int lifeDraw=0; static bool zephyrPlayed=false; static int zpDraw=0;
    static bool evtActivated=false; static int reijuDraw=0;
    static bool planpePlayed=false; static bool optAsk=false; static bool optLife=false;
    static int optDraw=0; static int optChained=0; static bool zoroActive=false; static bool cost0Ok=false; static bool cost0NegOk=false;
    static bool tsuruPlayed=false; static bool bounceChooserP1=false; static bool bounced=false; static bool cost0RawOk=false;
    static bool aramakiActivated=false; static bool aramakiReturned=false; static bool dongOk=false;
    static int queueHintPush=0; static int queueHintClear=0;
    static string standardScripts, expansionScripts;
    static readonly List<string> callbackErrors=new List<string>();
    static readonly Dictionary<uint, ulong[]> cardDb=new Dictionary<uint, ulong[]>();
    static readonly DataReader cardReader=ReadCard; static readonly DataReaderDone cardReaderDone=DoneCard; static readonly ScriptReader scriptReader=ReadScript; static readonly LogHandler logHandler=Log;
    public static void LoadDb(string csv){ foreach(string line in File.ReadAllLines(csv)){ string[] f=line.Split(','); if(f.Length<9) continue; ulong[] v=new ulong[9]; for(int i=0;i<9;++i) v[i]=unchecked((ulong)long.Parse(f[i])); cardDb[(uint)v[0]]=v; } }
    static void ReadCard(IntPtr payload, uint code, IntPtr output){ try{ CardData data=new CardData(); data.code=code; ulong[] v; if(cardDb.TryGetValue(code,out v)){ data.type=(uint)v[1];data.race=v[2];data.level=(uint)v[3];data.attribute=(uint)v[4];data.category=(uint)v[5];data.attack=(int)(long)v[7];data.defense=(int)(long)v[8]; ulong sc=v[6]; if(sc!=0){ IntPtr buf=Marshal.AllocHGlobal(10); int off=0; for(int s=0;s<4;++s){ ushort part=(ushort)((sc>>(16*s))&0xffff); if(part==0) continue; Marshal.WriteInt16(buf,off,(short)part); off+=2; } Marshal.WriteInt16(buf,off,0); data.setcodes=buf; } } else { data.type=1; data.race=2; } Marshal.StructureToPtr(data,output,false);} catch(Exception e){ callbackErrors.Add("card: "+e.Message); } }
    static void DoneCard(IntPtr payload, IntPtr data){}
    static bool dlHit=false;
    static void Log(IntPtr payload, IntPtr message, int type){ string t=Marshal.PtrToStringAnsi(message); if(t==null) t=""; if(t.StartsWith("PROBE|DL p=1")&&t.Contains("processed=1")) dlHit=true; if(t.Contains("KUZAN positive")) kuzanArmed=true; if(t.Contains("SETACTIVE 880001473")) zoroActive=true; if(t.Contains("COST0 lv=0 cost=0")) cost0Ok=true; if(t.Contains("COST0N lv=0 cost=0")) cost0NegOk=true; if(t.Contains("COST0R lv=0 cost=0")) cost0RawOk=true; if(t.Contains("RETDON moved=2")) dongOk=true; if(type==0||t.StartsWith("PROBE|")) Console.WriteLine("  [lua"+type+"] "+t); }
    static int Load(IntPtr duel, string name){ foreach(string d in new string[]{expansionScripts,standardScripts,Path.Combine(standardScripts,"unofficial")}){ string path=Path.Combine(d,name); if(File.Exists(path)){ byte[] bb=File.ReadAllBytes(path); return OCG_LoadScript(duel,bb,(uint)bb.Length,name); } } if(name!="c0.lua") callbackErrors.Add("missing: "+name); return 0; }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name){ try{ return Load(duel, Marshal.PtrToStringAnsi(name)); } catch(Exception e){ callbackErrors.Add("scr: "+e.Message); return 0; } }
    class Rd { public byte[] b; public int p; public Rd(byte[] bb,int pp){b=bb;p=pp;} public byte U8(){return b[p++];} public uint U32(){uint v=BitConverter.ToUInt32(b,p);p+=4;return v;} public ulong U64(){ulong v=BitConverter.ToUInt64(b,p);p+=8;return v;} }
    static void RespondI32(IntPtr duel,int v){ OCG_DuelSetResponse(duel,BitConverter.GetBytes(v),4); }
    public static int Run(string repo, string scenario){
        callbackErrors.Clear(); dlHit=false; windowSeen=false; samuraiCand=-1; lawListed=false;
        orderSeen=false; orderPicked=false; orderDraw=0; kalgaraPlayed=false; kalgaraLife=false;
        kuzanArmed=false; kuzanDraw=0; lifeDraw=0; zephyrPlayed=false; zpDraw=0;
        evtActivated=false; reijuDraw=0; queueHintPush=0; queueHintClear=0;
        planpePlayed=false; optAsk=false; optLife=false; optDraw=0; optChained=0; zoroActive=false; cost0Ok=false; cost0NegOk=false;
        tsuruPlayed=false; bounceChooserP1=false; bounced=false; cost0RawOk=false; aramakiActivated=false; aramakiReturned=false; dongOk=false;
        bool kal = scenario=="kalgara"||scenario=="life99";
        string release=Path.Combine(repo,"bin","release"); Directory.SetCurrentDirectory(release);
        standardScripts=Path.Combine(release,"script"); expansionScripts=Path.Combine(release,"expansions","script");
        Options o=new Options(); o.seed0=11;o.seed1=22;o.seed2=33;o.seed3=44; o.flags=0x2000000000UL;
        Player pl=new Player(); pl.startingLP=5;pl.startingDrawCount=5;pl.drawCountPerTurn=1; o.team1=pl;o.team2=pl;
        o.cardReader=cardReader;o.scriptReader=scriptReader;o.logHandler=logHandler;o.cardReaderDone=cardReaderDone;o.enableUnsafeLibraries=1;
        IntPtr duel; if(OCG_CreateDuel(out duel, ref o)!=0||duel==IntPtr.Zero){ Console.WriteLine("FAIL create"); return 2; }
        int t3Draw=0; bool attacked=false; int newTurns=0;
        try {
            foreach(string name in new string[]{"constant.lua","utility.lua","opcg_bootstrap.lua"}) if(Load(duel,name)!=1) callbackErrors.Add("boot: "+name);
            string seat = (scenario=="ko"||scenario=="leaderblock")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local c=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000881 end,1,LOCATION_HAND+LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if c then local ok=Duel.MoveToField(c,1,1,LOCATION_MZONE,POS_FACEUP_DEFENSE,true)\n"+
                 "      Debug.Message('PROBE|seat ok='..tostring(ok)..' loc='..tostring(c:GetLocation())..' seq='..tostring(c:GetSequence())..' rested='..tostring(opcg.IsRested(c))..' chr='..tostring(opcg.IsCharacter(c)))\n"+
                 "    end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="order")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local c=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000687 end,0,LOCATION_HAND+LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if c then local ok=Duel.MoveToField(c,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true)\n"+
                 "      Debug.Message('PROBE|seat kid ok='..tostring(ok)..' loc='..tostring(c:GetLocation()))\n"+
                 "    end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="life99")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  local tc=Duel.GetTurnCount()\n"+
                 "  if tc==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local c=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880001552 end,0,LOCATION_HAND+LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if c then local ok=Duel.MoveToField(c,0,0,LOCATION_MZONE,POS_FACEUP_DEFENSE,true)\n"+
                 "      Debug.Message('PROBE|seat 1552 ok='..tostring(ok)..' loc='..tostring(c:GetLocation()))\n"+
                 "    end\n"+
                 "  end\n"+
                 "  if tc==3 then\n"+
                 "    local c=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880001552 end,0,LOCATION_MZONE,0,nil):GetFirst()\n"+
                 "    if c and not opcg.IsRested(c) then opcg.SetRested(c) Debug.Message('PROBE|re-rest 1552 (keep leader as sole attacker)') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="zephyr")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local z=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880001499 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if z then Duel.SendtoHand(z,0,REASON_RULE) Debug.Message('PROBE|zephyr to hand loc='..tostring(z:GetLocation())) end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="reiju")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local z=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000038 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if z then Duel.SendtoHand(z,0,REASON_RULE) Debug.Message('PROBE|evt38 to hand') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : "";
            string battleProbe =
              "for _,ev in ipairs({{EVENT_BATTLE_START,'BSTART'},{EVENT_PRE_DAMAGE_CALCULATE,'PREDMG'},{EVENT_BATTLED,'BATTLED'},{EVENT_DAMAGE_STEP_END,'DSEND'}}) do\n"+
              "  local e=Effect.GlobalEffect() e:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) e:SetCode(ev[1])\n"+
              "  e:SetOperation(function()\n"+
              "    local a,t=Duel.GetAttacker(),Duel.GetAttackTarget()\n"+
              "    Debug.Message('PROBE|'..ev[2]..' atk='..tostring(a and a:GetOriginalCode())..'/'..tostring(a and a:GetAttack())..' tgt='..tostring(t and t:GetOriginalCode())..'/'..tostring(t and t:GetAttack())..' tgtldr='..tostring(t and opcg.IsLeader(t))..' canceled='..tostring(a and a:IsStatus(STATUS_ATTACK_CANCELED)))\n"+
              "  end)\n"+
              "  Duel.RegisterEffect(e,0)\n"+
              "end\n";
            string cancelProbe =
              "local origCAT=Duel.ChangeAttackTarget\n"+
              "Duel.ChangeAttackTarget=function(tc,noc)\n"+
              "  local a=Duel.GetAttacker()\n"+
              "  Debug.Message('PROBE|CAT-pre canceled='..tostring(a and a:IsStatus(STATUS_ATTACK_CANCELED)))\n"+
              "  local r=origCAT(tc,noc)\n"+
              "  Debug.Message('PROBE|CAT-post ret='..tostring(r)..' canceled='..tostring(a and a:IsStatus(STATUS_ATTACK_CANCELED)))\n"+
              "  return r\n"+
              "end\n"+
              "local origSR=opcg.SetRested\n"+
              "opcg.SetRested=function(c,...)\n"+
              "  local r=origSR(c,...)\n"+
              "  local a=Duel.GetAttacker()\n"+
              "  if a then Debug.Message('PROBE|SetRested('..c:GetOriginalCode()..') atkcanceled='..tostring(a:IsStatus(STATUS_ATTACK_CANCELED))) end\n"+
              "  return r\n"+
              "end\n";
            string lawProbe = (scenario=="law")
              ? ("local lw=Effect.GlobalEffect() lw:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) lw:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "lw:SetOperation(function()\n"+
                 "  local tc=Duel.GetTurnCount()\n"+
                 "  if tc==5 then local ld=opcg.GetLeader(0)\n"+
                 "    if ld then\n"+
                 "      Debug.Message('PROBE|LAW code='..ld:GetOriginalCode()..' def='..tostring(opcg._definitions and opcg._definitions[ld]~=nil))\n"+
                 "      if opcg.runtime and opcg.runtime.can_resolve then\n"+
                 "        local ok,reason=opcg.runtime.can_resolve(ld,'E1',{timing='ACTIVATE_MAIN'})\n"+
                 "        Debug.Message('PROBE|LAW canresolve='..tostring(ok)..' reason='..(type(reason)=='string' and reason or type(reason)))\n"+
                 "      end\n"+
                 "    end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(lw,0)\n")
              : "";
            string samProbe = (scenario=="samurai")
              ? ("local sm=Effect.GlobalEffect() sm:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) sm:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "sm:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==3 and not opcg._sam then opcg._sam=true\n"+
                 "    local ev=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000178 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if ev then Duel.SendtoHand(ev,0,REASON_RULE) Debug.Message('PROBE|evt sent to hand') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(sm,0)\n")
              : "";
            string orderProbe = (scenario=="order")
              ? ("local od=Effect.GlobalEffect() od:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) od:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "od:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==3 and not opcg._ord then opcg._ord=true\n"+
                 "    local mv=opcg.ReturnDon(0,1)\n"+
                 "    Debug.Message('PROBE|ORDER returned='..tostring(mv))\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(od,0)\n")
              : "";
            string kuzanProbe = (scenario=="kuzan")
              ? ("local kz=Effect.GlobalEffect() kz:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) kz:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "kz:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==3 and not opcg._kz then opcg._kz=true\n"+
                 "    local ld=opcg.GetLeader(0)\n"+
                 "    Debug.Message('PROBE|KUZAN positive: navy-source effect discards 1')\n"+
                 "    OPCGCore.ExecuteAction('TRASH_HAND', {count=1}, {card=ld, player=0})\n"+
                 "    local sh=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000847 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    Debug.Message('PROBE|KUZAN cost positive: navy-source COST discards 1')\n"+
                 "    OPCGCore.PayCost('TRASH_HAND', {count=1}, {card=ld, player=0})\n"+
                 "    Debug.Message('PROBE|KUZAN negative: non-navy source discards 1')\n"+
                 "    OPCGCore.ExecuteAction('TRASH_HAND', {count=1}, {card=sh, player=0})\n"+
                 "    Debug.Message('PROBE|KUZAN cost negative: non-navy COST discards 1')\n"+
                 "    OPCGCore.PayCost('TRASH_HAND', {count=1}, {card=sh, player=0})\n"+
                 "    Debug.Message('PROBE|KUZAN done')\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(kz,0)\n")
              : (scenario=="optaccept"||scenario=="optdecline")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local z=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000055 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if z then Duel.SendtoHand(z,0,REASON_RULE) Debug.Message('PROBE|planpe to hand') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="zoro")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local z=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880001492 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if z then Duel.SendtoHand(z,0,REASON_RULE) Debug.Message('PROBE|evt1492 to hand') end\n"+
                 "  end\n"+
                 "  local ld0=opcg.GetLeader(0)\n"+
                 "  if ld0 then Debug.Message('PROBE|ZORO t'..Duel.GetTurnCount()..' rested='..tostring(opcg.IsRested(ld0))) end\n"+
                 "end) Duel.RegisterEffect(st,0)\n"+
                 "local osa=opcg.SetActive opcg.SetActive=function(c,...) Debug.Message('PROBE|SETACTIVE '..tostring(c and c.GetOriginalCode and c:GetOriginalCode())) return osa(c,...) end\n"+
                 "local lastph=nil\n"+
                 "local pw=Effect.GlobalEffect() pw:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pw:SetCode(EVENT_ADJUST)\n"+
                 "pw:SetOperation(function() local ph=Duel.GetCurrentPhase() if ph~=lastph then lastph=ph Debug.Message('PROBE|phase='..ph..' t'..Duel.GetTurnCount()) end end)\n"+
                 "Duel.RegisterEffect(pw,0)\n")
              : (scenario=="bounce")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local z=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000785 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if z then Duel.SendtoHand(z,0,REASON_RULE) Debug.Message('PROBE|tsuru to hand') end\n"+
                 "    local f=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000881 end,1,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if f then Duel.SpecialSummon(f,0,1,1,true,false,POS_FACEUP_ATTACK) Debug.Message('PROBE|filler summoned to P1 mzone') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="aramaki")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==1 and not opcg._seat then opcg._seat=true\n"+
                 "    local a=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000777 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if a then Duel.SpecialSummon(a,0,0,0,true,false,POS_FACEUP_ATTACK) Debug.Message('PROBE|aramaki summoned to P0 mzone') end\n"+
                 "    local f=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000847 end,1,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if f then Duel.SpecialSummon(f,0,1,1,true,false,POS_FACEUP_ATTACK) Debug.Message('PROBE|shandora summoned to P1 mzone') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="dong")
              ? ("local ord=opcg.ReturnDon opcg.ReturnDon=function(p,mx,ch,st2,mi) local r=ord(p,mx,ch,st2,mi) Debug.Message('PROBE|RETDON moved='..tostring(r)..' max='..tostring(mx)) return r end\n"+
                 "local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==3 and not opcg._seat then opcg._seat=true\n"+
                 "    local z=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880001161 end,0,LOCATION_DECK,0,nil):GetFirst()\n"+
                 "    if z then Duel.SpecialSummon(z,0,0,0,true,false,POS_FACEUP_ATTACK) Debug.Message('PROBE|zoro065 summoned') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : (scenario=="zerocost")
              ? ("local st=Effect.GlobalEffect() st:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) st:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
                 "st:SetOperation(function()\n"+
                 "  if Duel.GetTurnCount()==3 and not opcg._zc then opcg._zc=true\n"+
                 "    local ch=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000847 end,0,LOCATION_MZONE,0,nil):GetFirst()\n"+
                 "    if ch then\n"+
                 "      local act={amount=-1, duration=[[THIS_TURN]], selector={kind=[[SELF]], count=1, mode=[[UP_TO]]}}\n"+
                 "      OPCGCore.ExecuteAction('MODIFY_COST', act, {card=ch, player=0})\n"+
                 "      Debug.Message('PROBE|COST0 lv='..ch:GetLevel()..' cost='..opcg.GetCost(ch))\n"+
                 "      OPCGCore.ExecuteAction('MODIFY_COST', act, {card=ch, player=0})\n"+
                 "      Debug.Message('PROBE|COST0N lv='..ch:GetLevel()..' cost='..opcg.GetCost(ch))\n"+
                 "      local e=Effect.CreateEffect(ch) e:SetType(EFFECT_TYPE_SINGLE) e:SetCode(EFFECT_UPDATE_LEVEL) e:SetValue(-5) e:SetReset(RESET_EVENT+RESETS_STANDARD) ch:RegisterEffect(e)\n"+
                 "      Debug.Message('PROBE|COST0R lv='..ch:GetLevel()..' cost='..opcg.GetCost(ch))\n"+
                 "    else Debug.Message('PROBE|COST0 no char') end\n"+
                 "  end\n"+
                 "end) Duel.RegisterEffect(st,0)\n")
              : "";
            string probe = seat + lawProbe + samProbe + orderProbe + kuzanProbe + battleProbe + cancelProbe +
              "local Qz=opcg.effect_queue\n"+
              "local ofl=Qz.flush Qz.flush=function(...) local n=Qz.pending_count() local r=ofl(...) if n>0 or r then Debug.Message('PROBE|flush n='..n..' raised='..tostring(r)..' ch='..Duel.GetCurrentChain()..' infl='..tostring(Qz._inflight)) end return r end\n"+
              "local oac=Qz.after_chain Qz.after_chain=function(...) if Qz.pending_count()>0 or Qz.direct_pending_count()>0 then Debug.Message('PROBE|AC n='..Qz.pending_count()..' d='..Qz.direct_pending_count()..' infl='..tostring(Qz._inflight)) end return oac(...) end\n"+
              "local orig_rt=opcg.effect_queue.resolve_timing\n"+
              "opcg.effect_queue.resolve_timing=function(cards,timing,event,...)\n"+
              "  if timing=='ON_DAMAGE_OR_HIGH_POWER_CHARACTER_KO' then\n"+
              "    local n=0 if type(cards)=='table' then n=#cards end\n"+
              "    Debug.Message('PROBE|RT n='..n..' dmg='..tostring(event and event.damage))\n"+
              "  end\n"+
              "  return orig_rt(cards,timing,event,...)\n"+
              "end\n"+
              "local orig_dl=opcg.life.damage_leader\n"+
              "opcg.life.damage_leader=function(player,amount,context)\n"+
              "  local r=orig_dl(player,amount,context)\n"+
              "  local pr='?' if type(r)=='table' then pr=tostring(r.processed) end\n"+
              "  Debug.Message('PROBE|DL p='..tostring(player)..' amt='..tostring(amount)..' processed='..pr)\n"+
              "  return r\n"+
              "end\n"+
              "if OPCGCore and OPCGCore.CheckCondition then\n"+
              "  local oc=OPCGCore.CheckCondition\n"+
              "  OPCGCore.CheckCondition=function(op,condition,context,...)\n"+
              "    local r=oc(op,condition,context,...)\n"+
              "    if op=='EVENT_DAMAGE_OR_TARGET_BASE_POWER_GTE' then\n"+
              "      Debug.Message('PROBE|COND '..tostring(r)..' dmg='..tostring(context and (context.damage or context.event_damage)))\n"+
              "    end\n"+
              "    return r\n"+
              "  end\n"+
              "end\n"+
              "local pr=Effect.GlobalEffect() pr:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pr:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n"+
              "pr:SetOperation(function()\n"+
              "  local tc=Duel.GetTurnCount()\n"+
              "  local ld=opcg.GetLeader(1)\n"+
              ((kal)
               ? "  if tc==3 and not opcg._ace_don then opcg._ace_don=true\n"+
                 "    local ld0=opcg.GetLeader(0)\n"+
                 "    if ld0 then local given=opcg.GiveDon(0,ld0,1,'ACTIVE')\n"+
                 "      Debug.Message('PROBE|T3 gave='..tostring(given)..' attached='..tostring(opcg.GetAttachedDon(ld0))) end\n"+
                 "  end\n"
               : "  if tc==2 and ld and not opcg._ace_don then opcg._ace_don=true\n"+
                 "    local given=opcg.GiveDon(1,ld,1,'ACTIVE')\n"+
                 "    Debug.Message('PROBE|T2 gave='..tostring(given)..' attached='..tostring(opcg.GetAttachedDon(ld)))\n"+
                 "  end\n")+
              "  if tc==3 and ld then Debug.Message('PROBE|T3 attached='..tostring(opcg.GetAttachedDon(ld)))\n"+
              "    local ld0=opcg.GetLeader(0)\n"+
              "    if ld0 and ld0.GetAttackableTarget then\n"+
              "      local tg=ld0:GetAttackableTarget() local codes={}\n"+
              "      if tg then for x in aux.Next(tg) do codes[#codes+1]=x:GetOriginalCode() end end\n"+
              "      Debug.Message('PROBE|T3 P0leader targets='..table.concat(codes,','))\n"+
              "    end\n"+
              "    local ch=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880000881 end,1,LOCATION_MZONE,0,nil):GetFirst()\n"+
              "    if ch and not opcg.IsRested(ch) then opcg.SetRested(ch) end\n"+
              "    if ch then Debug.Message('PROBE|char notgt='..tostring(ch:IsHasEffect(EFFECT_CANNOT_BE_BATTLE_TARGET)~=nil)..' pos='..tostring(ch:GetPosition())) end\n"+
              "  end\n"+
              "end) Duel.RegisterEffect(pr,0)\n";
            byte[] pb=System.Text.Encoding.UTF8.GetBytes(probe);
            if(OCG_LoadScript(duel,pb,(uint)pb.Length,"probe.lua")!=1) callbackErrors.Add("probe fail");
            Action<int,uint,int> add=delegate(int p,uint code,int copies){ for(int k=0;k<copies;++k){ NewCard c=new NewCard(); c.team=(byte)p;c.duelist=0;c.code=code;c.con=(byte)p;c.loc=1;c.seq=0;c.pos=8; OCG_DuelNewCard(duel,ref c);} };
            if(scenario=="kalgara"){ add(0,KALGARA,1); add(0,SHANDORA,45); }
            else if(scenario=="life99"){ add(0,KALGARA,1); add(0,NEWKAL,1); add(0,SHANDORA,44); }
            else if(scenario=="zephyr"){ add(0,KUZAN,1); add(0,ZEPHYR,1); add(0,SHANDORA,44); }
            else if(scenario=="reiju"){ add(0,REIJU,1); add(0,EVT38,1); add(0,SHANDORA,44); }
            else if(scenario=="samurai"){ add(0,ACE,1); add(0,SAMURAI_EVT,4); add(0,SHANDORA,41); }
            else if(scenario=="law"){ add(0,LAW,1); add(0,SHANDORA,45); }
            else if(scenario=="order"){ add(0,REIJU,1); add(0,KID,1); add(0,SHANDORA,44); }
            else if(scenario=="kuzan"){ add(0,KUZAN,1); add(0,SHANDORA,45); }
            else if(scenario=="optaccept"||scenario=="optdecline"){ add(0,ACE,1); add(0,PLANPE,1); add(0,SHANDORA,44); }
            else if(scenario=="zoro"){ add(0,ZOROL,1); add(0,EVT1492,1); add(0,SHANDORA,44); }
            else if(scenario=="zerocost"){ add(0,ACE,1); add(0,SHANDORA,45); }
            else if(scenario=="bounce"){ add(0,ACE,1); add(0,TSURU,1); add(0,SHANDORA,44); }
            else if(scenario=="aramaki"){ add(0,ACE,1); add(0,ARAMAKI,1); add(0,SHANDORA,44); }
            else if(scenario=="dong"){ add(0,ACE,1); add(0,ZORO065,1); add(0,SHANDORA,44); }
            else { add(0,ACE,1); add(0,FILLER,45); }
            add(1,(scenario=="leaderblock")?LEADER0:ACE,1); add(1,(scenario=="aramaki")?SHANDORA:FILLER,45);
            OCG_StartDuel(duel);
            uint lastId=0; byte[] lastMsg=null; int samuraiSummons=0;
            for(int step=0; step<20000; ++step){
                try {
                int st=OCG_DuelProcess(duel);
                uint length; IntPtr ptr=OCG_DuelGetMessage(duel,out length);
                byte[] all=new byte[length]; if(length>0) Marshal.Copy(ptr,all,0,(int)length);
                int off=0;
                while(off+4<=all.Length){
                    uint pl2=BitConverter.ToUInt32(all,off); off+=4; if(pl2==0||off+pl2>all.Length) break;
                    byte id=all[off]; byte[] m=new byte[pl2]; Array.Copy(all,off,m,0,(int)pl2); off+=(int)pl2;
                    lastId=id; lastMsg=m;
                    if(id==40) newTurns++;
                    else if(id==2 && m.Length>=2){ if(m[1]==210) queueHintPush++; else if(m[1]==212) queueHintClear++; }
                    else if(id==110){ attacked=true; Console.WriteLine("  ATTACK seen (turn "+newTurns+")"); }
                    else if(id==90){ byte dp=m[1]; uint cnt=BitConverter.ToUInt32(m,2);
                        if(newTurns==3){ Console.WriteLine("  DRAW turn3 P"+dp+" x"+cnt); if(dp==1) t3Draw+=(int)cnt; }
                        if(scenario=="order" && orderPicked && dp==0){ orderDraw+=(int)cnt; Console.WriteLine("  ORDER: P0 draw x"+cnt+" after order pick (Reiju mandatory resolved)"); }
                        if(scenario=="kuzan" && kuzanArmed && dp==0){ kuzanDraw+=(int)cnt; Console.WriteLine("  KUZAN: P0 draw x"+cnt+" after probe discard"); }
                        if(scenario=="life99" && kalgaraLife && dp==0){ lifeDraw+=(int)cnt; Console.WriteLine("  LIFE99: P0 draw x"+cnt+" after take-life (OP12-099 fired)"); }
                        if(scenario=="zephyr" && zephyrPlayed && dp==0){ zpDraw+=(int)cnt; Console.WriteLine("  ZEPHYR: P0 draw x"+cnt+" after effect discard (kuzan leader fired)"); }
                        if(scenario=="reiju" && evtActivated && dp==0){ reijuDraw+=(int)cnt; Console.WriteLine("  REIJU: P0 draw x"+cnt+" after DON-return cost (leader fired)"); }
                        if((scenario=="optaccept"||scenario=="optdecline") && planpePlayed && dp==0 && newTurns==1){ optDraw+=(int)cnt; Console.WriteLine("  OPT: P0 draw x"+cnt+" after planpe play (t1)"); } }
                    else if(id==50 && m.Length>=25 && kal){
                        uint mc=BitConverter.ToUInt32(m,1); byte pctl=m[5], ploc=m[6], cctl=m[15], cloc=m[16];
                        if(mc==SHANDORA && cctl==0 && cloc==4 && ploc==2){ kalgaraPlayed=true; Console.WriteLine("  KALGARA: shandora HAND->MZONE (mid-attack play landed)"); }
                        if(pctl==0 && ploc==0x40 && cctl==0 && cloc==2){ kalgaraLife=true; Console.WriteLine("  KALGARA: life EXTRA->HAND (take-life resolved)"); } }
                    else if(id==50 && m.Length>=25 && scenario=="zephyr"){
                        uint mc=BitConverter.ToUInt32(m,1); byte ploc=m[6], cctl=m[15], cloc=m[16];
                        if(mc==ZEPHYR && cctl==0 && cloc==4 && ploc==2){ zephyrPlayed=true; Console.WriteLine("  ZEPHYR: HAND->MZONE (played for real)"); } }
                    else if(id==50 && m.Length>=25 && (scenario=="optaccept"||scenario=="optdecline")){
                        uint mc=BitConverter.ToUInt32(m,1); byte pctl=m[5], ploc=m[6], cctl=m[15], cloc=m[16];
                        if(mc==PLANPE && cctl==0 && cloc==4 && ploc==2){ planpePlayed=true; Console.WriteLine("  OPT: PLANPE HAND->MZONE (played)"); }
                        if(pctl==0 && ploc==0x40 && cctl==0 && cloc==2){ optLife=true; Console.WriteLine("  OPT: life EXTRA->HAND (cost paid)"); } }
                    else if(id==70 && m.Length>=5 && (scenario=="optaccept"||scenario=="optdecline")){
                        uint cc=BitConverter.ToUInt32(m,1);
                        if(cc==PLANPE){ optChained++; Console.WriteLine("  OPT: CHAINING for PLANPE (core activation notation)"); } }
                    else if(id==50 && m.Length>=25 && scenario=="bounce"){
                        uint mc=BitConverter.ToUInt32(m,1); byte pctl=m[5], ploc=m[6], cctl=m[15], cloc=m[16];
                        if(mc==TSURU && cctl==0 && cloc==4 && ploc==2){ tsuruPlayed=true; Console.WriteLine("  BOUNCE: TSURU played"); }
                        if(mc==FILLER && pctl==1 && ploc==4 && cctl==1 && cloc==2){ bounced=true; Console.WriteLine("  BOUNCE: P1 char MZONE->HAND (bounced)"); } }
                    else if(id==50 && m.Length>=25 && scenario=="aramaki"){
                        uint mc=BitConverter.ToUInt32(m,1); byte pctl=m[5], ploc=m[6], cctl=m[15], cloc=m[16];
                        if(mc==SHANDORA && pctl==1 && ploc==4 && cctl==1 && cloc==1){ aramakiReturned=true; Console.WriteLine("  ARAMAKI: P1 char MZONE->DECK (returned to owner deck)"); } }
                }
                if(st==0) break; if(st!=1) continue; if(lastMsg==null) break;
                if(lastId==11){
                    Rd r=new Rd(lastMsg,1); byte ip=r.U8();
                    uint n;
                    List<string> sumCodes=new List<string>();
                    uint nsum=r.U32(); for(uint i=0;i<nsum;++i){uint sc2=r.U32();r.U8();r.U8();r.U32(); sumCodes.Add(sc2.ToString());}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U8();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    n=r.U32(); for(uint i=0;i<n;++i){r.U32();r.U8();r.U8();r.U32();}
                    uint nact=r.U32(); int evtIdx=-1; List<string> actCodes=new List<string>();
                    for(uint i=0;i<nact;++i){uint c2=r.U32();r.U8();r.U8();r.U32();r.U64();r.U8(); actCodes.Add(c2.ToString()); if(c2==SAMURAI_EVT&&evtIdx<0) evtIdx=(int)i;}
                    if(scenario=="samurai" && ip==0 && newTurns==3) Console.WriteLine("  T3 IDLE acts=["+string.Join(",",actCodes.ToArray())+"]");
                    r.U8();r.U8();r.U8();
                    uint natk=r.U32();
                    if(scenario=="law" && ip==0){
                        int lawIdx=-1;
                        for(int i2=0;i2<actCodes.Count;++i2){ if(actCodes[i2]==LAW.ToString()){ lawIdx=i2; break; } }
                        if(newTurns>=5 && lawIdx>=0 && !lawListed){ lawListed=true; Console.WriteLine("  T"+newTurns+" LAW ignition listed idx="+lawIdx+" -> activate"); RespondI32(duel,(lawIdx<<16)|5); }
                        else RespondI32(duel,7);
                    }
                    else if(scenario=="samurai" && ip==0){
                        if(newTurns==1 && samuraiSummons==0 && nsum>0){ samuraiSummons++; Console.WriteLine("  T1 summon"); RespondI32(duel,0); }
                        else if(newTurns==3 && samuraiSummons==1 && nsum>0){ samuraiSummons++; Console.WriteLine("  T3 summon (sick)"); RespondI32(duel,0); }
                        else if(newTurns==3 && evtIdx>=0 && samuraiCand<0){ Console.WriteLine("  T3 activate evt idx="+evtIdx); RespondI32(duel,(evtIdx<<16)|5); }
                        else RespondI32(duel,7);
                    }
                    else if(scenario=="zephyr" && ip==0){
                        int zi=-1; for(int i2=0;i2<sumCodes.Count;++i2){ if(sumCodes[i2]==ZEPHYR.ToString()){ zi=i2; break; } }
                        if(newTurns>=5 && zi>=0 && samuraiSummons==0){ samuraiSummons++; Console.WriteLine("  T"+newTurns+" summon ZEPHYR idx="+zi+" (real main-phase play)"); RespondI32(duel,(zi<<16)|0); }
                        else RespondI32(duel,7);
                    }
                    else if(scenario=="reiju" && ip==0){
                        int ei=-1; for(int i2=0;i2<actCodes.Count;++i2){ if(actCodes[i2]==EVT38.ToString()){ ei=i2; break; } }
                        if(newTurns>=5 && ei>=0 && !evtActivated){ evtActivated=true; Console.WriteLine("  T"+newTurns+" activate EVT38 idx="+ei+" (DON-1 cost inside native chain)"); RespondI32(duel,(ei<<16)|5); }
                        else RespondI32(duel,7);
                    }
                    else if((scenario=="optaccept"||scenario=="optdecline") && ip==0){
                        Console.WriteLine("  T"+newTurns+" IDLE sum=["+string.Join(",",sumCodes.ToArray())+"] act=["+string.Join(",",actCodes.ToArray())+"]");
                        int pi=-1; for(int i2=0;i2<sumCodes.Count;++i2){ if(sumCodes[i2]==PLANPE.ToString()){ pi=i2; break; } }
                        if(pi>=0 && !planpePlayed){ Console.WriteLine("  T"+newTurns+" summon PLANPE idx="+pi); RespondI32(duel,(pi<<16)|0); }
                        else RespondI32(duel,7);
                    }
                    else if(scenario=="zerocost" && ip==0){
                        if(newTurns==1 && samuraiSummons==0 && nsum>0){ samuraiSummons++; Console.WriteLine("  T1 summon shandora (cost1 seed)"); RespondI32(duel,0); }
                        else RespondI32(duel,7);
                    }
                    else if(scenario=="bounce" && ip==0){
                        int ti=-1; for(int i2=0;i2<sumCodes.Count;++i2){ if(sumCodes[i2]==TSURU.ToString()){ ti=i2; break; } }
                        if(newTurns>=5 && ti>=0 && samuraiSummons==0){ samuraiSummons++; Console.WriteLine("  T"+newTurns+" summon TSURU (cost5)"); RespondI32(duel,(ti<<16)|0); }
                        else RespondI32(duel,7);
                    }
                    else if(scenario=="dong" && ip==0){ RespondI32(duel,7); }
                    else if(scenario=="aramaki" && ip==0){
                        int ai=-1; for(int i2=0;i2<actCodes.Count;++i2){ if(actCodes[i2]==ARAMAKI.ToString()){ ai=i2; break; } }
                        if(newTurns>=3 && ai>=0 && !aramakiActivated){ aramakiActivated=true; Console.WriteLine("  T"+newTurns+" activate ARAMAKI ignition idx="+ai); RespondI32(duel,(ai<<16)|5); }
                        else RespondI32(duel,7);
                    }
                    else if(scenario=="zoro" && ip==0){
                        Console.WriteLine("  T"+newTurns+" IDLE act=["+string.Join(",",actCodes.ToArray())+"] natk="+natk);
                        int ei=-1; for(int i2=0;i2<actCodes.Count;++i2){ if(actCodes[i2]==EVT1492.ToString()){ ei=i2; break; } }
                        if(newTurns==3 && !attacked && natk>0){ Console.WriteLine("  T3 leader attack (rest zoro)"); RespondI32(duel,9); }
                        else if(newTurns==3 && attacked && ei>=0 && !evtActivated){ evtActivated=true; Console.WriteLine("  T3 activate OP12-039 idx="+ei); RespondI32(duel,(ei<<16)|5); }
                        else RespondI32(duel,7);
                    }
                    else if(newTurns==3 && ip==0 && natk>0 && !attacked){ RespondI32(duel,9); }
                    else RespondI32(duel,7);
                }
                else if(lastId==15||lastId==20){ Rd r=new Rd(lastMsg,1); r.U8(); r.U8(); uint smin=r.U32(); r.U32();
                    uint nsel=r.U32(); int pick=-1; int mzoneShandora=0; List<string> codes=new List<string>();
                    for(uint i=0;i<nsel;++i){ uint code=r.U32(); r.U8(); byte loc=r.U8(); r.U32(); r.U32(); codes.Add(code+"@"+loc);
                        if(code==SHANDORA && loc==4) mzoneShandora++;
                        if(code==FILLER && smin>0) pick=(int)i;
                        if(code==SHANDORA && smin==0 && loc==2){ windowSeen=true; if(kal && pick<0) pick=(int)i; }
                        if(code==LEADER0 && smin==0) pick=(int)i;
                        if(scenario=="zoro" && code==ZOROL) pick=(int)i; }
                    if(windowSeen && kal && pick>=0) Console.WriteLine("  KALGARA WINDOW SEEN -> picking shandora idx="+pick+" (complete the play)");
                    if((scenario=="zephyr"||scenario=="bounce") && smin>=2){
                        Console.WriteLine("  MULTI-SELECT n="+nsel+" min="+smin+" ["+string.Join(",",codes.ToArray())+"] -> pick first "+smin);
                        List<byte> mr=new List<byte>(); mr.AddRange(BitConverter.GetBytes((int)0)); mr.AddRange(BitConverter.GetBytes((uint)smin));
                        for(uint i2=0;i2<smin;++i2) mr.AddRange(BitConverter.GetBytes((uint)i2));
                        OCG_DuelSetResponse(duel,mr.ToArray(),(uint)mr.Count); continue; }
                    if(scenario=="bounce"){
                        bool hasField=false; for(int i2=0;i2<codes.Count;++i2){ if(codes[i2]==(FILLER+"@4")) hasField=true; }
                        if(hasField){ byte sp=lastMsg[1];
                            Console.WriteLine("  BOUNCE TARGET WINDOW player="+sp+" ["+string.Join(",",codes.ToArray())+"]");
                            if(sp==1) bounceChooserP1=true; } }
                    if(scenario=="dong" && nsel>=2 && codes.Count>0 && codes[0].StartsWith("879999997@")){
                        Console.WriteLine("  DON RETURN WINDOW n="+nsel+" min="+smin+" -> pick 2");
                        byte[] r4=new byte[16]; Array.Copy(BitConverter.GetBytes((int)0),0,r4,0,4); Array.Copy(BitConverter.GetBytes((uint)2),0,r4,4,4);
                        Array.Copy(BitConverter.GetBytes((uint)0),0,r4,8,4); Array.Copy(BitConverter.GetBytes((uint)1),0,r4,12,4);
                        OCG_DuelSetResponse(duel,r4,16); continue; }
                    if(scenario=="samurai" && smin>=2 && mzoneShandora>0){
                        samuraiCand=(int)nsel;
                        Console.WriteLine("  REST-COST WINDOW n="+nsel+" min="+smin+" ["+string.Join(",",codes.ToArray())+"]");
                        byte[] r2=new byte[16]; Array.Copy(BitConverter.GetBytes((int)0),0,r2,0,4); Array.Copy(BitConverter.GetBytes((uint)2),0,r2,4,4);
                        Array.Copy(BitConverter.GetBytes((uint)0),0,r2,8,4); Array.Copy(BitConverter.GetBytes((uint)1),0,r2,12,4);
                        OCG_DuelSetResponse(duel,r2,16); continue; }
                    if(scenario=="order" && !orderSeen){
                        int kidIdx=-1; bool reijuIn=false;
                        for(int i2=0;i2<codes.Count;++i2){ if(codes[i2].StartsWith(KID+"@")) kidIdx=i2; if(codes[i2].StartsWith(REIJU+"@")) reijuIn=true; }
                        if(kidIdx>=0 && reijuIn && smin==1){
                            orderSeen=true; orderPicked=true;
                            Console.WriteLine("  ORDER WINDOW n="+nsel+" ["+string.Join(",",codes.ToArray())+"] -> pick KID (non-leader first)");
                            byte[] r3=new byte[12]; Array.Copy(BitConverter.GetBytes((int)0),0,r3,0,4); Array.Copy(BitConverter.GetBytes((uint)1),0,r3,4,4);
                            Array.Copy(BitConverter.GetBytes((uint)kidIdx),0,r3,8,4);
                            OCG_DuelSetResponse(duel,r3,12); continue; } }
                    if(smin>0 && pick<0) pick=0;
                    if(pick<0){ OCG_DuelSetResponse(duel,new byte[8],8); continue; }
                    Console.WriteLine("  SELECT n="+nsel+" min="+smin+" ["+string.Join(",",codes.ToArray())+"] -> pick "+pick);
                    byte[] resp=new byte[12]; Array.Copy(BitConverter.GetBytes((int)0),0,resp,0,4); Array.Copy(BitConverter.GetBytes((uint)1),0,resp,4,4); Array.Copy(BitConverter.GetBytes((uint)pick),0,resp,8,4); OCG_DuelSetResponse(duel,resp,12); }
                else if(lastId==12||lastId==13){
                    // msg12 with the planpe card = the core's PRE-activation ask for a
                    // lone optional trigger (processor.cpp PointEvent case4: single
                    // candidate + empty chain -> SelectEffectYesNo desc221).
                    bool mine12=false; byte[] n12=BitConverter.GetBytes((scenario=="bounce")?TSURU:(scenario=="dong")?ZORO065:PLANPE);
                    if(lastId==12&&(scenario=="optaccept"||scenario=="optdecline"||scenario=="bounce"||scenario=="dong")){
                        for(int i2=1;i2+4<=lastMsg.Length;++i2){ if(lastMsg[i2]==n12[0]&&lastMsg[i2+1]==n12[1]&&lastMsg[i2+2]==n12[2]&&lastMsg[i2+3]==n12[3]){ mine12=true; break; } } }
                    if(mine12){
                        optAsk=true;
                        int oa=(scenario=="optdecline")?0:1;
                        Console.WriteLine("  OPT ASK (msg12 pre-activation) -> "+(oa==1?"ACTIVATE":"DECLINE"));
                        RespondI32(duel,oa); }
                    else {
                        Rd r=new Rd(lastMsg,1); r.U8(); ulong desc=r.U64();
                        int ans=(desc==(((ulong)879999999<<20)+0))?1:0;
                        if(ans==1) Console.WriteLine("  BLOCK PROMPT -> YES");
                        RespondI32(duel,ans); } }
                else if(lastId==14){ RespondI32(duel,0); }
                else if(lastId==16){
                    // MSG_SELECT_CHAIN: routine empty chain windows ask here too
                    // (blanket -1 kept). The e2/TRIGGER_O activation ask carries
                    // the candidate card's code in its payload -- only then does
                    // the scenario policy answer.
                    bool mine=false; byte[] needle=BitConverter.GetBytes(PLANPE);
                    for(int i2=1;i2+4<=lastMsg.Length;++i2){ if(lastMsg[i2]==needle[0]&&lastMsg[i2+1]==needle[1]&&lastMsg[i2+2]==needle[2]&&lastMsg[i2+3]==needle[3]){ mine=true; break; } }
                    if(mine && scenario=="optaccept"){ optAsk=true; Console.WriteLine("  OPT ASK (msg16, planpe listed) -> ACTIVATE"); RespondI32(duel,0); }
                    else if(mine && scenario=="optdecline"){ optAsk=true; Console.WriteLine("  OPT ASK (msg16, planpe listed) -> DECLINE"); RespondI32(duel,-1); }
                    else RespondI32(duel,-1); }
                else if(lastId==26){ RespondI32(duel,-1); }
                else if(lastId==25){ RespondI32(duel,-1); }
                else if(lastId==19){ RespondI32(duel,0x1); }
                else if(lastId==143){ RespondI32(duel,0); }
                else if(lastId==18||lastId==24){ Rd r=new Rd(lastMsg,1); byte player=r.U8(); byte need=r.U8(); uint flag=r.U32(); uint aw=~flag; List<byte> resp=new List<byte>(); int given=0; for(int bit=0;bit<32&&given<Math.Max((int)need,1);++bit){ if((aw&(1u<<bit))==0) continue; byte con=(byte)((bit>=16)?(1-player):player); int local=bit&0xf; byte loc=(byte)((local>=8)?8:4); byte seq=(byte)((local>=8)?(local-8):local); resp.Add(con);resp.Add(loc);resp.Add(seq); given++; } if(given==0) break; OCG_DuelSetResponse(duel,resp.ToArray(),(uint)resp.Count); }
                else break;
                if(newTurns >= ((scenario=="law"||scenario=="zephyr"||scenario=="reiju"||scenario=="optaccept"||scenario=="optdecline"||scenario=="bounce") ? 6 : 4)) break;
                } catch(Exception ex) {
                    Console.WriteLine("PARSE CRASH step="+step+" lastId="+lastId+" msglen="+(lastMsg==null?-1:lastMsg.Length)+" : "+ex.Message);
                    if(lastMsg!=null) Console.WriteLine("  HEX "+BitConverter.ToString(lastMsg));
                    break;
                }
            }
        } finally { OCG_DestroyDuel(duel); }
        foreach(string e in callbackErrors) Console.WriteLine("CB/"+e);
        bool pass = (scenario=="leaderblock") ? (attacked && dlHit)
            : (scenario=="kalgara") ? (attacked && windowSeen && kalgaraPlayed && kalgaraLife)
            : (scenario=="samurai") ? (samuraiCand>=2)
            : (scenario=="law") ? lawListed
            : (scenario=="order") ? (orderSeen && orderDraw>=1)
            : (scenario=="kuzan") ? (kuzanArmed && kuzanDraw==2)
            : (scenario=="life99") ? (attacked && windowSeen && kalgaraPlayed && kalgaraLife && lifeDraw==1)
            : (scenario=="zephyr") ? (zephyrPlayed && zpDraw==2)
            : (scenario=="reiju") ? (evtActivated && reijuDraw==1)
            : (scenario=="optaccept") ? (planpePlayed && optAsk && optChained>=1 && optLife && optDraw==1)
            : (scenario=="optdecline") ? (planpePlayed && optAsk && optChained==0 && !optLife && optDraw==0 && newTurns>=6)
            : (scenario=="zoro") ? (attacked && evtActivated && zoroActive)
            : (scenario=="zerocost") ? (cost0Ok && cost0NegOk && cost0RawOk)
            : (scenario=="bounce") ? (tsuruPlayed && optAsk && bounceChooserP1 && bounced)
            : (scenario=="aramaki") ? (aramakiActivated && aramakiReturned)
            : (scenario=="dong") ? dongOk
            : (attacked && t3Draw>=1);
        Console.WriteLine("scenario="+scenario+" attacked="+attacked+" t3_p1_draw="+t3Draw+" leader_damage="+dlHit+" kalgara_window="+windowSeen+" kalgara_played="+kalgaraPlayed+" kalgara_life="+kalgaraLife+" rest_candidates="+samuraiCand+" law_listed="+lawListed+" order_window="+orderSeen+" order_draw="+orderDraw+" kuzan_draw="+kuzanDraw+" life99_draw="+lifeDraw+" zephyr_played="+zephyrPlayed+" zephyr_draw="+zpDraw+" evt_activated="+evtActivated+" reiju_draw="+reijuDraw+" planpe_played="+planpePlayed+" opt_ask="+optAsk+" opt_chained="+optChained+" opt_life="+optLife+" opt_draw="+optDraw+" zoro_active="+zoroActive+" cost0_ok="+cost0Ok+" cost0_neg_ok="+cost0NegOk+" tsuru_played="+tsuruPlayed+" bounce_chooser_p1="+bounceChooserP1+" bounced="+bounced+" aramaki_act="+aramakiActivated+" aramaki_ret="+aramakiReturned+" dong_ok="+dongOk+" turns="+newTurns+" qhint_push="+queueHintPush+" qhint_clear="+queueHintClear);
        Console.WriteLine(pass ? ("ACE_E2_"+scenario.ToUpper()+": PASS") : ("ACE_E2_"+scenario.ToUpper()+": FAIL"));
        return pass ? 0 : 1;
    }
}
'@
Add-Type -TypeDefinition $source -Language CSharp
[AceDraw]::LoadDb("$PSScriptRoot\cdb_dump.csv")
$repoPath = (Resolve-Path -LiteralPath $Repo).Path
if ($Scenario -ne "") { exit [AceDraw]::Run($repoPath, $Scenario) }
$r1 = [AceDraw]::Run($repoPath, "damage")
$r2 = [AceDraw]::Run($repoPath, "ko")
$r3 = [AceDraw]::Run($repoPath, "leaderblock")
$r4 = [AceDraw]::Run($repoPath, "kalgara")
$r5 = [AceDraw]::Run($repoPath, "optaccept")
$r6 = [AceDraw]::Run($repoPath, "optdecline")
$r7 = [AceDraw]::Run($repoPath, "zoro")
$r8 = [AceDraw]::Run($repoPath, "zerocost")
$r9 = [AceDraw]::Run($repoPath, "bounce")
$r10 = [AceDraw]::Run($repoPath, "aramaki")
$r11 = [AceDraw]::Run($repoPath, "dong")
$all = @($r1,$r2,$r3,$r4,$r5,$r6,$r7,$r8,$r9,$r10,$r11)
exit ($all | Measure-Object -Maximum).Maximum
