param([Parameter(Mandatory = $true)][string]$Repo)

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public static class OpcgRuntimeLogRepro {
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
    static extern int OCG_LoadScript(
        IntPtr duel, byte[] buffer, uint length,
        [MarshalAs(UnmanagedType.LPStr)] string name);

    static string standardScripts;
    static string expansionScripts;
    static readonly List<string> errors = new List<string>();
    static readonly List<string> callbackErrors = new List<string>();

    static readonly DataReader cardReader = ReadCard;
    static readonly DataReaderDone cardReaderDone = DoneCard;
    static readonly ScriptReader scriptReader = ReadScript;
    static readonly LogHandler logHandler = Log;

    static void ReadCard(IntPtr payload, uint code, IntPtr output) {
        try {
            var data = new CardData {
                code = code,
                alias = 0,
                setcodes = IntPtr.Zero,
                type = 1,
                level = 0,
                attribute = 0,
                race = 2,
                attack = 0,
                defense = 0,
                category = 0
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

    public static int Run(string repo) {
        var release = Path.Combine(repo, "bin", "release");
        Directory.SetCurrentDirectory(release);
        standardScripts = Path.Combine(release, "script");
        expansionScripts = Path.Combine(release, "expansions", "script");
        errors.Clear();
        callbackErrors.Clear();

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

            uint sequence = 0;
            for(uint code = 880000000; code <= 880002004; ++code) {
                var card = new NewCard {
                    team = 0, duelist = 0, code = code, con = 0,
                    loc = 1, seq = sequence++, pos = 8
                };
                OCG_DuelNewCard(duel, ref card);
            }
            for(uint code = 881000000; code <= 881000550; ++code) {
                var card = new NewCard {
                    team = 0, duelist = 0, code = code, con = 0,
                    loc = 1, seq = sequence++, pos = 8
                };
                OCG_DuelNewCard(duel, ref card);
            }
            OCG_StartDuel(duel);
            int processStatus = 2;
            for(int step = 0; step < 10000 && processStatus == 2; ++step)
                processStatus = OCG_DuelProcess(duel);
            Console.WriteLine("process_status=" + processStatus);
        } finally {
            OCG_DestroyDuel(duel);
        }

        Console.WriteLine(
            "cards=2556 errors=" + errors.Count +
            " callback_failures=" + callbackErrors.Count);
        foreach(var error in callbackErrors)
            Console.WriteLine("CALLBACK: " + error);
        foreach(var error in errors)
            Console.WriteLine("SCRIPT: " + error);
        return errors.Count == 0 && callbackErrors.Count == 0 ? 0 : 1;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
exit [OpcgRuntimeLogRepro]::Run((Resolve-Path -LiteralPath $Repo).Path)
