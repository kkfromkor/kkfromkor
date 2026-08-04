param([Parameter(Mandatory = $true)][string]$Repo)

# Headless behavioural proof of "cannot leave the field by opponent effects"
# guards (user report: OP13-089 Warcury family left the field by card effects
# even with 7+ cards in trash - the opponent-judgment never received its
# actor input, so the guard had never fired in real play).
# Real card: OP13-089 (880001661), trash seeded with 7 cards ->
#   - opponent-effect removal: BLOCKED
#   - own-effect removal: allowed (text says by OPPONENT effects)
#   - battle reason: allowed (guard is effect-only)
#   - trash drops to 6: opponent-effect removal allowed again (live condition)
# Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgLeaveFieldGuard {
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

    const uint WARCURY = 880001661; // OP13-089
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
            if(code == WARCURY) { data.type = CHAR_TYPE; data.attack = 7000; data.level = 6; }
            else if(code >= 999000200 && code < 999000300) { data.type = CHAR_TYPE; data.attack = 1000; }
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
    local function ensure(ok, label) assert(ok, 'LEAVEGUARD ' .. label) end
    local deck = Duel.GetFieldGroup(0, LOCATION_DECK, 0)
    local warcury = deck:Filter(function(c) return c:GetCode() == 880001661 end, nil):GetFirst()
    ensure(warcury, 'warcury in deck')
    -- seed the trash to 7 by moving fillers from deck
    local fillers = deck:Filter(function(c) return c:GetCode() ~= 880001661 end, nil)
    local moved = 0
    for c in aux.Next(fillers) do
        if moved >= 7 then break end
        Duel.SendtoGrave(c, REASON_RULE)
        moved = moved + 1
    end
    ensure(Duel.GetFieldGroupCount(0, LOCATION_GRAVE, 0) >= 7, 'trash seeded to 7')
    ensure(Duel.MoveToField(warcury, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true, 1), 'place warcury')

    local guard = opcg.contract_ops.before_remove

    -- (1) opponent effect removal: BLOCKED (this exact path never fired before)
    local kept = guard({ warcury }, REASON_EFFECT, 'TRASH', { player = 1 })
    ensure(#kept == 0, 'opponent effect removal blocked at 7+ trash')

    -- (2) own effect removal: allowed (guard reads BY OPPONENT effects)
    kept = guard({ warcury }, REASON_EFFECT, 'TRASH', { player = 0 })
    ensure(#kept == 1, 'own effect removal still allowed')

    -- (3) battle destruction: allowed (guard is effect-only)
    kept = guard({ warcury }, REASON_BATTLE + REASON_DESTROY, 'TRASH', { player = 1 })
    ensure(#kept == 1, 'battle removal not caught by the guard')

    -- (4) live condition: drop trash to 6 -> guard must switch off
    local one = Duel.GetFieldGroup(0, LOCATION_GRAVE, 0):GetFirst()
    Duel.SendtoDeck(one, 0, SEQ_DECKBOTTOM, REASON_RULE)
    ensure(Duel.GetFieldGroupCount(0, LOCATION_GRAVE, 0) == 6, 'trash now 6')
    kept = guard({ warcury }, REASON_EFFECT, 'TRASH', { player = 1 })
    ensure(#kept == 1, 'guard off below 7 trash')
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
            if(OCG_LoadScript(duel, script, (uint)script.Length, "opcg_leavefield_guard_test.lua") != 1)
                callbackErrors.Add("test script failed to load");
            var deckCodes = new uint[] { WARCURY, 999000211, 999000212, 999000213, 999000214, 999000215, 999000216, 999000217, 999000218 };
            for(uint sequence = 0; sequence < deckCodes.Length; ++sequence) {
                var card = new NewCard { team = 0, duelist = 0, code = deckCodes[sequence], con = 0, loc = 1, seq = sequence, pos = 8 };
                OCG_DuelNewCard(duel, ref card);
            }
            var opp = new NewCard { team = 1, duelist = 0, code = 999000209, con = 1, loc = 1, seq = 0, pos = 8 };
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
        Console.WriteLine(passed ? "LEAVEFIELD_GUARD PASS" : "LEAVEFIELD_GUARD FAIL");
        return passed ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgLeaveFieldGuard]::Run((Resolve-Path -LiteralPath $Repo).Path)
