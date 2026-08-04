// Adversarial verification for OCG_DuelRewind (in-core time rewind), v3.
// v2 compared only outbound prompt bytes - "byte-identical prompt" can mask a
// diverged internal state. v3 attacks that blind spot:
//   - deep STATE FINGERPRINT via OCG_DuelQueryField + OCG_DuelQueryLocation
//     (deck ORDER, board codes/positions/atk/def/level/counters, LP, chain)
//   - a duel that actually mutates state: normal summons + zone placement
//   - rewind-to-zero edge, full-length redo determinism
//   - 30x rewind ping-pong with working-set flatness measurement
// usage: rewind_harness.exe [ocgcore.dll path] [fault]
#include <windows.h>
#include <psapi.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

typedef void* OCG_Duel;
struct OCG_CardData {
	uint32_t code, alias;
	uint16_t* setcodes;
	uint32_t type, level, attribute;
	uint64_t race;
	int32_t attack, defense;
	uint32_t lscale, rscale, link_marker, category;
};
struct OCG_Player { uint32_t startingLP, startingDrawCount, drawCountPerTurn; };
typedef void (*OCG_DataReader)(void* payload, uint32_t code, OCG_CardData* data);
typedef int (*OCG_ScriptReader)(void* payload, OCG_Duel duel, const char* name);
typedef void (*OCG_LogHandler)(void* payload, const char* string, int type);
typedef void (*OCG_DataReaderDone)(void* payload, OCG_CardData* data);
struct OCG_DuelOptions {
	uint64_t seed[4];
	uint64_t flags;
	OCG_Player team1, team2;
	OCG_DataReader cardReader; void* payload1;
	OCG_ScriptReader scriptReader; void* payload2;
	OCG_LogHandler logHandler; void* payload3;
	OCG_DataReaderDone cardReaderDone; void* payload4;
	uint8_t enableUnsafeLibraries;
};
struct OCG_NewCardInfo {
	uint8_t team, duelist;
	uint32_t code;
	uint8_t con;
	uint32_t loc, seq, pos;
};
struct OCG_QueryInfo {
	uint32_t flags;
	uint8_t con;
	uint32_t loc, seq, overlay_seq;
};

typedef int  (*fnCreateDuel)(OCG_Duel*, const OCG_DuelOptions*);
typedef void (*fnDestroyDuel)(OCG_Duel);
typedef void (*fnNewCard)(OCG_Duel, const OCG_NewCardInfo*);
typedef void (*fnStartDuel)(OCG_Duel);
typedef int  (*fnProcess)(OCG_Duel);
typedef void*(*fnGetMessage)(OCG_Duel, uint32_t*);
typedef void (*fnSetResponse)(OCG_Duel, const void*, uint32_t);
typedef int  (*fnLoadScript)(OCG_Duel, const char*, uint32_t, const char*);
typedef void (*fnRewind)(OCG_Duel, uint32_t);
typedef void*(*fnQueryLocation)(OCG_Duel, uint32_t*, const OCG_QueryInfo*);
typedef void*(*fnQueryField)(OCG_Duel, uint32_t*);

static const char* SCRIPT_DIR = "F:\\edopcg_CODEX_INTEGRATED_20260701_FINAL_EDIT_BY_CLAUDE_FABLE\\bin\\release\\script\\";
static fnLoadScript g_LoadScript = nullptr;

static void CardReader(void*, uint32_t code, OCG_CardData* data) {
	std::memset(data, 0, sizeof(*data));
	data->code = code;
	data->type = 0x1 | 0x10;      // TYPE_MONSTER | TYPE_NORMAL
	data->level = 4;
	data->attribute = 0x01;
	data->race = 0x1;
	data->attack = 1000 + (int32_t)(code % 100);
	data->defense = 1000;
}
static void CardReaderDone(void*, OCG_CardData*) {}
static std::vector<char> ReadFileBytes(const std::string& path) {
	std::vector<char> out;
	FILE* fp = nullptr;
	fopen_s(&fp, path.c_str(), "rb");
	if(!fp) return out;
	fseek(fp, 0, SEEK_END);
	long sz = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	out.resize(sz);
	if(sz) fread(out.data(), 1, sz, fp);
	fclose(fp);
	return out;
}
static int ScriptReader(void*, OCG_Duel duel, const char* name) {
	std::string n(name);
	auto pos = n.find_last_of("/\\");
	if(pos != std::string::npos) n = n.substr(pos + 1);
	auto buf = ReadFileBytes(std::string(SCRIPT_DIR) + n);
	if(buf.empty()) return 0;
	return g_LoadScript(duel, buf.data(), (uint32_t)buf.size(), name);
}
static void LogHandler(void*, const char* s, int type) {
	fprintf(stderr, "[corelog t=%d] %s\n", type, s);
}

struct Msg { uint8_t type; std::vector<uint8_t> bytes; };
static std::vector<Msg> ParseBuffer(const uint8_t* buf, uint32_t len) {
	std::vector<Msg> out;
	uint32_t p = 0;
	while(p + 4 <= len) {
		uint32_t sz; std::memcpy(&sz, buf + p, 4); p += 4;
		if(p + sz > len || sz == 0) break;
		Msg m; m.type = buf[p];
		m.bytes.assign(buf + p, buf + p + sz);
		out.push_back(std::move(m));
		p += sz;
	}
	return out;
}
static size_t WorkingSetMB() {
	PROCESS_MEMORY_COUNTERS pmc{};
	pmc.cb = sizeof(pmc);
	K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc));
	return pmc.WorkingSetSize / (1024 * 1024);
}

int main(int argc, char** argv) {
	const char* dll_path = (argc > 1) ? argv[1]
		: "F:\\edopcg_CODEX_INTEGRATED_20260701_FINAL_EDIT_BY_CLAUDE_FABLE\\bin\\release\\ocgcore.dll";
	const bool fault_mode = (argc > 2 && std::strcmp(argv[2], "fault") == 0);
	HMODULE dll = LoadLibraryA(dll_path);
	if(!dll) { printf("FAIL: LoadLibrary(%s) %lu\n", dll_path, GetLastError()); return 1; }
	printf("INFO: dll = %s%s\n", dll_path, fault_mode ? " [fault mode]" : "");
	auto CreateDuel  = (fnCreateDuel) GetProcAddress(dll, "OCG_CreateDuel");
	auto DestroyDuel = (fnDestroyDuel)GetProcAddress(dll, "OCG_DestroyDuel");
	auto NewCard     = (fnNewCard)    GetProcAddress(dll, "OCG_DuelNewCard");
	auto StartDuel   = (fnStartDuel)  GetProcAddress(dll, "OCG_StartDuel");
	auto Process     = (fnProcess)    GetProcAddress(dll, "OCG_DuelProcess");
	auto GetMessage_ = (fnGetMessage) GetProcAddress(dll, "OCG_DuelGetMessage");
	auto SetResponse = (fnSetResponse)GetProcAddress(dll, "OCG_DuelSetResponse");
	g_LoadScript     = (fnLoadScript) GetProcAddress(dll, "OCG_LoadScript");
	auto Rewind      = (fnRewind)     GetProcAddress(dll, "OCG_DuelRewind");
	auto QueryLoc    = (fnQueryLocation)GetProcAddress(dll, "OCG_DuelQueryLocation");
	auto QueryField  = (fnQueryField) GetProcAddress(dll, "OCG_DuelQueryField");
	if(!CreateDuel || !Rewind || !g_LoadScript || !QueryLoc || !QueryField) { printf("FAIL: missing exports\n"); return 1; }

	OCG_DuelOptions opts{};
	opts.seed[0] = 0x1111; opts.seed[1] = 0x2222; opts.seed[2] = 0x3333; opts.seed[3] = 0x4444;
	opts.flags = 0;
	opts.team1 = { 8000, 5, 1 };
	opts.team2 = { 8000, 5, 1 };
	opts.cardReader = CardReader;
	opts.scriptReader = ScriptReader;
	opts.logHandler = LogHandler;
	opts.cardReaderDone = CardReaderDone;
	opts.enableUnsafeLibraries = 1;

	OCG_Duel duel = nullptr;
	if(CreateDuel(&duel, &opts) != 0) { printf("FAIL: CreateDuel\n"); return 1; }
	for(const char* s : { "constant.lua", "utility.lua" }) {
		auto buf = ReadFileBytes(std::string(SCRIPT_DIR) + s);
		if(buf.empty() || !g_LoadScript(duel, buf.data(), (uint32_t)buf.size(), s)) {
			printf("FAIL: load %s\n", s); return 1;
		}
	}
	for(int team = 0; team < 2; ++team) {
		for(int i = 0; i < 15; ++i) {
			OCG_NewCardInfo ci{};
			ci.team = (uint8_t)team; ci.duelist = 0;
			ci.code = (team ? 2001 : 1001) + i;
			ci.con = (uint8_t)team; ci.loc = 0x01; ci.seq = 0; ci.pos = 0x8;
			NewCard(duel, &ci);
		}
	}
	StartDuel(duel);

	// deep state fingerprint: full field snapshot + every location list with
	// code/position/level/atk/def/counters. Deck order included - any RNG
	// stream divergence between timelines shows up here immediately.
	auto fingerprint = [&]() -> std::vector<uint8_t> {
		std::vector<uint8_t> fp;
		uint32_t len = 0;
		auto* f = (const uint8_t*)QueryField(duel, &len);
		fp.insert(fp.end(), (const uint8_t*)&len, (const uint8_t*)&len + 4);
		if(f && len) fp.insert(fp.end(), f, f + len);
		for(uint8_t con = 0; con < 2; ++con) {
			for(uint32_t loc : { 0x01u, 0x02u, 0x04u, 0x08u, 0x10u, 0x20u, 0x40u }) {
				OCG_QueryInfo qi{ 0x1 | 0x2 | 0x10 | 0x100 | 0x200 | 0x20000, con, loc, 0, 0 };
				len = 0;
				auto* q = (const uint8_t*)QueryLoc(duel, &len, &qi);
				fp.insert(fp.end(), (const uint8_t*)&len, (const uint8_t*)&len + 4);
				if(q && len) fp.insert(fp.end(), q, q + len);
			}
		}
		return fp;
	};

	struct Prompt { uint8_t type; std::vector<uint8_t> bytes; bool reload; };
	auto next_prompt = [&](int guard = 800) -> Prompt {
		bool saw_reload = false;
		while(guard-- > 0) {
			int st = Process(duel);
			uint32_t len = 0;
			auto* buf = (const uint8_t*)GetMessage_(duel, &len);
			auto msgs = ParseBuffer(buf, len);
			for(auto& m : msgs) {
				if(m.type == 162) saw_reload = true;
				if(m.type == 11 || m.type == 16 || m.type == 18)
					return { m.type, m.bytes, saw_reload };
				if(m.type == 5) { printf("INFO: MSG_WIN\n"); return { 0, {}, saw_reload }; }
			}
			if(st == 0) { printf("INFO: END status\n"); return { 0, {}, saw_reload }; }
			if(st == 1) {
				printf("FAIL: awaiting on unhandled prompt (types:");
				for(auto& m : msgs) printf(" %d", m.type);
				printf(")\n");
				return { 0, {}, saw_reload };
			}
		}
		printf("FAIL: pump guard exhausted\n");
		return { 0, {}, false };
	};
	// live policy: summon whenever the core offers a summonable card, place
	// it in the lowest free own mzone, otherwise pass; decline chain windows
	auto decide = [&](const Prompt& p) -> std::vector<uint8_t> {
		std::vector<uint8_t> r(4, 0);
		if(p.type == 11) {
			uint32_t summonable = 0;
			if(p.bytes.size() >= 6) std::memcpy(&summonable, p.bytes.data() + 2, 4);
			uint32_t v = summonable ? 0u : 7u; // summon first / to end phase
			std::memcpy(r.data(), &v, 4);
		} else if(p.type == 16) {
			int32_t v = -1;
			std::memcpy(r.data(), &v, 4);
		} else { // 18: {player, count, flag(u32, bit set = unusable)}
			uint8_t player = p.bytes.size() > 1 ? p.bytes[1] : 0;
			uint32_t flag = 0;
			if(p.bytes.size() >= 7) std::memcpy(&flag, p.bytes.data() + 3, 4);
			uint8_t seq = 0;
			for(uint8_t s = 0; s < 5; ++s)
				if(!(flag & (1u << s))) { seq = s; break; }
			r = { player, 0x04, seq };
		}
		return r;
	};
	auto feed = [&](const std::vector<uint8_t>& r) { SetResponse(duel, r.data(), (uint32_t)r.size()); };

	const size_t LIVE = 14;
	std::vector<Prompt> prompts;
	std::vector<std::vector<uint8_t>> resps;
	std::vector<std::vector<uint8_t>> fps;
	int summons_seen = 0;
	while(prompts.size() < LIVE) {
		auto p = next_prompt();
		if(p.type == 0) { printf("FAIL: live died at %zu\n", prompts.size()); return 1; }
		if(p.type == 18) ++summons_seen;
		prompts.push_back(p);
		fps.push_back(fingerprint());
		auto r = decide(p);
		resps.push_back(r);
		feed(r);
	}
	auto pending = next_prompt();
	if(pending.type == 0) { printf("FAIL: no pending prompt\n"); return 1; }
	prompts.push_back(pending);
	fps.push_back(fingerprint());
	printf("INFO: live journal built - %zu responses, %d placements, pending prompt type %d\n", resps.size(), summons_seen, pending.type);
	if(summons_seen < 2) { printf("FAIL: policy produced <2 summons; duel too trivial for the drill\n"); return 1; }

	if(fault_mode) {
		// dll rejects the 4th fed journal entry: land on prompts[3], fresh
		// prompt + reload, journal poisoned, timeline consistent afterwards
		Rewind(duel, 4);
		auto p = next_prompt();
		if(p.type == 0 || !p.reload) { printf("FAIL: fault rewind missing prompt/reload\n"); return 1; }
		if(p.bytes != prompts[3].bytes) { printf("FAIL: fault landing != prompts[3]\n"); return 1; }
		if(fingerprint() != fps[3]) { printf("FAIL: fault landing fingerprint != fps[3]\n"); return 1; }
		printf("PASS: fault landing = prompts[3] bytes AND state fingerprint\n");
		feed(resps[3]);
		auto q = next_prompt();
		if(q.type == 0 || q.bytes != prompts[4].bytes || q.reload) { printf("FAIL: post-fault continuation\n"); return 1; }
		Rewind(duel, 1); // poisoned -> must be refused
		feed(resps[4]);
		auto r2 = next_prompt();
		if(r2.type == 0 || r2.bytes != prompts[5].bytes || r2.reload) { printf("FAIL: poisoned journal not refused\n"); return 1; }
		printf("PASS: poisoned journal refused, timeline consistent\n");
		DestroyDuel(duel);
		printf("FAULT DRILL v3 GREEN\n");
		return 0;
	}

	// T1: rewind(4) -> prompts[10] AND full state fingerprint fps[10]
	Rewind(duel, 4);
	{
		auto p = next_prompt();
		if(p.type == 0 || !p.reload) { printf("FAIL: T1 prompt/reload\n"); return 1; }
		if(p.bytes != prompts[10].bytes) { printf("FAIL: T1 prompt != prompts[10]\n"); return 1; }
		auto fp = fingerprint();
		if(fp != fps[10]) { printf("FAIL: T1 STATE DIVERGENCE - fingerprint != fps[10] (%zu vs %zu bytes)\n", fp.size(), fps[10].size()); return 1; }
		printf("PASS T1: rewind(4) prompt AND deep state fingerprint identical (fp %zu bytes)\n", fp.size());
	}
	// T2: redo 10..13 with recorded responses -> reconverge on fps[14]
	for(size_t i = 10; i < 14; ++i) {
		feed(resps[i]);
		auto p = next_prompt();
		if(p.type == 0 || p.reload) { printf("FAIL: T2 leg %zu\n", i); return 1; }
		if(p.bytes != prompts[i + 1].bytes) { printf("FAIL: T2 prompt diverged at %zu\n", i + 1); return 1; }
	}
	if(fingerprint() != fps[14]) { printf("FAIL: T2 STATE DIVERGENCE at reconvergence point\n"); return 1; }
	printf("PASS T2: redo reconverged - prompts 11..14 and final state fingerprint identical\n");

	// T3: rewind past everything -> very first decision point
	Rewind(duel, 100000);
	{
		auto p = next_prompt();
		if(p.type == 0 || !p.reload) { printf("FAIL: T3 prompt/reload\n"); return 1; }
		if(p.bytes != prompts[0].bytes) { printf("FAIL: T3 prompt != prompts[0]\n"); return 1; }
		if(fingerprint() != fps[0]) { printf("FAIL: T3 STATE DIVERGENCE at zero point\n"); return 1; }
		printf("PASS T3: rewind-to-zero lands on first prompt with identical state\n");
	}
	// T4: full-length redo through summons/placements
	for(size_t i = 0; i < 14; ++i) {
		feed(resps[i]);
		auto p = next_prompt();
		if(p.type == 0 || p.reload) { printf("FAIL: T4 leg %zu\n", i); return 1; }
		if(p.bytes != prompts[i + 1].bytes) { printf("FAIL: T4 prompt diverged at %zu\n", i + 1); return 1; }
	}
	if(fingerprint() != fps[14]) { printf("FAIL: T4 STATE DIVERGENCE after full redo\n"); return 1; }
	printf("PASS T4: full-length redo (14 responses incl. summons) state-identical\n");

	// T5: 30x rewind ping-pong + working set flatness
	size_t ws_start = WorkingSetMB(), ws_peak = ws_start;
	for(int i = 0; i < 30; ++i) {
		Rewind(duel, 1);
		auto p = next_prompt();
		if(p.type == 0 || !p.reload) { printf("FAIL: T5 rewind %d\n", i); return 1; }
		if(p.bytes != prompts[13].bytes) { printf("FAIL: T5 prompt drift at %d\n", i); return 1; }
		feed(resps[13]);
		auto q = next_prompt();
		if(q.type == 0 || q.bytes != prompts[14].bytes) { printf("FAIL: T5 follow drift at %d\n", i); return 1; }
		size_t ws = WorkingSetMB();
		if(ws > ws_peak) ws_peak = ws;
	}
	size_t ws_end = WorkingSetMB();
	printf("INFO: working set start=%zuMB peak=%zuMB end=%zuMB over 30 rewinds\n", ws_start, ws_peak, ws_end);
	if(ws_end > ws_start + 25) { printf("FAIL: T5 memory growth %zuMB - zombie reclaim broken\n", ws_end - ws_start); return 1; }
	printf("PASS T5: 30x rewind ping-pong state-stable, memory flat\n");

	DestroyDuel(duel);
	printf("PASS: duel destroyed cleanly\n");
	printf("ALL GREEN v3\n");
	return 0;
}
