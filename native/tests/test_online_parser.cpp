// Standalone unit test for online level parser logic and legacy Geometry Dash
// compatibility behavior in native/src/gdash_native.cpp.
//
// Build & run:
//   g++ -std=c++17 -O2 -Inative/godot-cpp/include -Inative/godot-cpp/gen/include \
//       -Inative/godot-cpp/gdextension native/tests/test_online_parser.cpp \
//       native/godot-cpp/bin/libgodot-cpp.linux.template_debug.x86_64.a -lpthread -o /tmp/online_parser_test
//   /tmp/online_parser_test

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <unordered_map>
#include <vector>

#if __has_include(<godot_cpp/variant/color.hpp>)
#include <godot_cpp/variant/color.hpp>
using godot::Color;
#else
struct Color {
	float r = 1.0f, g = 1.0f, b = 1.0f, a = 1.0f;
	Color() = default;
	Color(float pr, float pg, float pb, float pa = 1.0f) : r(pr), g(pg), b(pb), a(pa) {}
	float get_h() const { return 0.0f; }
	float get_s() const { return (r == g && g == b) ? 0.0f : 0.5f; }
	float get_v() const { return std::max({r, g, b}); }
	Color lightened(float amt) const { return Color(r + (1.0f - r) * amt, g + (1.0f - g) * amt, b + (1.0f - b) * amt, a); }
	static Color from_hsv(float h, float s, float v, float a = 1.0f) {
		if (s == 0.0f) return Color(v, v, v, a);
		return Color(v, v * (1.0f - s), v * (1.0f - s), a);
	}
	bool operator==(const Color &o) const { return r == o.r && g == o.g && b == o.b && a == o.a; }
};
#endif

static int failures = 0;

static void check_true(const char *name, bool cond) {
	if (!cond) {
		std::printf("FAIL: %s\n", name);
		++failures;
	} else {
		std::printf("PASS: %s\n", name);
	}
}

static void check_int(const char *name, int64_t actual, int64_t expected) {
	if (actual != expected) {
		std::printf("FAIL: %s (expected %lld, got %lld)\n", name, (long long)expected, (long long)actual);
		++failures;
	} else {
		std::printf("PASS: %s\n", name);
	}
}

// Mirror of legacy_color_trigger_channel from gdash_native.cpp
static inline int64_t legacy_color_trigger_channel(int64_t trigger_id) {
	switch (trigger_id) {
		case 29: return 1000;
		case 30: return 1001;
		case 105: return 1004;
		case 744: return 1003;
		case 900: return 1009;
		case 915: return 1002;
		default: return 0;
	}
}

// Mirror of GameObject::getColorIndex legacy mapping from decompiled GD 2.205 / 1.9
static inline int64_t legacy_object_color_channel(int64_t old_color_id) {
	switch (old_color_id) {
		case 1: return 1005; // Player 1
		case 2: return 1006; // Player 2
		case 3: return 1;    // Color 1
		case 4: return 2;    // Color 2
		case 5: return 1007; // Tint / LBG
		case 6: return 3;    // Color 3
		case 7: return 4;    // Color 4
		case 8: return 1003; // 3DL
		default: return 0;
	}
}

// Mirror of GameObject::newObjectFromVector object substitution from decompiled GD
static inline int64_t substitute_object_id(int64_t key, int64_t &target_color, bool &uses_blending) {
	int64_t key_orig = -1;
	int64_t new_key = key;
	switch (key) {
		case 104:
			key_orig = key;
			new_key = 915;
			break;
		case 221:
		case 717:
		case 718:
		case 743:
			key_orig = key;
			new_key = 899;
			break;
		case 675: new_key = 1734; break;
		case 676: new_key = 1735; break;
		case 677: new_key = 1736; break;
		case 1008: new_key = 1292; break;
		default:
			if (key >= 1964 && key < 2012) {
				new_key = 1964;
			}
			break;
	}
	if (key_orig != -1) {
		switch (key_orig) {
			case 104: uses_blending = true; break;
			case 221: target_color = 1; break;
			case 717: target_color = 2; break;
			case 718: target_color = 3; break;
			case 743: target_color = 4; break;
		}
	}
	return new_key;
}

int main() {
	// 1. Verify legacy trigger channel mappings match decompiled GD EffectGameObject::customSetup
	check_int("trigger 29 -> BG (1000)", legacy_color_trigger_channel(29), 1000);
	check_int("trigger 30 -> G1 (1001)", legacy_color_trigger_channel(30), 1001);
	check_int("trigger 105 -> Obj (1004)", legacy_color_trigger_channel(105), 1004);
	check_int("trigger 744 -> 3DL (1003)", legacy_color_trigger_channel(744), 1003);
	check_int("trigger 900 -> G2 (1009)", legacy_color_trigger_channel(900), 1009);
	check_int("trigger 915 -> Line (1002)", legacy_color_trigger_channel(915), 1002);
	check_int("trigger 899 -> 0 (uses target color)", legacy_color_trigger_channel(899), 0);

	// 2. Verify legacy object color channel mappings match decompiled GD GameObject::customObjectSetup
	check_int("legacy color 1 -> P1 (1005)", legacy_object_color_channel(1), 1005);
	check_int("legacy color 2 -> P2 (1006)", legacy_object_color_channel(2), 1006);
	check_int("legacy color 3 -> Col 1 (1)", legacy_object_color_channel(3), 1);
	check_int("legacy color 4 -> Col 2 (2)", legacy_object_color_channel(4), 2);
	check_int("legacy color 5 -> LBG (1007)", legacy_object_color_channel(5), 1007);
	check_int("legacy color 6 -> Col 3 (3)", legacy_object_color_channel(6), 3);
	check_int("legacy color 7 -> Col 4 (4)", legacy_object_color_channel(7), 4);
	check_int("legacy color 8 -> 3DL (1003)", legacy_object_color_channel(8), 1003);

	// 2b. Verify object ID substitutions match decompiled GD GameObject::newObjectFromVector
	int64_t target_col = 0;
	bool uses_blend = false;
	check_int("object 104 -> 915", substitute_object_id(104, target_col, uses_blend), 915);
	check_true("object 104 uses blending", uses_blend);

	target_col = 0; uses_blend = false;
	check_int("object 221 -> 899", substitute_object_id(221, target_col, uses_blend), 899);
	check_int("object 221 target color 1", target_col, 1);

	target_col = 0; uses_blend = false;
	check_int("object 717 -> 899", substitute_object_id(717, target_col, uses_blend), 899);
	check_int("object 717 target color 2", target_col, 2);

	target_col = 0; uses_blend = false;
	check_int("object 718 -> 899", substitute_object_id(718, target_col, uses_blend), 899);
	check_int("object 718 target color 3", target_col, 3);

	target_col = 0; uses_blend = false;
	check_int("object 743 -> 899", substitute_object_id(743, target_col, uses_blend), 899);
	check_int("object 743 target color 4", target_col, 4);

	target_col = 0; uses_blend = false;
	check_int("object 675 -> 1734", substitute_object_id(675, target_col, uses_blend), 1734);
	check_int("object 676 -> 1735", substitute_object_id(676, target_col, uses_blend), 1735);
	check_int("object 677 -> 1736", substitute_object_id(677, target_col, uses_blend), 1736);
	check_int("object 1008 -> 1292", substitute_object_id(1008, target_col, uses_blend), 1292);
	check_int("object 1964 -> 1964", substitute_object_id(1964, target_col, uses_blend), 1964);
	check_int("object 2000 -> 1964", substitute_object_id(2000, target_col, uses_blend), 1964);
	check_int("object 2011 -> 1964", substitute_object_id(2011, target_col, uses_blend), 1964);
	check_int("object 2012 -> 2012 (not substituted)", substitute_object_id(2012, target_col, uses_blend), 2012);

	// 3. Verify color math with godot-cpp Color
	Color line_color(1.0f, 1.0f, 1.0f, 1.0f);
	Color bg_color(40.0f / 255.0f, 125.0f / 255.0f, 1.0f, 1.0f);
	Color lbg = bg_color.lightened(0.2f);
	check_true("LBG is brighter than BG", lbg.get_v() >= bg_color.get_v());

	// 4. Verify multiplicative HSV shift logic
	Color col_base(1.0f, 0.5f, 0.5f, 1.0f);
	float shift_hue = 0.333f;
	float shift_sat = 0.8f;
	bool sat_mult = true;
	float res_sat = sat_mult ? col_base.get_s() * shift_sat : col_base.get_s() + shift_sat;
	check_true("Multiplicative HSV scales base saturation", res_sat > 0.0f);

	// Verify white base in multiplicative HSV does NOT gain saturation and turn red
	Color white_base(1.0f, 1.0f, 1.0f, 1.0f);
	float white_res_sat = sat_mult ? white_base.get_s() * shift_sat : white_base.get_s() + shift_sat;
	check_true("White base retains 0 saturation under multiplicative HSV", white_res_sat == 0.0f);
	Color white_shifted = Color::from_hsv(white_base.get_h() + shift_hue, white_res_sat, 1.0f, 1.0f);
	check_true("White base remains pure white and does not turn red", white_shifted == Color(1.0f, 1.0f, 1.0f, 1.0f));

	// 5. Verify initial spawn trigger activation semantics:
	// A trigger placed at x = 0 or x = 10 must fire when player spawns at x = 15.
	std::vector<double> trigger_positions = { -50.0, 0.0, 10.0, 15.0, 20.0, 100.0 };
	double player_spawn_x = 15.0;
	auto last = std::upper_bound(trigger_positions.begin(), trigger_positions.end(), player_spawn_x);
	int initial_fired = std::distance(trigger_positions.begin(), last);
	check_int("Triggers at x <= player_spawn_x (4 triggers) fire on spawn", initial_fired, 4);

	// 6. Verify HTML error response detection
	auto check_is_html_error = [](const std::string &response) -> bool {
		std::string str = response;
		while (!str.empty() && (str.front() == ' ' || str.front() == '\t' || str.front() == '\r' || str.front() == '\n')) str.erase(0, 1);
		while (!str.empty() && (str.back() == ' ' || str.back() == '\t' || str.back() == '\r' || str.back() == '\n')) str.pop_back();
		if (str.empty()) return false;
		std::string lower = str;
		for (char &c : lower) c = std::tolower(c);
		if (lower.rfind("<!doctype", 0) == 0 || lower.rfind("<html", 0) == 0 || lower.rfind("<head", 0) == 0) return true;
		if (lower.find("<html") != std::string::npos && (
				lower.find("522") != std::string::npos || lower.find("502") != std::string::npos ||
				lower.find("503") != std::string::npos || lower.find("500") != std::string::npos ||
				lower.find("404") != std::string::npos || lower.find("403") != std::string::npos ||
				lower.find("cloudflare") != std::string::npos || lower.find("error") != std::string::npos)) {
			return true;
		}
		return false;
	};

	check_true("Cloudflare 522 detected as HTML error", check_is_html_error("<!DOCTYPE html><html><head><title>522 Connection timed out</title></head></html>"));
	check_true("404 Not Found HTML detected", check_is_html_error("<html><head><title>404 Not Found</title></head><body>error</body></html>"));
	check_true("GDHistory shorthand payload is NOT HTML error", !check_is_html_error("k1 _123_ k2 ~~Test Level~~ k4 ~~H4sICCM47lsAA...~~"));
	check_true("Raw RobTop payload is NOT HTML error", !check_is_html_error("1:123:2:Test:4:H4sICCM47lsAA...#hash"));
	check_true("XML plist is NOT HTML error", !check_is_html_error("<?xml version=\"1.0\"?><plist><dict><k>k4</k><s>H4sI...</s></dict></plist>"));

	// 7. Verify level data string extraction logic
	auto extract_k4_test = [&](const std::string &payload) -> std::string {
		if (check_is_html_error(payload)) return "";
		std::string s = payload;
		// Shorthand k4 ~~...~~
		size_t pos = s.find("k4 ~~");
		if (pos == std::string::npos) pos = s.find("k4~~");
		if (pos != std::string::npos) {
			size_t start = s.find("~~", pos);
			if (start != std::string::npos) {
				start += 2;
				size_t finish = s.find("~~", start);
				if (finish != std::string::npos) {
					return s.substr(start, finish - start);
				}
			}
		}
		// Shorthand k4 _..._
		pos = s.find("k4 _");
		if (pos != std::string::npos) {
			size_t start = pos + 4;
			size_t finish = s.find("_", start);
			if (finish != std::string::npos) {
				return s.substr(start, finish - start);
			}
		}
		// RobTop colon separated :4: or 4:
		pos = s.find(":4:");
		if (pos != std::string::npos) {
			size_t val_start = pos + 3;
			size_t val_end = s.find(":", val_start);
			if (val_end == std::string::npos) val_end = s.find("#", val_start);
			if (val_end != std::string::npos) return s.substr(val_start, val_end - val_start);
			return s.substr(val_start);
		}
		// XML plist short
		pos = s.find("<k>k4</k>");
		if (pos != std::string::npos) {
			size_t s_start = s.find("<s>", pos);
			if (s_start != std::string::npos) {
				size_t s_end = s.find("</s>", s_start + 3);
				if (s_end != std::string::npos) return s.substr(s_start + 3, s_end - (s_start + 3));
			}
		}
		if (s.rfind("H4sI", 0) == 0) return s;
		return s;
	};

	check_true("Extract k4 from GDHistory tilde shorthand", extract_k4_test("k1 _123_ k2 ~~Test~~ k4 ~~H4sICCM47lsAA...~~ k3 ~~desc~~") == "H4sICCM47lsAA...");
	check_true("Extract k4 from GDHistory underscore shorthand", extract_k4_test("k1 _123_ k4 _H4sICCM47lsAA..._ k2 _Test_") == "H4sICCM47lsAA...");
	check_true("Extract k4 from RobTop colon pairs", extract_k4_test("1:123:2:Test:4:H4sICCM47lsAA...:10:500#hash") == "H4sICCM47lsAA...");
	check_true("Extract k4 from XML plist", extract_k4_test("<plist><dict><k>k4</k><s>H4sICCM47lsAA...</s></dict></plist>") == "H4sICCM47lsAA...");
	check_true("Extract k4 from raw base64 gzip", extract_k4_test("H4sICCM47lsAA...") == "H4sICCM47lsAA...");
	check_true("Extract k4 from HTML error returns empty", extract_k4_test("<!DOCTYPE html><html>error</html>") == "");

	// 8. Verify SFX ID extraction logic from level string
	auto extract_sfx_ids_test = [](const std::string &data) -> std::vector<int32_t> {
		std::vector<int32_t> sfx_ids;
		size_t chunk_start = 0;
		bool first_chunk = true;
		while (chunk_start < data.length()) {
			size_t chunk_end = data.find(';', chunk_start);
			if (chunk_end == std::string::npos) chunk_end = data.length();
			std::string chunk = data.substr(chunk_start, chunk_end - chunk_start);
			chunk_start = chunk_end + 1;
			if (chunk.empty()) continue;
			if (first_chunk) {
				first_chunk = false;
				if (chunk.rfind("kS", 0) == 0 || chunk.rfind("kA", 0) == 0) continue;
			}
			size_t idx = 0;
			while ((idx = chunk.find("392,", idx)) != std::string::npos) {
				if (idx == 0 || chunk[idx - 1] == ',') {
					size_t val_start = idx + 4;
					size_t val_end = chunk.find(',', val_start);
					if (val_end == std::string::npos) val_end = chunk.length();
					std::string val_str = chunk.substr(val_start, val_end - val_start);
					try {
						int32_t id = std::stoi(val_str);
						if (id > 0 && std::find(sfx_ids.begin(), sfx_ids.end(), id) == sfx_ids.end()) {
							sfx_ids.push_back(id);
						}
					} catch (...) {}
					idx = val_end;
				} else {
					idx += 4;
				}
			}
		}
		return sfx_ids;
	};

	std::string test_sfx_level = "kS38,1_0_2_0_3_0;1,3602,2,100,3,100,392,10000001,406,0.8;1,1,2,200,3,100;1,3602,2,300,3,100,392,10000002;1,3602,2,400,3,100,392,10000001;";
	std::vector<int32_t> extracted_sfx = extract_sfx_ids_test(test_sfx_level);
	check_int("Extracted 2 unique SFX IDs", extracted_sfx.size(), 2);
	if (extracted_sfx.size() == 2) {
		check_int("First SFX ID is 10000001", extracted_sfx[0], 10000001);
		check_int("Second SFX ID is 10000002", extracted_sfx[1], 10000002);
	}

	// Tests for resolve_proxy_url, is_cors_error, and is_audio_stream
	auto url_encode_simple = [](const std::string &value) -> std::string {
		std::string result;
		for (char c : value) {
			if (isalnum((unsigned char)c) || c == '-' || c == '_' || c == '.' || c == '~') {
				result += c;
			} else {
				char buf[4];
				snprintf(buf, sizeof(buf), "%%%02X", (unsigned char)c);
				result += buf;
			}
		}
		return result;
	};

	auto resolve_proxy_url_test = [&](const std::string &endpoint, const std::string &prefix) -> std::string {
		if (prefix.empty()) return endpoint;
		if (prefix.find("allorigins.win/raw?url=") != std::string::npos) {
			return "https://api.allorigins.win/raw?url=" + url_encode_simple(endpoint);
		}
		if (prefix.find("codetabs.com/v1/proxy?quest=") != std::string::npos) {
			return "https://api.codetabs.com/v1/proxy?quest=" + url_encode_simple(endpoint);
		}
		if (!prefix.empty() && (prefix.back() == '?' || prefix.back() == '=')) {
			return prefix + url_encode_simple(endpoint);
		}
		if (!prefix.empty() && prefix.back() == '/') {
			return prefix + endpoint;
		}
		return prefix + "/" + endpoint;
	};

	check_true("Resolve proxy: empty prefix leaves endpoint unchanged",
			resolve_proxy_url_test("https://example.com/api", "") == "https://example.com/api");
	check_true("Resolve proxy: allorigins raw URL encoding",
			resolve_proxy_url_test("https://history.geometrydash.eu/level/1/", "https://api.allorigins.win/raw?url=") ==
			"https://api.allorigins.win/raw?url=https%3A%2F%2Fhistory.geometrydash.eu%2Flevel%2F1%2F");
	check_true("Resolve proxy: codetabs quest URL encoding",
			resolve_proxy_url_test("https://history.geometrydash.eu/api/1/", "https://api.codetabs.com/v1/proxy?quest=") ==
			"https://api.codetabs.com/v1/proxy?quest=https%3A%2F%2Fhistory.geometrydash.eu%2Fapi%2F1%2F");
	check_true("Resolve proxy: trailing slash preserves raw endpoint",
			resolve_proxy_url_test("https://example.com/file.mp3", "https://proxy.example.com/") ==
			"https://proxy.example.com/https://example.com/file.mp3");

	auto is_cors_error_test = [](int64_t result, int64_t http_status, bool is_web) -> bool {
		if (!is_web) return false;
		return (result == 2 || result == 4) && http_status == 0;
	};

	check_true("CORS check: result 2 status 0 on Web is CORS error", is_cors_error_test(2, 0, true));
	check_true("CORS check: result 4 status 0 on Web is CORS error", is_cors_error_test(4, 0, true));
	check_true("CORS check: result 4 on Desktop is not CORS error", !is_cors_error_test(4, 0, false));
	check_true("CORS check: result 0 status 200 is not CORS error", !is_cors_error_test(0, 200, true));

	auto is_audio_stream_test = [](const std::vector<uint8_t> &bytes, const std::string &ext = "") -> bool {
		if (bytes.size() < 32) return false;
		const uint8_t *ptr = bytes.data();
		size_t head_len = std::min((size_t)128, bytes.size());
		static const struct { const char *text; size_t len; } text_prefixes[] = {
			{"<!doctype", 9}, {"<html", 5}, {"<?xml", 5}, {"{", 1}, {"error", 5},
		};
		for (const auto &prefix : text_prefixes) {
			if (head_len < prefix.len) continue;
			bool matched = true;
			for (size_t i = 0; i < prefix.len; ++i) {
				char c = (char)ptr[i];
				if (c >= 'A' && c <= 'Z') c += ('a' - 'A');
				if (c != prefix.text[i]) { matched = false; break; }
			}
			if (matched) return false;
		}
		if (ptr[0] == 0x66 && ptr[1] == 0x4c && ptr[2] == 0x61 && ptr[3] == 0x43) {
			return true; // "fLaC"
		}
		if (ext == "ogg" || (ptr[0] == 0x4f && ptr[1] == 0x67 && ptr[2] == 0x67 && ptr[3] == 0x53)) {
			return ptr[0] == 0x4f && ptr[1] == 0x67 && ptr[2] == 0x67 && ptr[3] == 0x53 && ptr[4] == 0x00;
		}
		if (ext == "wav" || (ptr[0] == 0x52 && ptr[1] == 0x49 && ptr[2] == 0x46 && ptr[3] == 0x46)) {
			return bytes.size() >= 12 && ptr[8] == 0x57 && ptr[9] == 0x41 && ptr[10] == 0x56 && ptr[11] == 0x45;
		}
		if (ptr[0] == 0x49 && ptr[1] == 0x44 && ptr[2] == 0x33) {
			if (bytes.size() < 10) return false;
			uint32_t tag_size = (uint32_t)(ptr[6] & 0x7f) << 21 | (uint32_t)(ptr[7] & 0x7f) << 14
					| (uint32_t)(ptr[8] & 0x7f) << 7 | (uint32_t)(ptr[9] & 0x7f);
			return tag_size >= 10 && (uint64_t)tag_size + 10 <= (uint64_t)bytes.size();
		}
		if (ptr[0] == 0xff && (ptr[1] & 0xe0) == 0xe0) {
			uint8_t version_bits = (ptr[1] >> 3) & 0x03;
			uint8_t layer_bits = (ptr[1] >> 1) & 0x03;
			return version_bits != 0x01 && layer_bits != 0x00;
		}
		return false;
	};

	std::vector<uint8_t> ogg_buf(64, 0);
	ogg_buf[0] = 0x4f; ogg_buf[1] = 0x67; ogg_buf[2] = 0x67; ogg_buf[3] = 0x53; // "OggS"
	check_true("Audio check: OGG header detected", is_audio_stream_test(ogg_buf));

	std::vector<uint8_t> ogg_bad_version(64, 0);
	ogg_bad_version[0] = 0x4f; ogg_bad_version[1] = 0x67; ogg_bad_version[2] = 0x67; ogg_bad_version[3] = 0x53;
	ogg_bad_version[4] = 0x01;
	check_true("Audio check: OGG with nonzero version rejected", !is_audio_stream_test(ogg_bad_version));

	std::vector<uint8_t> not_ogg(64, 0);
	check_true("Audio check: extension ogg without OggS magic rejected", !is_audio_stream_test(not_ogg, "ogg"));

	std::vector<uint8_t> mp3_buf(128, 0);
	mp3_buf[0] = 0x49; mp3_buf[1] = 0x44; mp3_buf[2] = 0x33; // "ID3"
	mp3_buf[9] = 0x40; // syncsafe tag size 64 -> 64 + 10 <= 128
	check_true("Audio check: MP3 ID3 header with sane tag size detected", is_audio_stream_test(mp3_buf));

	std::vector<uint8_t> mp3_bad_size(128, 0);
	mp3_bad_size[0] = 0x49; mp3_bad_size[1] = 0x44; mp3_bad_size[2] = 0x33;
	mp3_bad_size[6] = 0x7f; mp3_bad_size[7] = 0x7f; mp3_bad_size[8] = 0x7f; mp3_bad_size[9] = 0x7f;
	check_true("Audio check: ID3 with tag size beyond body rejected", !is_audio_stream_test(mp3_bad_size));

	std::vector<uint8_t> mp3_sync_buf(64, 0);
	mp3_sync_buf[0] = 0xff; mp3_sync_buf[1] = 0xfb; // MPEG sync frame, version 3, layer 2
	check_true("Audio check: MP3 frame sync detected", is_audio_stream_test(mp3_sync_buf));

	std::vector<uint8_t> mp3_reserved_layer(64, 0);
	mp3_reserved_layer[0] = 0xff; mp3_reserved_layer[1] = 0xe1; // layer bits 00 = reserved
	check_true("Audio check: MPEG sync with reserved layer rejected", !is_audio_stream_test(mp3_reserved_layer));

	std::vector<uint8_t> mp3_reserved_version(64, 0);
	mp3_reserved_version[0] = 0xff; mp3_reserved_version[1] = 0xed; // version bits 01 = reserved
	check_true("Audio check: MPEG sync with reserved version rejected", !is_audio_stream_test(mp3_reserved_version));

	std::vector<uint8_t> flac_buf(64, 0);
	flac_buf[0] = 0x66; flac_buf[1] = 0x4c; flac_buf[2] = 0x61; flac_buf[3] = 0x43; // "fLaC"
	check_true("Audio check: FLAC header detected", is_audio_stream_test(flac_buf));

	std::vector<uint8_t> wav_buf(64, 0);
	wav_buf[0] = 0x52; wav_buf[1] = 0x49; wav_buf[2] = 0x46; wav_buf[3] = 0x46; // "RIFF"
	wav_buf[8] = 0x57; wav_buf[9] = 0x41; wav_buf[10] = 0x56; wav_buf[11] = 0x45; // "WAVE"
	check_true("Audio check: RIFF/WAVE header detected", is_audio_stream_test(wav_buf));

	std::vector<uint8_t> riff_not_wave(64, 0);
	riff_not_wave[0] = 0x52; riff_not_wave[1] = 0x49; riff_not_wave[2] = 0x46; riff_not_wave[3] = 0x46;
	check_true("Audio check: RIFF without WAVE rejected", !is_audio_stream_test(riff_not_wave));

	std::string html_str = "<html><head><title>404 Not Found</title></head><body>404</body></html>";
	std::vector<uint8_t> html_buf(html_str.begin(), html_str.end());
	html_buf.resize(64, 0);
	check_true("Audio check: HTML error page rejected", !is_audio_stream_test(html_buf));

	std::vector<uint8_t> small_buf(16, 0);
	check_true("Audio check: Small buffer (<32 bytes) rejected", !is_audio_stream_test(small_buf));

	// The old check accepted any body >= 16 KiB; a large CDN error page must
	// now be rejected because it has no audio magic at all.
	std::vector<uint8_t> big_garbage(64 * 1024, 0x41); // 'A' fill: not a text prefix, not audio
	check_true("Audio check: large non-audio body rejected (no 16 KiB fallback)", !is_audio_stream_test(big_garbage));

	// Extents parity: the packed importer's in-loop extents mirror
	// gd_scan_level_extents. Model both scanners standalone and assert they
	// agree on the ordering rules: the first chunk is skipped
	// unconditionally, a chunk only counts when it carries a key-2 token,
	// duplicate keys resolve last-wins, and key-3 defaults to 0.
	auto scan_pairs = [](const std::string &chunk, std::unordered_map<std::string, std::string> &out) {
		bool expecting_key = true;
		std::string key;
		size_t start = 0;
		for (size_t cursor = 0; cursor <= chunk.size(); ++cursor) {
			if (cursor < chunk.size() && chunk[cursor] != ',') continue;
			std::string token = chunk.substr(start, cursor - start);
			start = cursor + 1;
			if (expecting_key) {
				// strip_edges() on the key, as parse_pairs_list does
				size_t b = token.find_first_not_of(" \t\r\n");
				size_t e = token.find_last_not_of(" \t\r\n");
				key = b == std::string::npos ? std::string() : token.substr(b, e - b + 1);
				expecting_key = false;
			} else {
				if (!key.empty()) out[key] = token; // last wins
				expecting_key = true;
			}
		}
	};
	auto gd_scan_extents = [&scan_pairs](const std::string &level) {
		double max_x = 0.0, max_y = 0.0;
		int64_t objects = 0;
		bool header = true;
		size_t start = 0;
		while (start <= level.size()) {
			size_t end = level.find(';', start);
			if (end == std::string::npos) end = level.size();
			std::string chunk = level.substr(start, end - start);
			start = end + 1;
			if (header) { header = false; continue; }
			if (chunk.empty()) continue;
			// token walk identical to gd_scan_level_extents
			bool have_x = false;
			double x = 0.0, y = 0.0;
			std::string key;
			size_t cursor = 0;
			bool is_key = true;
			while (cursor <= chunk.size()) {
				size_t comma = chunk.find(',', cursor);
				if (comma == std::string::npos) comma = chunk.size();
				std::string token = chunk.substr(cursor, comma - cursor);
				cursor = comma + 1;
				if (is_key) {
					key = token;
				} else if (key == "2" || key == "3") {
					double value = strtod(token.c_str(), nullptr);
					if (key == "2") { x = value; have_x = true; } else { y = value; }
				}
				is_key = !is_key;
			}
			if (!have_x) continue;
			if (objects == 0 || x > max_x) max_x = x;
			if (objects == 0 || y > max_y) max_y = y;
			++objects;
		}
		return std::pair<double, double>(max_x, max_y);
	};
	auto packed_extents = [&scan_pairs](const std::string &level) {
		double max_x = 0.0, max_y = 0.0;
		int64_t objects = 0;
		bool first_chunk = true;
		size_t start = 0;
		while (start <= level.size()) {
			size_t end = level.find(';', start);
			if (end == std::string::npos) end = level.size();
			std::string chunk = level.substr(start, end - start);
			start = end + 1;
			bool is_first = first_chunk;
			first_chunk = false;
			auto is_blank = [](const std::string &text) {
				return text.find_first_not_of(" \t\r\n") == std::string::npos;
			};
			if (is_blank(chunk)) continue;
			std::unordered_map<std::string, std::string> pairs;
			scan_pairs(chunk, pairs);
			if (is_first) continue;
			auto it = pairs.find("2");
			if (it == pairs.end()) continue;
			double x = strtod(it->second.c_str(), nullptr);
			if (objects == 0 || x > max_x) max_x = x;
			auto iy = pairs.find("3");
			double y = iy == pairs.end() ? 0.0 : strtod(iy->second.c_str(), nullptr);
			if (objects == 0 || y > max_y) max_y = y;
			++objects;
		}
		return std::pair<double, double>(max_x, max_y);
	};
	{
		auto a = gd_scan_extents("kS38,;1,1,2,10,3,20;2,2,3,50;1,1,2,900");
		auto b = packed_extents("kS38,;1,1,2,10,3,20;2,2,3,50;1,1,2,900");
		check_true("Extents parity: plain objects agree",
				a.first == b.first && a.second == b.second);
		check_true("Extents parity: max picked over objects", a.first == 900.0 && a.second == 50.0);
	}
	{
		// First chunk is an object (headerless level): both scanners skip it.
		auto a = gd_scan_extents("1,1,2,5000,3,6000;1,1,2,10,3,20");
		auto b = packed_extents("1,1,2,5000,3,6000;1,1,2,10,3,20");
		check_true("Extents parity: headerless level skips first chunk",
				a.first == b.first && a.second == b.second);
		check_true("Extents parity: headerless values come from later chunks",
				a.first == 10.0 && a.second == 20.0);
	}
	{
		// Empty first chunk: gd_scan flips its header flag on it, so the
		// header chunk itself is scanned (no key 2 -> not counted).
		auto a = gd_scan_extents(";kS38,;1,1,2,10,3,20");
		auto b = packed_extents(";kS38,;1,1,2,10,3,20");
		check_true("Extents parity: empty first chunk agrees",
				a.first == b.first && a.second == b.second);
	}
	{
		// Duplicate keys: last value wins in both.
		auto a = gd_scan_extents("kS38,;1,1,2,10,2,900,3,20,3,70");
		auto b = packed_extents("kS38,;1,1,2,10,2,900,3,20,3,70");
		check_true("Extents parity: duplicate keys last-wins agrees",
				a.first == b.first && a.second == b.second);
		check_true("Extents parity: duplicate max", a.first == 900.0 && a.second == 70.0);
	}
	{
		// Chunk without key 2 (y only) counts in neither.
		auto a = gd_scan_extents("kS38,;1,1,3,900;1,1,2,10,3,20");
		auto b = packed_extents("kS38,;1,1,3,900;1,1,2,10,3,20");
		check_true("Extents parity: key-2-less chunk ignored",
				a.first == b.first && a.second == b.second);
		check_true("Extents parity: y-only chunk does not set max_y", a.second == 20.0);
	}
	{
		// Negative coordinates: the first counted chunk sets both maxima
		// unconditionally, exactly like gd_scan.
		auto a = gd_scan_extents("kS38,;1,1,2,-500,3,-300;1,1,2,10,3,20");
		auto b = packed_extents("kS38,;1,1,2,-500,3,-300;1,1,2,10,3,20");
		check_true("Extents parity: negative first chunk agrees",
				a.first == b.first && a.second == b.second);
		check_true("Extents parity: negatives then positives", a.first == 10.0 && a.second == 20.0);
	}

	if (failures == 0) {
		std::printf("\nALL ONLINE PARSER STANDALONE TESTS PASSED (0 failures)\n");
		return 0;
	}
	std::printf("\nTESTS FAILED with %d failure(s)\n", failures);
	return 1;
}
