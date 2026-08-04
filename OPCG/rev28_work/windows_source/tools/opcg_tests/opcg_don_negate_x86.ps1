param([Parameter(Mandatory = $true)][string]$Repo)

# OP09-097 repro: does EFFECT_DISABLE (+ EFFECT_DISABLE_EFFECT) on a character
# kill the +1000-per-attached-DON!! (EFFECT_TYPE_XMATERIAL on the DON card)?
# Official rule: it must NOT — the boost belongs to the DON!! card.
# Run with 32-bit PowerShell (the release ocgcore.dll is Win32).

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class OpcgDonNegateHeadless {
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
    [DllImport("ocgcore.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void OCG_DuelSetResponse(IntPtr duel, byte[] buffer, uint length);

    const uint CHAR_A = 999000201;
    const uint SRC_B = 999000202;

    static string standardScripts;
    static string expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();
    static readonly List<string> probes = new List<string>();

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            var data = new CardData {
                code = code, alias = 0, setcodes = IntPtr.Zero,
                type = 0x21, level = 0, attribute = 0,
                race = 2, // OPCG character
                attack = (code == CHAR_A) ? 5000 : 0,
                defense = 0, category = 0
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
        else
            probes.Add(text);
    }
    static int Load(IntPtr duel, string name) {
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

    static readonly List<byte> messageTypes = new List<byte>();
    static byte[] lastSelectPlace;
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
            messageTypes.Add(bytes[offset]);
            if(bytes[offset] == 18) {
                lastSelectPlace = new byte[packetLength];
                Array.Copy(bytes, offset, lastSelectPlace, 0, (int)packetLength);
            }
            offset += (int)packetLength;
        }
    }
    // MSG_SELECT_PLACE payload: type u8, player u8, count u8, flag u32.
    // flag SET bit = disabled place. self: mzone bits 0-6, szone bits 8-15.
    static byte[] AnswerSelectPlace() {
        var player = lastSelectPlace[1];
        var flag = BitConverter.ToUInt32(lastSelectPlace, 3);
        for(int bit = 0; bit < 7; ++bit)
            if((flag & (1u << bit)) == 0)
                return new byte[] { player, 0x04, (byte)bit };
        for(int bit = 8; bit < 16; ++bit)
            if((flag & (1u << bit)) == 0)
                return new byte[] { player, 0x08, (byte)(bit - 8) };
        return new byte[] { player, 0x04, 0 };
    }

    const string testScript = @"
local ge = Effect.GlobalEffect()
ge:SetType(EFFECT_TYPE_FIELD + EFFECT_TYPE_CONTINUOUS)
ge:SetCode(EVENT_STARTUP)
ge:SetOperation(function()
    local function probe(text) Debug.Message(text) end
    local function ensure(ok, label) assert(ok, 'DONNEGATE ' .. label) end
    local deck = Duel.GetFieldGroup(0, LOCATION_DECK, 0)
    local char = deck:Filter(function(c) return c:GetCode() == 999000201 end, nil):GetFirst()
    local src = deck:Filter(function(c) return c:GetCode() == 999000202 end, nil):GetFirst()
    ensure(char and src, 'dummies in deck')
    probe('turn_player=' .. tostring(Duel.GetTurnPlayer()))
    ensure(Duel.MoveToField(char, 0, 0, LOCATION_MZONE, POS_FACEUP_ATTACK, true, 0x1), 'character placed')
    local base = char:GetAttack()
    probe('attack_base=' .. base)
    opcg.SetupDonHosts(0)
    ensure(opcg.AddDon(0, 2) == 2, 'don to cost area')
    ensure(opcg.GiveDon(0, char, 2, 'ACTIVE') == 2, 'don attached')
    local with_don = char:GetAttack()
    probe('attack_with_don=' .. with_don)
    -- mimic contract NEGATE_EFFECTS exactly: owner = the negating card
    local e1 = Effect.CreateEffect(src)
    e1:SetType(EFFECT_TYPE_SINGLE)
    e1:SetCode(EFFECT_DISABLE)
    e1:SetValue(1)
    e1:SetReset(RESET_PHASE + PHASE_END)
    char:RegisterEffect(e1)
    local use_disable_effect = true
    if use_disable_effect then
        local e2 = Effect.CreateEffect(src)
        e2:SetType(EFFECT_TYPE_SINGLE)
        e2:SetCode(EFFECT_DISABLE_EFFECT)
        e2:SetValue(1)
        e2:SetReset(RESET_PHASE + PHASE_END)
        char:RegisterEffect(e2)
    end
    if Duel.AdjustInstantly then Duel.AdjustInstantly(char) end
    local negated = char:GetAttack()
    probe('attack_negated=' .. negated)
    probe('status_disabled=' .. tostring(char.IsDisabled and char:IsDisabled() or 'n/a'))
end)
Duel.RegisterEffect(ge, 0)
";

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");

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
            if(OCG_LoadScript(duel, script, (uint)script.Length, "opcg_don_negate_test.lua") != 1)
                callbackErrors.Add("test script failed to load");

            var deckCodes = new uint[] {
                CHAR_A, SRC_B,
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
                if(processStatus == 1) {
                    var last = messageTypes.Count > 0 ? messageTypes[messageTypes.Count - 1] : (byte)0;
                    if(last == 18 && lastSelectPlace != null) { // MSG_SELECT_PLACE
                        var answer = AnswerSelectPlace();
                        OCG_DuelSetResponse(duel, answer, (uint)answer.Length);
                        processStatus = 2;
                    }
                }
            }
            Console.WriteLine("final_status=" + processStatus);
        } finally {
            OCG_DestroyDuel(duel);
        }

        Console.WriteLine("errors=" + errors.Count + " callback_failures=" + callbackErrors.Count);
        var tail = messageTypes.Count <= 12 ? messageTypes : messageTypes.GetRange(messageTypes.Count - 12, 12);
        Console.WriteLine("msg_count=" + messageTypes.Count + " tail=" + string.Join(",", tail));
        foreach(var probe in probes)
            Console.WriteLine("PROBE: " + probe);
        foreach(var error in callbackErrors)
            Console.WriteLine("CALLBACK: " + error);
        foreach(var error in errors)
            Console.WriteLine("SCRIPT: " + error);
        return (errors.Count == 0 && callbackErrors.Count == 0) ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgDonNegateHeadless]::Run((Resolve-Path -LiteralPath $Repo).Path)
