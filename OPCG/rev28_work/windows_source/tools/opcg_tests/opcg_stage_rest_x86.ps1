param([Parameter(Mandatory = $true)][string]$Repo)

# Headless proof that the OPCG stage zone (szone seq 5) carries the full
# rest/active position model: active placement, in-place rest, no-op refusal,
# ready, rested placement (with field replacement to the trash), and the
# opcg.* helpers, with every transition emitted as MSG_POS_CHANGE on the wire.
# Run with 32-bit PowerShell (the release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgStageRestHeadless {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void DataReader(IntPtr payload, uint code, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void DataReaderDone(IntPtr payload, IntPtr data);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int ScriptReader(IntPtr payload, IntPtr duel, IntPtr name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void LogHandler(IntPtr payload, IntPtr message, int type);

    [StructLayout(LayoutKind.Sequential)]
    public struct Player {
        public uint startingLP, startingDrawCount, drawCountPerTurn;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct Options {
        public ulong seed0, seed1, seed2, seed3, flags;
        public Player team1, team2;
        public DataReader cardReader;
        public IntPtr payload1;
        public ScriptReader scriptReader;
        public IntPtr payload2;
        public LogHandler logHandler;
        public IntPtr payload3;
        public DataReaderDone cardReaderDone;
        public IntPtr payload4;
        public byte enableUnsafeLibraries;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct NewCard {
        public byte team, duelist;
        public uint code;
        public byte con;
        public uint loc, seq, pos;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct CardData {
        public uint code, alias;
        public IntPtr setcodes;
        public uint type, level, attribute;
        public ulong race;
        public int attack, defense;
        public uint lscale, rscale, link_marker, category;
    }

    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int OCG_CreateDuel(out IntPtr duel, ref Options options);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_DestroyDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_DuelNewCard(IntPtr duel, ref NewCard info);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_StartDuel(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int OCG_DuelProcess(IntPtr duel);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr OCG_DuelGetMessage(IntPtr duel, out uint length);
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int OCG_LoadScript(
        IntPtr duel, byte[] buffer, uint length,
        [MarshalAs(UnmanagedType.LPStr)] string name);

    const byte MSG_MOVE = 50;
    const byte MSG_POS_CHANGE = 53;
    const byte LOCATION_SZONE = 0x8;
    const byte POS_FACEUP_ATTACK = 0x1;
    const byte POS_FACEUP_DEFENSE = 0x4;
    const uint STAGE_A = 999000101;
    const uint STAGE_B = 999000102;
    const uint TYPE_FIELD_SPELL = 0x80002;

    static string standardScripts;
    static string expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<byte[]> posChanges = new List<byte[]>();
    static readonly List<byte[]> stageMoves = new List<byte[]>();

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            var data = new CardData {
                code = code, alias = 0, setcodes = IntPtr.Zero,
                type = (code == STAGE_A || code == STAGE_B) ? TYPE_FIELD_SPELL : 1,
                level = 0, attribute = 0,
                race = (code == STAGE_A || code == STAGE_B) ? 0UL : 2UL,
                attack = 0, defense = 0, category = 0
            };
            Marshal.StructureToPtr(data, output, false);
        } catch(Exception exception) {
            callbackErrors.Add("card reader: " + exception);
        }
    }
    static void DoneCard(IntPtr payload, IntPtr data) {}
    static void Log(IntPtr payload, IntPtr message, int type) {
        var text = Marshal.PtrToStringAnsi(message) ?? "";
        if(type == 0)
            errors.Add(text);
    }
    static int Load(IntPtr duel, string name) {
        // the test decks use dummy codes: serve a no-op card script
        if(name.StartsWith("c999")) {
            var stub = Encoding.UTF8.GetBytes("local s,id=GetID()\nfunction s.initial_effect(c)\nend\n");
            return OCG_LoadScript(duel, stub, (uint)stub.Length, name);
        }
        foreach(var directory in new [] {
            expansionScripts,
            standardScripts,
            Path.Combine(standardScripts, "unofficial")
        }) {
            var path = Path.Combine(directory, name);
            if(File.Exists(path)) {
                var bytes = File.ReadAllBytes(path);
                return OCG_LoadScript(duel, bytes, (uint)bytes.Length, name);
            }
        }
        if(name != "c0.lua")
            callbackErrors.Add("missing script: " + name);
        return 0;
    }
    static int ReadScript(IntPtr payload, IntPtr duel, IntPtr name) {
        try {
            return Load(duel, Marshal.PtrToStringAnsi(name));
        } catch(Exception exception) {
            callbackErrors.Add("script reader: " + exception);
            return 0;
        }
    }

    static void DrainMessages(IntPtr duel) {
        uint length;
        var buffer = OCG_DuelGetMessage(duel, out length);
        if(buffer == IntPtr.Zero || length == 0)
            return;
        var bytes = new byte[length];
        Marshal.Copy(buffer, bytes, 0, (int)length);
        var offset = 0;
        while(offset + 4 <= bytes.Length) {
            var packetLength = BitConverter.ToUInt32(bytes, offset);
            offset += 4;
            if(packetLength == 0 || offset + packetLength > bytes.Length)
                break;
            if(bytes[offset] == MSG_POS_CHANGE && bytes[offset + 6] == LOCATION_SZONE) {
                var packet = new byte[packetLength];
                Array.Copy(bytes, offset, packet, 0, (int)packetLength);
                posChanges.Add(packet);
            } else if(bytes[offset] == MSG_MOVE && packetLength >= 29) {
                // payload: type u8, code u32, prev loc_info(10), curr loc_info(10), reason u32
                var code = BitConverter.ToUInt32(bytes, offset + 1);
                var currentLocation = bytes[offset + 16];
                if((code == STAGE_A || code == STAGE_B) && currentLocation == LOCATION_SZONE) {
                    var packet = new byte[packetLength];
                    Array.Copy(bytes, offset, packet, 0, (int)packetLength);
                    stageMoves.Add(packet);
                }
            }
            offset += (int)packetLength;
        }
    }

    // MSG_POS_CHANGE payload: type u8, code u32, controller u8, location u8,
    // sequence u8, previous u8, current u8.
    static bool PosChangeMatches(byte[] packet, byte sequence, byte previous, byte current) {
        return packet.Length >= 10 && packet[7] == sequence
            && packet[8] == previous && packet[9] == current;
    }
    // MSG_MOVE current loc_info: controller at +15, location +16, sequence
    // i32 at +17, position i32 at +21.
    static bool MoveMatches(byte[] packet, uint code, int sequence, int position) {
        return BitConverter.ToUInt32(packet, 1) == code
            && BitConverter.ToInt32(packet, 17) == sequence
            && BitConverter.ToInt32(packet, 21) == position;
    }

    const string testScript = @"
local ge = Effect.GlobalEffect()
ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
ge:SetCode(EVENT_STARTUP)
ge:SetOperation(function()
    local function ensure(ok, label)
        assert(ok, 'STAGETEST ' .. label)
    end
    local deck = Duel.GetFieldGroup(0, LOCATION_DECK, 0)
    local stage_a = deck:Filter(function(c) return c:GetCode() == 999000101 end, nil):GetFirst()
    local stage_b = deck:Filter(function(c) return c:GetCode() == 999000102 end, nil):GetFirst()
    ensure(stage_a and stage_b, 'stage dummies should be in the deck')
    -- 1. placement with the faceup MASK (what the stock spell-activation path
    -- passes): OPCG must normalize it to upright/active, never rested
    ensure(Duel.MoveToField(stage_a, 0, 0, LOCATION_FZONE, POS_FACEUP, true), 'active placement should operate')
    ensure(stage_a:IsLocation(LOCATION_SZONE) and stage_a:GetSequence() == 5, 'stage should sit on szone 5')
    ensure(stage_a:IsPosition(POS_FACEUP_ATTACK), 'faceup-mask placement should land ACTIVE exactly')
    -- 2. rest it: in place, zone kept
    ensure(Duel.ChangePosition(stage_a, POS_FACEUP_DEFENSE) == 1, 'rest should operate')
    ensure(stage_a:IsPosition(POS_FACEUP_DEFENSE), 'stage should be rested')
    ensure(stage_a:IsLocation(LOCATION_SZONE) and stage_a:GetSequence() == 5, 'rest should keep the zone')
    -- 3. resting a rested stage must refuse
    ensure(Duel.ChangePosition(stage_a, POS_FACEUP_DEFENSE) == 0, 'same-position rest should refuse')
    -- 4. ready it again
    ensure(Duel.ChangePosition(stage_a, POS_FACEUP_ATTACK) == 1, 'set active should operate')
    ensure(stage_a:IsPosition(POS_FACEUP_ATTACK), 'stage should be active again')
    -- 5. rested (horizontal) placement replaces: old stage to the trash
    ensure(Duel.MoveToField(stage_b, 0, 0, LOCATION_FZONE, POS_FACEUP_DEFENSE, true), 'rested placement should operate')
    ensure(stage_b:IsLocation(LOCATION_SZONE) and stage_b:GetSequence() == 5, 'replacement should sit on szone 5')
    ensure(stage_b:IsPosition(POS_FACEUP_DEFENSE), 'replacement should arrive rested')
    ensure(stage_a:IsLocation(LOCATION_GRAVE), 'replaced stage should be in the trash')
    -- 6. the opcg helpers must agree
    ensure(opcg.IsRested(stage_b), 'opcg.IsRested should see the rested stage')
    ensure(opcg.SetActive(stage_b) == 1, 'opcg.SetActive should ready the stage')
    ensure(stage_b:IsPosition(POS_FACEUP_ATTACK), 'stage should end active')
end)
Duel.RegisterEffect(ge, 0)
";

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        errors.Clear();
        callbackErrors.Clear();
        posChanges.Clear();
        stageMoves.Clear();

        var options = new Options {
            seed0 = 1, seed1 = 2, seed2 = 3, seed3 = 4,
            flags = 0x2000000000UL,
            team1 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            team2 = new Player { startingLP = 5, startingDrawCount = 0, drawCountPerTurn = 1 },
            cardReader = cardReader,
            scriptReader = scriptReader,
            logHandler = logHandler,
            cardReaderDone = cardReaderDone,
            enableUnsafeLibraries = 1
        };
        IntPtr duel;
        var status = OCG_CreateDuel(out duel, ref options);
        if(status != 0 || duel == IntPtr.Zero) {
            Console.WriteLine("OCG_CreateDuel failed: " + status);
            return 2;
        }
        try {
            foreach(var name in new [] { "constant.lua", "utility.lua", "opcg_bootstrap.lua" })
                if(Load(duel, name) != 1)
                    callbackErrors.Add("initial script failed: " + name);

            var script = Encoding.UTF8.GetBytes(testScript);
            if(OCG_LoadScript(duel, script, (uint)script.Length, "opcg_stage_rest_test.lua") != 1)
                callbackErrors.Add("test script failed to load");

            var deckCodes = new uint[] {
                STAGE_A, STAGE_B,
                999000001, 999000002, 999000003, 999000004,
                999000005, 999000006, 999000007, 999000008
            };
            for(uint sequence = 0; sequence < deckCodes.Length; ++sequence) {
                var card = new NewCard {
                    team = 0, duelist = 0, code = deckCodes[sequence], con = 0,
                    loc = 1, seq = sequence, pos = 8
                };
                OCG_DuelNewCard(duel, ref card);
            }
            OCG_StartDuel(duel);
            int processStatus = 2;
            for(int step = 0; step < 1000 && processStatus == 2; ++step) {
                processStatus = OCG_DuelProcess(duel);
                DrainMessages(duel);
            }
        } finally {
            OCG_DestroyDuel(duel);
        }

        // the wire must carry exactly three stage position changes, in order:
        // rest, ready, ready (the helper at the end), all on szone seq 5
        var wireErrors = new List<string>();
        if(posChanges.Count != 3)
            wireErrors.Add("expected 3 stage MSG_POS_CHANGE packets, saw " + posChanges.Count);
        else {
            if(!PosChangeMatches(posChanges[0], 5, POS_FACEUP_ATTACK, POS_FACEUP_DEFENSE))
                wireErrors.Add("packet 1 is not a stage rest");
            if(!PosChangeMatches(posChanges[1], 5, POS_FACEUP_DEFENSE, POS_FACEUP_ATTACK))
                wireErrors.Add("packet 2 is not a stage ready");
            if(!PosChangeMatches(posChanges[2], 5, POS_FACEUP_DEFENSE, POS_FACEUP_ATTACK))
                wireErrors.Add("packet 3 is not a stage ready");
        }
        // and the two placements must arrive with their positions intact
        if(stageMoves.Count != 2)
            wireErrors.Add("expected 2 stage MSG_MOVE packets, saw " + stageMoves.Count);
        else {
            if(!MoveMatches(stageMoves[0], STAGE_A, 5, POS_FACEUP_ATTACK))
                wireErrors.Add("move 1 is not an active placement to szone 5");
            if(!MoveMatches(stageMoves[1], STAGE_B, 5, POS_FACEUP_DEFENSE))
                wireErrors.Add("move 2 is not a rested placement to szone 5");
        }

        Console.WriteLine(
            "pos_changes=" + posChanges.Count +
            " stage_moves=" + stageMoves.Count +
            " errors=" + errors.Count +
            " callback_failures=" + callbackErrors.Count +
            " wire_failures=" + wireErrors.Count);
        foreach(var error in callbackErrors)
            Console.WriteLine("CALLBACK: " + error);
        foreach(var error in errors)
            Console.WriteLine("SCRIPT: " + error);
        foreach(var error in wireErrors)
            Console.WriteLine("WIRE: " + error);
        var passed = errors.Count == 0 && callbackErrors.Count == 0 && wireErrors.Count == 0;
        Console.WriteLine(passed ? "STAGE_REST_HEADLESS PASS" : "STAGE_REST_HEADLESS FAIL");
        return passed ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgStageRestHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
