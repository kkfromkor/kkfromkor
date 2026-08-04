param([Parameter(Mandatory = $true)][string]$Repo)

# Headless behavioural proof that negating a card turns its PRINTED keywords
# off (user report: a negated character still declared Blocker). Real card:
# OP14-093 Mr.4 (printed BLOCKER).
#   - before: HasKeyword BLOCKER = true
#   - real NEGATE_EFFECTS lands (EFFECT_DISABLE single) -> IsDisabled = true
#   - after: HasKeyword BLOCKER = false, runtime can_resolve = EFFECT_NEGATED
# Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgNegateKeyword {
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
    [StructLayout(LayoutKind.Sequential)] public struct CardData { public uint code, alias; public IntPtr setcodes; public uint type, level, attribute; public ulong race; public int attack, defense; public uint lscale, rscale, link_marker, category; }

    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_CreateDuel(out IntPtr duel, ref Options options);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DestroyDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_DuelNewCard(IntPtr duel, ref NewCard info);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern void OCG_StartDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_DuelProcess(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr OCG_DuelGetMessage(IntPtr duel, out uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)] static extern int OCG_LoadScript(IntPtr duel, byte[] buffer, uint length, [MarshalAs(UnmanagedType.LPStr)] string name);

    const uint MR4 = 880002258; // OP14-093, printed BLOCKER
    const uint CHAR_TYPE = 33;

    static string standardScripts, expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            var data = new CardData { code = code, alias = 0, setcodes = IntPtr.Zero,
                type = 1, level = 0, attribute = 0, race = 2UL, attack = 0, defense = 0, category = 0 };
            if(code == MR4) { data.type = CHAR_TYPE; data.attack = 5000; data.level = 4; }
            Marshal.StructureToPtr(data, output, false);
        } catch(Exception e) { callbackErrors.Add("card reader: " + e); }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        var text = Marshal.PtrToStringAnsi(message) ?? "";
        if(type == 0) errors.Add(text);
    }
    static int Load(IntPtr duel, string name) {
        if(name.StartsWith("c999")) {
            var stub = Encoding.UTF8.GetBytes("local s,id=GetID()\nfunction s.initial_effect(c)\nend\n");
            return OCG_LoadScript(duel, stub, (uint)stub.Length, name);
        }
        foreach(var directory in new [] { expansionScripts, standardScripts, Path.Combine(standardScripts, "unofficial") }) {
            var path = Path.Combine(directory, name);
            if(File.Exists(path)) { var bytes = File.ReadAllBytes(path); return OCG_LoadScript(duel, bytes, (uint)bytes.Length, name); }
        }
        if(name != "c0.lua") callbackErrors.Add("missing script: " + name);
        return 0;
    }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name) {
        try { return Load(duel, Marshal.PtrToStringAnsi(name)); }
        catch(Exception e) { callbackErrors.Add("script reader: " + e); return 0; }
    }
    static void Drain(IntPtr duel) {
        uint length; OCG_DuelGetMessage(duel, out length);
    }

    const string testScript = @"
local ge = Effect.GlobalEffect()
ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
ge:SetCode(EVENT_STARTUP)
ge:SetOperation(function()
    local function ensure(ok, label) assert(ok, 'NEGKW ' .. label) end
    local mr4 = Duel.GetFieldGroup(0, LOCATION_DECK, 0):Filter(function(c) return c:GetCode() == 880002258 end, nil):GetFirst()
    ensure(mr4, 'mr4 in deck')
    ensure(Duel.MoveToField(mr4, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true, 1), 'place mr4')

    ensure(opcg.HasKeyword(mr4, 'BLOCKER'), 'printed blocker on before negation')

    -- real negation through the product executor (SELF selector = no prompt),
    -- acting player = the opponent
    local acted = opcg.contract_ops.execute('NEGATE_EFFECTS',
        { op = 'NEGATE_EFFECTS', duration = 'THIS_TURN',
          selector = { owner = 'YOU', kind = 'SELF', count = 1, mode = 'EXACT' } },
        { card = mr4, player = 1 })
    ensure(acted ~= nil, 'negation executed')
    Duel.AdjustInstantly(mr4)
    ensure(mr4:IsDisabled(), 'card reads as negated')

    ensure(not opcg.HasKeyword(mr4, 'BLOCKER'), 'printed blocker OFF while negated')
    local ok, why = opcg.runtime.can_resolve(mr4, 'E1', { player = 0 })
    ensure(ok == false and why == 'EFFECT_NEGATED', 'runtime effect gate agrees: ' .. tostring(why))
end)
Duel.RegisterEffect(ge, 0)
";

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        errors.Clear(); callbackErrors.Clear();

        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4, flags = 0x2000000000UL,
            team1 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            cardReader = cardReader, scriptReader = scriptReader, logHandler = logHandler,
            cardReaderDone = cardReaderDone, enableUnsafeLibraries = 1
        };
        IntPtr duel;
        if(OCG_CreateDuel(out duel, ref options) != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed"); return 2;
        }
        try {
            foreach(var name in new [] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if(Load(duel, name) != 1) callbackErrors.Add("initial script failed: " + name);
            var script = Encoding.UTF8.GetBytes(testScript);
            if(OCG_LoadScript(duel, script, (uint)script.Length, "opcg_negate_keyword_test.lua") != 1)
                callbackErrors.Add("test script failed to load");
            var deckCodes = new uint[] { MR4, 999000001, 999000002, 999000003, 999000004, 999000005 };
            for(uint sequence = 0; sequence < deckCodes.Length; ++sequence) {
                var card = new NewCard { team = 0, duelist = 0, code = deckCodes[sequence], con = 0, loc = 1, seq = sequence, pos = 8 };
                OCG_DuelNewCard(duel, ref card);
            }
            var opp = new NewCard { team = 1, duelist = 0, code = 999000009, con = 1, loc = 1, seq = 0, pos = 8 };
            OCG_DuelNewCard(duel, ref opp);
            OCG_StartDuel(duel);
            int processStatus = 2;
            for(int step = 0; step < 500 && processStatus == 2; ++step) {
                processStatus = OCG_DuelProcess(duel);
                Drain(duel);
            }
        } finally { OCG_DestroyDuel(duel); }

        Console.WriteLine("script_errors=" + errors.Count + " callback_failures=" + callbackErrors.Count);
        foreach(var e in callbackErrors) Console.WriteLine("CALLBACK: " + e);
        foreach(var e in errors) Console.WriteLine("SCRIPT: " + e);
        var passed = errors.Count == 0 && callbackErrors.Count == 0;
        Console.WriteLine(passed ? "NEGATE_KEYWORD PASS" : "NEGATE_KEYWORD FAIL");
        return passed ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgNegateKeyword]::Run((Resolve-Path -LiteralPath $Repo).Path)
