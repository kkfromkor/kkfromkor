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

public static class OpcgLifeReorder {
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
            if(bytes[offset] == MSG_MOVE && packetLength >= 25
                && bytes[offset + 6] == 0x40 && bytes[offset + 16] == 0x40) {
                var packet = new byte[packetLength];
                Array.Copy(bytes, offset, packet, 0, (int)packetLength);
                posChanges.Add(packet);
            }
            offset += (int)packetLength;
        }
    }


    const string testScript =
    "local ge = Effect.GlobalEffect()\n" +
    "ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)\n" +
    "ge:SetCode(EVENT_STARTUP)\n" +
    "ge:SetOperation(function()\n" +
    "    local function ensure(ok, label)\n" +
    "        assert(ok, 'REORDER ' .. label)\n" +
    "    end\n" +
    "    local dealt = Duel.GetDecktopGroup(0, 4)\n" +
    "    ensure(dealt:GetCount() == 4, 'deck should hold the dummy cards')\n" +
    "    Duel.Sendto(dealt, LOCATION_EXTRA, REASON_RULE, POS_FACEDOWN_DEFENSE, 0, 0)\n" +
    "    local function stack()\n" +
    "        local cards = {}\n" +
    "        for card in aux.Next(Duel.GetFieldGroup(0, LOCATION_EXTRA, 0)) do\n" +
    "            cards[card:GetSequence() + 1] = card\n" +
    "        end\n" +
    "        return cards\n" +
    "    end\n" +
    "    local life = stack()\n" +
    "    ensure(#life == 4, 'life stack should hold four cards')\n" +
    "    local top, second, bottom = life[4], life[3], life[1]\n" +
    "    -- 1. top -> bottom is a single honored move\n" +
    "    Duel.MoveSequence(top, 0)\n" +
    "    ensure(top:GetSequence() == 0, 'top should now sit at the bottom')\n" +
    "    ensure(second:GetSequence() == 3, 'old second should now be the top')\n" +
    "    -- 2. in-place request moves nothing\n" +
    "    Duel.MoveSequence(top, 0)\n" +
    "    ensure(top:GetSequence() == 0, 'in-place request keeps the bottom')\n" +
    "    -- 3. rebuilding the current order is wire-silent\n" +
    "    local current = stack()\n" +
    "    for index, card in ipairs(current) do\n" +
    "        if card:GetSequence() ~= index - 1 then Duel.MoveSequence(card, index - 1) end\n" +
    "    end\n" +
    "    ensure(current[1]:GetSequence() == 0, 'rebuild keeps the stack intact')\n" +
    "    -- 4. oversized sequence clamps to the top\n" +
    "    Duel.MoveSequence(bottom, 99)\n" +
    "    ensure(bottom:GetSequence() == 3, 'oversized request lands on top')\n" +
    "end)\n" +
    "Duel.RegisterEffect(ge, 0)\n";


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

        // the wire must carry exactly TWO reorder moves (steps 1 and 4);
        // in-place and rebuild requests stay silent
        var wireErrors = new List<string>();
        if(posChanges.Count != 2)
            wireErrors.Add("expected 2 life reorder MSG_MOVE packets, saw " + posChanges.Count);

        Console.WriteLine(
            "reorder_moves=" + posChanges.Count +
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
        Console.WriteLine(passed ? "LIFE_REORDER PASS" : "LIFE_REORDER FAIL");
        return passed ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgLifeReorder]::Run((Resolve-Path -LiteralPath $Repo).Path)
