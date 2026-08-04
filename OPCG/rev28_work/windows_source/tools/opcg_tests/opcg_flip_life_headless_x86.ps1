param([Parameter(Mandatory = $true)][string]$Repo)

# Headless proof that ChangePosition works inside the OPCG life stack
# (LOCATION_EXTRA): flips operate in place, refuse no-ops, and emit
# MSG_POS_CHANGE on the wire exactly like an on-field flip would.
# Run with 32-bit PowerShell (the release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgFlipLifeHeadless {
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

    const byte MSG_POS_CHANGE = 53;
    const uint LOCATION_EXTRA = 0x40;
    const byte POS_FACEUP_DEFENSE = 0x4;
    const byte POS_FACEDOWN_DEFENSE = 0x8;

    static string standardScripts;
    static string expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<byte[]> posChanges = new List<byte[]>();

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            var data = new CardData {
                code = code, alias = 0, setcodes = IntPtr.Zero,
                type = 1, level = 0, attribute = 0, race = 2,
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
            if(bytes[offset] == MSG_POS_CHANGE) {
                var packet = new byte[packetLength];
                Array.Copy(bytes, offset, packet, 0, (int)packetLength);
                posChanges.Add(packet);
            }
            offset += (int)packetLength;
        }
    }

    // MSG_POS_CHANGE payload: code u32, controller u8, location u8,
    // sequence u8, previous u8, current u8 (after the 1-byte type).
    static bool PosChangeMatches(byte[] packet, uint location, byte previous, byte current) {
        return packet.Length >= 10 && packet[6] == location
            && packet[8] == previous && packet[9] == current;
    }

    const string testScript = @"
local ge = Effect.GlobalEffect()
ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
ge:SetCode(EVENT_STARTUP)
ge:SetOperation(function()
    local function ensure(ok, label)
        assert(ok, 'FLIPTEST ' .. label)
    end
    -- deal three cards from P0's deck to the life stack, face-down
    local dealt = Duel.GetDecktopGroup(0, 3)
    ensure(dealt:GetCount() == 3, 'deck should hold the dummy cards')
    Duel.Sendto(dealt, LOCATION_EXTRA, REASON_RULE, POS_FACEDOWN_DEFENSE, 0, 0)
    local life = Duel.GetFieldGroup(0, LOCATION_EXTRA, 0)
    ensure(life:GetCount() == 3, 'life stack should hold three cards')
    local top, top_sequence
    for card in aux.Next(life) do
        local sequence = card:GetSequence()
        if top_sequence == nil or sequence > top_sequence then
            top, top_sequence = card, sequence
        end
    end
    ensure(top:IsPosition(POS_FACEDOWN), 'life should start face-down')
    -- 1. flip the top card face-up: real state change, in place
    ensure(Duel.ChangePosition(top, POS_FACEUP_DEFENSE) == 1, 'face-up flip should operate')
    ensure(top:IsPosition(POS_FACEUP), 'top should be face-up')
    ensure(top:IsLocation(LOCATION_EXTRA), 'top should stay in the life stack')
    ensure(top:GetSequence() == top_sequence, 'top should keep its sequence')
    -- 2. flipping to the same face must refuse
    ensure(Duel.ChangePosition(top, POS_FACEUP_DEFENSE) == 0, 'same-face flip should refuse')
    -- 3. flip back face-down (no turn-set gate inside the life stack)
    ensure(Duel.ChangePosition(top, POS_FACEDOWN_DEFENSE) == 1, 'face-down flip should operate')
    ensure(top:IsPosition(POS_FACEDOWN), 'top should be face-down again')
    -- 4. group flip: both remaining face-down cards at once
    local rest = life:Filter(function(card) return card ~= top end, nil)
    ensure(Duel.ChangePosition(rest, POS_FACEUP_DEFENSE) == 2, 'group flip should operate on both')
    local faceup = life:Filter(Card.IsPosition, nil, POS_FACEUP)
    ensure(faceup:GetCount() == 2, 'two life cards should be face-up')
    ensure(top:IsPosition(POS_FACEDOWN), 'group flip should not touch the top')
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
            if(OCG_LoadScript(duel, script, (uint)script.Length, "opcg_flip_test.lua") != 1)
                callbackErrors.Add("test script failed to load");

            for(uint sequence = 0; sequence < 10; ++sequence) {
                var card = new NewCard {
                    team = 0, duelist = 0, code = 999000001 + sequence, con = 0,
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

        // the wire must carry exactly the four flips, in order:
        // top fd->fu, top fu->fd, then the group's two fd->fu
        var wireErrors = new List<string>();
        if(posChanges.Count != 4)
            wireErrors.Add("expected 4 MSG_POS_CHANGE packets, saw " + posChanges.Count);
        else {
            if(!PosChangeMatches(posChanges[0], LOCATION_EXTRA, POS_FACEDOWN_DEFENSE, POS_FACEUP_DEFENSE))
                wireErrors.Add("packet 1 is not a life face-up flip");
            if(!PosChangeMatches(posChanges[1], LOCATION_EXTRA, POS_FACEUP_DEFENSE, POS_FACEDOWN_DEFENSE))
                wireErrors.Add("packet 2 is not a life face-down flip");
            if(!PosChangeMatches(posChanges[2], LOCATION_EXTRA, POS_FACEDOWN_DEFENSE, POS_FACEUP_DEFENSE))
                wireErrors.Add("packet 3 is not a life face-up flip");
            if(!PosChangeMatches(posChanges[3], LOCATION_EXTRA, POS_FACEDOWN_DEFENSE, POS_FACEUP_DEFENSE))
                wireErrors.Add("packet 4 is not a life face-up flip");
        }

        Console.WriteLine(
            "pos_changes=" + posChanges.Count +
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
        Console.WriteLine(passed ? "FLIP_LIFE_HEADLESS PASS" : "FLIP_LIFE_HEADLESS FAIL");
        return passed ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgFlipLifeHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
