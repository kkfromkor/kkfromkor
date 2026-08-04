param([Parameter(Mandatory = $true)][string]$Repo)

# Headless behavioural proof of the two OP14 runtime primitives against the
# real ocgcore:
#   1. SWAP_BASE_POWER swap math (the exact EFFECT_SET_BASE_ATTACK cross-apply
#      the handler runs) - two characters exchange their base powers.
#   2. ON_SELF_RESTED emit - opcg.SetRested fires the new timing on ANY rest
#      (plain/attack), and still fires the effect-gated timings on an
#      effect-caused rest.
# Run with 32-bit PowerShell (release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgOp14NewOps {
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

    const uint CHAR_A = 999000201;   // base power 1000
    const uint CHAR_B = 999000202;   // base power 9000
    const uint CHAR_TYPE = 33;       // OPCG character frame (TYPE_MONSTER set)

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
            if(code == CHAR_A) { data.type = CHAR_TYPE; data.attack = 1000; }
            else if(code == CHAR_B) { data.type = CHAR_TYPE; data.attack = 9000; }
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
        // messages are irrelevant here; draining keeps the process loop moving
    }

    const string testScript = @"
local ge = Effect.GlobalEffect()
ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
ge:SetCode(EVENT_STARTUP)
ge:SetOperation(function()
    local function ensure(ok, label) assert(ok, 'OP14OPS ' .. label) end
    local deck = Duel.GetFieldGroup(0, LOCATION_DECK, 0)
    local a = deck:Filter(function(c) return c:GetCode() == 999000201 end, nil):GetFirst()
    local b = deck:Filter(function(c) return c:GetCode() == 999000202 end, nil):GetFirst()
    ensure(a and b, 'both characters in deck')
    ensure(Duel.MoveToField(a, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true, 1), 'place A')
    ensure(Duel.MoveToField(b, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true, 2), 'place B')
    ensure(opcg.GetBasePower(a) == 1000, 'A base is 1000 before')
    ensure(opcg.GetBasePower(b) == 9000, 'B base is 9000 before')

    -- (1) SWAP_BASE_POWER: exact cross-apply the handler runs (read both first,
    -- then EFFECT_SET_BASE_ATTACK each to the other value).
    local pa, pb = opcg.GetBasePower(a), opcg.GetBasePower(b)
    local function setbase(tgt, val)
        local e = Effect.CreateEffect(a)
        e:SetType(EFFECT_TYPE_SINGLE)
        e:SetCode(EFFECT_SET_BASE_ATTACK)
        e:SetValue(val)
        e:SetReset(RESET_PHASE + PHASE_END)
        tgt:RegisterEffect(e)
    end
    setbase(a, pb)
    setbase(b, pa)
    ensure(opcg.GetBasePower(a) == 9000, 'A swapped to 9000')
    ensure(opcg.GetBasePower(b) == 1000, 'B swapped to 1000')

    -- (2) ON_SELF_RESTED emit: spy the emit, then rest with/without an effect.
    local seen = {}
    local real_emit = opcg.contract_ops.emit
    opcg.contract_ops.emit = function(timing, ctx, player, cards)
        seen[#seen + 1] = { timing = timing, card = cards and cards[1] }
        return real_emit(timing, ctx, player, cards)
    end
    local function fired(timing, card)
        for _, e in ipairs(seen) do
            if e.timing == timing and (card == nil or e.card == card) then return true end
        end
        return false
    end
    -- plain rest (as an attack declaration would - no effect context)
    local rested = opcg.SetRested(a)
    ensure(rested and rested ~= 0, 'plain rest A operated')
    ensure(fired('ON_SELF_RESTED', a), 'ON_SELF_RESTED fired on plain rest of A')
    ensure(not fired('ON_OWN_CHARACTER_RESTED_BY_EFFECT'), 'plain rest must NOT fire the by-effect timing')
    -- effect-caused rest by the OPPONENT (player 1) on B (owned by 0)
    seen = {}
    local rested_b = opcg.SetRested(b, { effect = true, player = 1 })
    ensure(rested_b and rested_b ~= 0, 'effect rest B operated')
    ensure(fired('ON_SELF_RESTED', b), 'ON_SELF_RESTED fired on effect rest of B')
    ensure(fired('ON_OWN_CHARACTER_RESTED_BY_EFFECT', b), 'by-effect timing fired on effect rest')
    ensure(fired('ON_SELF_RESTED_BY_OPPONENT_EFFECT', b), 'by-opponent timing fired (rester is player 1)')

    -- (3) ON_OWN_CHARACTER_PLAYED: force emit_played down the direct path
    -- (queue path enqueues out of the spy's sight) and expect the generic
    -- own-side timing plus the opponent-side one.
    seen = {}
    local q = opcg.effect_queue
    local saved_enqueue = q and q.enqueue_timing
    if q then q.enqueue_timing = nil end
    opcg.contract_ops.emit_played(b, 0, {})
    if q then q.enqueue_timing = saved_enqueue end
    ensure(fired('ON_OWN_CHARACTER_PLAYED'), 'ON_OWN_CHARACTER_PLAYED fired for the owner')
    ensure(fired('ON_OPPONENT_CHARACTER_PLAYED'), 'opponent-side played timing still fired')
    opcg.contract_ops.emit = real_emit

    -- (4) CHARACTER_OR_STAGE selector kind sees both zones
    local pred = opcg.KindPredicate('CHARACTER_OR_STAGE')
    ensure(pred ~= nil, 'CHARACTER_OR_STAGE kind exists')
    ensure(pred(a) == true, 'kind accepts a character')
    local grp = opcg.GetCandidateGroup({ kind = 'CHARACTER_OR_STAGE', owner = 'YOU' }, { player = 0 })
    ensure(grp ~= nil and grp:GetCount() >= 2, 'candidate group sees the two placed characters')
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
            if(OCG_LoadScript(duel, script, (uint)script.Length, "opcg_op14_newops_test.lua") != 1)
                callbackErrors.Add("test script failed to load");
            var deckCodes = new uint[] { CHAR_A, CHAR_B, 999000001, 999000002, 999000003, 999000004 };
            for(uint sequence = 0; sequence < deckCodes.Length; ++sequence) {
                var card = new NewCard { team = 0, duelist = 0, code = deckCodes[sequence], con = 0, loc = 1, seq = sequence, pos = 8 };
                OCG_DuelNewCard(duel, ref card);
            }
            var opp = new NewCard { team = 1, duelist = 1, code = 999000009, con = 1, loc = 1, seq = 0, pos = 8 };
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
        Console.WriteLine(passed ? "OP14_NEWOPS PASS" : "OP14_NEWOPS FAIL");
        return passed ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgOp14NewOps]::Run((Resolve-Path -LiteralPath $Repo).Path)
