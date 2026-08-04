param([Parameter(Mandatory = $true)][string]$Repo)

# EB04-038 로시난테 & 로 「룰상 카드명 2종 추가 취급」 실측(유저 제보 "작동 안 함").
#  t1: 덱의 1장을 필드로 직접 배치. t1~t3 MAIN1마다 필드/패/덱의 EB04-038에 대해
#  opcg.HasName(c,'트라팔가 로'/'돈키호테 로시난테') + EFFECT_NAME_ALIAS 부여 수를 덤프.
#  기대: 세 존 전부 true/true/2. (룰상 효과 = 존 불문)
# 32-bit PowerShell로 구동.

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class AliasProbe {
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

    const uint ROSI = 880002459; // EB04-038
    const uint LEADER = 880000634;
    const uint FILLER = 880000881;

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
        int newTurns = 0;
        try {
            foreach (var name in new[] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if (Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            string probe =
              "local pr=Effect.GlobalEffect() pr:SetType(EFFECT_TYPE_FIELD+EFFECT_TYPE_CONTINUOUS) pr:SetCode(EVENT_PHASE_START+PHASE_MAIN1)\n" +
              "pr:SetOperation(function()\n" +
              "  local t=Duel.GetTurnCount() if t>3 then return end\n" +
              "  Debug.Message('DECKN t='..t..' n='..Duel.GetFieldGroupCount(0,LOCATION_DECK,0))\n" +
              "  local dg=Duel.GetFieldGroup(0,LOCATION_DECK,0) local seen={}\n" +
              "  for c in aux.Next(dg) do local k=c:GetOriginalCode() seen[k]=(seen[k] or 0)+1 end\n" +
              "  local ss='' for k,v in pairs(seen) do ss=ss..k..'x'..v..' ' end\n" +
              "  Debug.Message('DECKC t='..t..' '..ss)\n" +
              "  if t==1 and not opcg._placed then opcg._placed=true\n" +
              "    local c=Duel.GetMatchingGroup(function(x) return x:GetOriginalCode()==880002459 end,0,LOCATION_DECK,0,nil):GetFirst()\n" +
              "    if c then Duel.MoveToField(c,0,0,LOCATION_MZONE,POS_FACEUP_ATTACK,true) end\n" +
              "  end\n" +
              "  for _,zone in ipairs({{LOCATION_MZONE,'FIELD'},{LOCATION_HAND,'HAND'},{LOCATION_DECK,'DECK'}}) do\n" +
              "    local g=Duel.GetFieldGroup(0,zone[1],0)\n" +
              "    for c in aux.Next(g) do\n" +
              "     if c:GetOriginalCode()==880002459 then\n" +
              "      local n1=opcg.HasName(c,'트라팔가 로') local n2=opcg.HasName(c,'돈키호테 로시난테')\n" +
              "      local cnt=0 if c.GetCardEffect and opcg.EFFECT_NAME_ALIAS then local r={c:GetCardEffect(opcg.EFFECT_NAME_ALIAS)} cnt=#r end\n" +
              "      Debug.Message('ALIAS t='..t..' '..zone[2]..' law='..tostring(n1)..' rosi='..tostring(n2)..' fx='..cnt)\n" +
              "     end\n" +
              "    end\n" +
              "  end\n" +
              "end) Duel.RegisterEffect(pr,0)\n";
            byte[] pb = Encoding.UTF8.GetBytes(probe);
            if (OCG_LoadScript(duel, pb, (uint)pb.Length, "alias_probe.lua") != 1) callbackErrors.Add("probe fail");

            Action<int,uint,int> add = delegate(int p, uint code, int copies){ for(int k=0;k<copies;++k){ NewCard c=new NewCard(); c.team=(byte)p;c.duelist=0;c.code=code;c.con=(byte)p;c.loc=1;c.seq=0;c.pos=8; OCG_DuelNewCard(duel, ref c);} };
            add(0, LEADER, 1); add(0, FILLER, 30); add(0, ROSI, 20);
            add(1, LEADER, 1); add(1, FILLER, 45);
            OCG_StartDuel(duel);

            uint lastId=0; byte[] lastMsg=null;
            for (int step=0; step<20000; ++step) {
                int st=OCG_DuelProcess(duel);
                uint length; IntPtr ptr=OCG_DuelGetMessage(duel, out length);
                byte[] all=new byte[length]; if(length>0) Marshal.Copy(ptr, all, 0, (int)length);
                int off=0;
                while(off+4<=all.Length){ uint pl2=BitConverter.ToUInt32(all,off); off+=4; if(pl2==0||off+pl2>all.Length) break; byte id=all[off]; byte[] payload=new byte[pl2]; Array.Copy(all,off,payload,0,(int)pl2); off+=(int)pl2; lastId=id; lastMsg=payload; if(id==40) newTurns++; }
                if(st==0) break; if(st!=1) continue; if(lastMsg==null) break;
                if(newTurns>=4) break;
                if(lastId==11) OCG_DuelSetResponse(duel, BitConverter.GetBytes(7), 4);
                else if(lastId==13||lastId==12||lastId==14) OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
                else if(lastId==16) OCG_DuelSetResponse(duel, BitConverter.GetBytes(-1), 4);
                else if(lastId==15){ var mn=BitConverter.ToUInt32(lastMsg,3); if(mn==0){ OCG_DuelSetResponse(duel,new byte[8],8); } else { byte[] r1=new byte[12]; Array.Copy(BitConverter.GetBytes((int)0),0,r1,0,4); Array.Copy(BitConverter.GetBytes((uint)1),0,r1,4,4); OCG_DuelSetResponse(duel,r1,12); } }
                else if(lastId==18||lastId==24){
                    byte pl2b = lastMsg.Length > 1 ? lastMsg[1] : (byte)0;
                    uint flag = lastMsg.Length >= 7 ? BitConverter.ToUInt32(lastMsg, 3) : 0u;
                    byte loc = 4, seq = 0;
                    for (byte i = 0; i < 7; ++i) if ((flag & (1u << i)) == 0) { loc = 4; seq = i; break; }
                    if ((flag & 0x7f) == 0x7f)
                        for (byte i = 0; i < 8; ++i) if ((flag & (1u << (8 + i))) == 0) { loc = 8; seq = i; break; }
                    OCG_DuelSetResponse(duel, new byte[] { pl2b, loc, seq }, 3);
                }
                else OCG_DuelSetResponse(duel, BitConverter.GetBytes(0), 4);
            }
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("turns=" + newTurns + " errors=" + errors.Count + " callback=" + callbackErrors.Count);
        foreach(var e in errors) Console.WriteLine("ERR " + e);
        foreach(var e in callbackErrors) Console.WriteLine("CB " + e);
        foreach(var p2 in probes) Console.WriteLine("PROBE " + p2);
        bool fieldOk=false, handOk=false, deckOk=false, anyFalse=false;
        foreach(var p2 in probes){
            if(!p2.StartsWith("ALIAS")) continue;
            bool ok = p2.Contains("law=true") && p2.Contains("rosi=true");
            if(p2.Contains("FIELD") && ok) fieldOk=true;
            if(p2.Contains("HAND") && ok) handOk=true;
            if(p2.Contains("DECK") && ok) deckOk=true;
            if(p2.Contains("law=false")||p2.Contains("rosi=false")) anyFalse=true;
        }
        Console.WriteLine("fieldOk="+fieldOk+" handOk="+handOk+" deckOk="+deckOk+" anyFalse="+anyFalse);
        bool pass = fieldOk && handOk && deckOk && !anyFalse && errors.Count==0;
        Console.WriteLine(pass ? "EB04038_ALIAS PASS" : "EB04038_ALIAS FAIL");
        return pass ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [AliasProbe]::Run((Resolve-Path -LiteralPath $Repo).Path)
