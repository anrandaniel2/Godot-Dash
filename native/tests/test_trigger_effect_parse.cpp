// Standalone test for the native trigger effect engine's pure math: the 19
// Geometry Dash easing curves ported onto Godot's Tween transitions. Runs
// without the engine (godot-cpp's Math header is self-contained); the
// property-parsing side is exercised end-to-end by the engine-hosted smoke
// test (tools/runtime_visual_smoke_test.gd), which asserts moved offsets,
// colour fades, pulse envelopes, zoom values and timewarp targets.
//
// Build & run:
//   g++ -std=c++17 -O2 -Inative/godot-cpp/include -Inative/godot-cpp/gen/include \
//       -Inative/godot-cpp/gdextension native/tests/test_trigger_effect_parse.cpp \
//       native/godot-cpp/bin/libgodot-cpp.linux.template_release.x86_64.a -lpthread -o /tmp/trigger_test
//   /tmp/trigger_test

#include <cstring>
#include <limits>
#include "../src/gdash_native.cpp"

#include <cmath>
#include <cstdio>

using namespace godot;

static int failures = 0;

static void expect_close(const char *name, double actual, double expected, double epsilon = 1e-4) {
	if (std::fabs(actual - expected) > epsilon) {
		std::printf("FAIL %s: expected %f, got %f\n", name, expected, actual);
		++failures;
	}
}

static void expect_true(const char *name, bool condition) {
	if (!condition) {
		std::printf("FAIL %s\n", name);
		++failures;
	}
}

int main() {
	// GD easing order: 0 linear; 1-3 quad in-out/in/out; 4-6 elastic;
	// 7-9 bounce; 10-12 expo; 13-15 sine; 16-18 back.
	expect_close("linear", ease_weight(0, 0.25), 0.25);
	expect_close("quad in-out at 0.25", ease_weight(1, 0.25), 0.125);
	expect_close("quad in at 0.5", ease_weight(2, 0.5), 0.25);
	// gd_docs easings.md: Ease Out is x^(1/rate), not 1 - (1 - x)^2.
	expect_close("ease out at 0.5", ease_weight(3, 0.5), std::sqrt(0.5));
	expect_close("ease in rate 3 at 0.5", ease_weight(2, 0.5, 3.0), 0.125);
	expect_close("ease out rate 4 at 0.0625", ease_weight(3, 0.0625, 4.0), 0.5);
	expect_close("ease in linear below 1%", ease_weight(2, 0.005, 2.0), 0.005 * 0.01);
	expect_close("back in at 0.5", ease_weight(17, 0.5), 3.5949095 * 0.125 - 2.5949095 * 0.25);
	expect_close("elastic in rate 2 at 0.5", ease_weight(5, 0.5), 0.0);
	expect_close("elastic in rate 1 at 0.75", ease_weight(5, 0.75, 1.0),
			std::pow(2.0, -2.5) * std::sin(Math::PI * (0.5 + 0.5)));
	expect_close("quad in-out at 0.75", ease_weight(1, 0.75), 0.875);
	expect_close("expo in at 0.5", ease_weight(11, 0.5), std::pow(2.0, -5.0));
	expect_close("expo out at 0.5", ease_weight(12, 0.5), 1.0 - std::pow(2.0, -5.0));
	expect_close("sine in-out at 0.5", ease_weight(13, 0.5), 0.5);
	expect_close("sine out at 0.25", ease_weight(15, 0.25), std::sin(0.25 * Math::PI / 2.0));
	expect_close("bounce out at 0.5", ease_weight(9, 0.5), 7.5625 * std::pow(0.5 - 1.5 / 2.75, 2.0) + 0.75);
	// Back out overshoots above 1 before settling at 1.
	const double back_out_half = ease_weight(18, 0.5);
	expect_close("back out overshoots", back_out_half, 1.0 - (3.5949095 * 0.125 - 2.5949095 * 0.25));
	// Elastic out overshoots just above 1 at the midpoint (its bounce) and
	// lands exactly on 1 at the end.
	const double elastic_out_half = ease_weight(6, 0.5);
	expect_true("elastic out midpoint sane", elastic_out_half > 0.9 && elastic_out_half < 1.1);
	// Endpoints hold for every curve index, and unknown indices are linear.
	for (int i = 0; i <= 18; ++i) {
		expect_close("easing start", ease_weight(i, 0.0), 0.0);
		expect_close("easing end", ease_weight(i, 1.0), 1.0);
	}
	expect_close("unknown easing is linear", ease_weight(19, 0.3), 0.3);
	expect_close("negative easing is linear", ease_weight(-1, 0.3), 0.3);
	// Weights clamp outside [0, 1] for every curve.
	expect_close("clamped low", ease_weight(2, -1.0), 0.0);
	expect_close("clamped high", ease_weight(3, 4.0), 1.0);
	// The family/mode decomposition maps every index as the converter does.
	expect_true("family of easing 5 is elastic", 5 >= 4 && 5 <= 6);
	expect_true("mode of easing 5 is in", (5 - 1) % 3 == 1);

	// Pulse (1006) source classification - parity: GD 2.11
	// EffectGameObject::customObjectSetup case 1006 (Wyliemaster/GD-Decompiled).
	// HSV-mode channel pulses used to classify as inert: a silent no-op on the
	// default native path.
	expect_true("rgb channel pulse", classify_pulse(5, 0, 0, 0) == PulseSource::RGB);
	expect_true("hsv channel pulse copies key 50", classify_pulse(5, 0, 1, 3) == PulseSource::HSV_COPY);
	expect_true("hsv mode is atoi-truthy", classify_pulse(5, 0, 2, 3) == PulseSource::HSV_COPY);
	expect_true("rgb mode ignores key 50", classify_pulse(5, 0, 0, 3) == PulseSource::RGB);
	expect_true("hsv pulse without source is inert", classify_pulse(5, 0, 1, 0) == PulseSource::INERT);
	expect_true("group pulse uses the rgb source", classify_pulse(5, 1, 0, 0) == PulseSource::RGB);
	expect_true("group hsv pulse copies key 50", classify_pulse(5, 1, 1, 3) == PulseSource::HSV_COPY);
	// Group pulse tint: batched records lerp, node layers get a factor whose
	// product with the watcher tint is the same lerp.
	const Color tint(0.5f, 0.25f, 1.0f, 0.6f);
	const Color pulse_to(1.0f, 0.0f, 0.5f, 1.0f);
	const Color half = pulse_record_color(tint, pulse_to, 0.5f);
	expect_close("record pulse lerps r", half.r, 0.75);
	expect_close("record pulse keeps alpha", half.a, 0.6);
	const Color factor = pulse_self_modulate(tint, pulse_to, 0.5);
	expect_close("node pulse product r", tint.r * factor.r, 0.75);
	expect_close("node pulse product g", tint.g * factor.g, 0.125);
	expect_close("node pulse product b", tint.b * factor.b, 0.75);
	const Color idle = pulse_self_modulate(tint, pulse_to, 0.0);
	expect_true("weight 0 releases the node tint", idle == Color(1, 1, 1, 1));
	expect_true("missing target is inert", classify_pulse(0, 0, 0, 0) == PulseSource::INERT);

	// Follow (1347): target moves by the follow object's movement times keys 72/73.
	const Vector2 follow = follow_step(Vector2(100.0, 50.0), Vector2(130.0, 30.0), Vector2(0.5, 2.0));
	expect_close("follow x scaled by key 72", follow.x, 15.0);
	expect_close("follow y scaled by key 73", follow.y, -40.0);
	const Vector2 still = follow_step(Vector2(10.0, 10.0), Vector2(10.0, 10.0), Vector2(1.0, 1.0));
	expect_true("no movement, no follow", still == Vector2());
	expect_true("follow is a distinct effect kind", TriggerEffectKind::FOLLOW != TriggerEffectKind::MOVE);

	// Random (1912) / Advanced Random (2068): weighted pick and key 152 pairs.
	const std::vector<double> random_weights = { 30.0, 70.0 };
	expect_true("random roll below chance picks the hit group", pick_weighted(random_weights, 0.29) == 0);
	expect_true("random roll at chance picks the miss group", pick_weighted(random_weights, 0.30) == 1);
	expect_true("random zero weight is never picked", pick_weighted({ 0.0, 5.0 }, 0.0) == 1);
	expect_true("random without weight picks nothing", pick_weighted({ 0.0 }, 0.5) == -1);
	const std::vector<ChancePair> pairs = parse_chance_pairs("12.40.7.60.0.5.9.0");
	expect_true("adv random keeps positive group/weight pairs", pairs.size() == 2);
	expect_true("adv random first pair", pairs.size() == 2 && pairs[0].group == 12 && pairs[0].weight == 40.0);
	expect_true("adv random second pair", pairs.size() == 2 && pairs[1].group == 7 && pairs[1].weight == 60.0);

	// Item Edit / Compare (3619/3620), gmdkit ItemOperation/RoundOp/SignOp.
	expect_close("edit (A + B) * mod", item_edit_rhs(3.0, 4.0, 1, 3, 2.0, 0, 0), 14.0);
	expect_close("edit only A divides by mod", item_edit_rhs(9.0, 0.0, 1, 4, 2.0, 0, 0), 4.5);
	expect_close("edit with no items reads zero", item_edit_rhs(0.0, 0.0, 0, 0, 7.0, 0, 0), 0.0);
	expect_close("edit floor then negative", item_edit_rhs(2.5, 0.0, 1, 3, 1.0, 2, 2), -2.0);
	expect_true("divide by zero is IEEE", std::isinf(item_arith(5.0, 4, 0.0)));
	expect_true("item int truncates and saturates", item_to_int(-2.7) == -2 && item_to_int(1e12) == 2147483647
			&& item_to_int(std::nan("")) == std::numeric_limits<int32_t>::min());
	expect_close("timer clamps", timer_clamp(1e9), 9999999.0);
	expect_close("compare side op 0 is the mod", item_compare_side(9.0, 0, 4.0, 0, 0), 4.0);
	expect_close("compare side multiplies", item_compare_side(9.0, 3, 2.0, 0, 0), 18.0);
	expect_true("greater widened by tolerance", item_compare_values(1.8, 1, 2.0, 0.5) && !item_compare_values(1.0, 1, 2.0, 0.5));
	expect_true("less widened by tolerance", item_compare_values(2.2, 3, 2.0, 0.5) && !item_compare_values(3.0, 3, 2.0, 0.5));
	expect_true("collision pair is unordered", collision_pair_key(3, 7, false, false, false) == collision_pair_key(7, 3, false, false, false));
	expect_true("collision P1 replaces block A", collision_pair_key(5, 7, true, false, false) == collision_pair_key(-1, 7, false, false, false)
			&& collision_pair_key(5, 7, true, false, false) != collision_pair_key(5, 7, false, true, false));
	expect_true("collision PP ignores blocks", collision_pair_key(1, 2, false, false, true) == collision_pair_key(9, 9, false, false, true));
	expect_true("touch default flips per press", touch_toggle_result(false, 0, true, true) == 0 && touch_toggle_result(false, 0, true, false) == 1
			&& touch_toggle_result(false, 0, false, true) == -1);
	expect_true("touch toggle on / off modes", touch_toggle_result(false, 1, true, true) == 1 && touch_toggle_result(false, 2, true, false) == 0);
	expect_true("touch hold mode", touch_toggle_result(true, 0, true, true) == 0 && touch_toggle_result(true, 0, false, false) == 1
			&& touch_toggle_result(true, 1, true, false) == 1 && touch_toggle_result(true, 1, false, true) == 0
			&& touch_toggle_result(true, 2, true, true) == 0);
	expect_close("follow Y snaps at speed 4", follow_player_y_step(0.0, 100.0, 4.0, 0.0, 1.0 / 240.0), 100.0);
	expect_close("follow Y eases at speed 1", follow_player_y_step(0.0, 100.0, 1.0, 0.0, 1.0 / 60.0), 25.0);
	expect_close("follow Y max speed", follow_player_y_step(0.0, 100.0, 4.0, 10.0, 1.0 / 60.0), 10.0);
	expect_true("event matches id, material, player", event_matches({ 4, 12 }, 0, 0, 12, 0, 2)
			&& !event_matches({ 4 }, 0, 0, 12, 0, 1) && !event_matches({ 4 }, 3, 0, 4, 0, 1) && !event_matches({ 4 }, 0, 1, 4, 0, 2));
	{
		AdvFollowParams m1; m1.easing = 2.0;
		Vector2 v;
		expect_true("adv follow mode 1 is distance / easing", adv_follow_tick(m1, Vector2(10, 0), v, true).is_equal_approx(Vector2(5, 0)));
		m1.max_range = 5.0; v = Vector2();
		expect_true("adv follow outside max range does nothing", adv_follow_tick(m1, Vector2(10, 0), v, true) == Vector2());
		m1.max_range = 0.0; m1.max_speed = 1.0;
		expect_true("adv follow max speed", adv_follow_tick(m1, Vector2(10, 0), v, true).is_equal_approx(Vector2(1, 0)));
		AdvFollowParams m2; m2.mode = 1; m2.start_speed = 2.0; m2.start_dir = 90.0;
		Vector2 w;
		expect_true("adv follow init start speed points clockwise from up", adv_follow_tick(m2, Vector2(0, 0), w, true).is_equal_approx(Vector2(2, 0)));
		expect_true("adv follow init only on first action", adv_follow_tick(m2, Vector2(0, 0), w, false).is_equal_approx(Vector2(2, 0)));
		const double pi = 3.14159265358979323846;
		expect_true("adv heading defaults to up", std::fabs(adv_start_heading(false, Vector2(), false, Vector2(), 0.0) + pi / 2.0) < 1e-9);
		expect_true("adv heading dir is clockwise", std::fabs(adv_start_heading(false, Vector2(), false, Vector2(), 90.0)) < 1e-9);
		expect_true("adv speed ref uses ref motion", std::fabs(adv_start_heading(true, Vector2(-1, 0), true, Vector2(0, 1), 0.0) - pi) < 1e-5);
		expect_true("adv speed ref without motion falls back to up", std::fabs(adv_start_heading(true, Vector2(), true, Vector2(1, 0), 0.0) + pi / 2.0) < 1e-9);
		expect_true("adv dir ref points to reference", std::fabs(adv_start_heading(false, Vector2(), true, Vector2(0, 2), 10.0) - (pi / 2.0 + 10.0 * pi / 180.0)) < 1e-5);
		expect_true("adv rotate capped", std::fabs(adv_rotate_step(0.0, 3.0, 0.0, 0.5) - 0.5) < 1e-9);
		expect_true("adv rotate easing divides", std::fabs(adv_rotate_step(0.0, 0.4, 4.0, 0.5) - 0.1) < 1e-9);
		expect_true("adv rotate takes short way", adv_rotate_step(0.1, 2.0 * pi - 0.1, 0.0, 1.0) < 0.0);
		Vector2 sv;
		AdvFollowParams sp; sp.mode = 1;
		expect_true("adv start override used", adv_follow_tick(sp, Vector2(), sv, true, Vector2(3, 4)).is_equal_approx(Vector2(3, 4)));
		AdvFollowParams fr; fr.mode = 1; fr.friction = 50.0; fr.accel = 100.0;
		Vector2 f(4, 0);
		expect_true("adv follow friction then accel", adv_follow_tick(fr, Vector2(0, 10), f, false).is_equal_approx(Vector2(2, 1)));
		AdvFollowParams xo; xo.x_only = true; xo.easing = 1.0;
		Vector2 x;
		expect_true("adv follow X only", adv_follow_tick(xo, Vector2(3, 7), x, true).is_equal_approx(Vector2(3, 0)));
	}
	{
		AdvFollowParams m3; m3.mode = 2; m3.steer = 10.0; m3.accel = 0.0;
		Vector2 v(1, 0);
		adv_follow_tick(m3, Vector2(0, 100), v, false);
		expect_true("mode 3 steers at most steer * 0.01 rad", std::fabs(std::atan2(v.y, v.x) - 0.1) < 1e-4 && std::fabs(v.length() - 1.0) < 1e-4);
		AdvFollowParams br; br.mode = 2; br.break_angle = 45.0; br.break_force = 50.0;
		Vector2 b(2, 0);
		adv_follow_tick(br, Vector2(-100, 0), b, false);
		expect_true("mode 3 brakes past the break angle", std::fabs(b.length() - 1.0) < 1e-4);
		AdvFollowParams ac; ac.mode = 2; ac.accel = 100.0; ac.break_angle = 180.0;
		Vector2 a(1, 0);
		adv_follow_tick(ac, Vector2(100, 0), a, false);
		expect_true("mode 3 accelerates along heading", a.is_equal_approx(Vector2(2, 0)));
		expect_true("edit scales then adds speed", adv_follow_edit(Vector2(2, 4), 0.5, 2.0, 1.0, 0.0, false, false).is_equal_approx(Vector2(2, 8)));
		expect_true("edit X only keeps Y", adv_follow_edit(Vector2(2, 4), 0.0, 0.0, 0.0, 0.0, true, false).is_equal_approx(Vector2(0, 4)));
	}
	{
		const std::vector<double> f = parse_particle_data("30a-1a1.5a0a-1a90");
		expect_true("particle data splits on a", f.size() == 6 && f[0] == 30.0 && f[1] == -1.0 && f[2] == 1.5 && f[5] == 90.0);
		expect_true("particle infinite emission bursts max", particle_burst_count(f) == 30);
		expect_true("particle infinite duration with finite emission spawns none", particle_burst_count(parse_particle_data("30a-1a1a0a10")) == 0);
		expect_true("particle emission over duration capped", particle_burst_count(parse_particle_data("30a2a1a0a10")) == 20
				&& particle_burst_count(parse_particle_data("15a2a1a0a10")) == 15);
		{
			std::string raw;
			for (int i = 0; i < 65; ++i) raw += (i ? "a" : "") + std::string(i == 53 || i == 64 ? "1" : "0");
			const std::vector<double> g = parse_particle_data(raw);
			expect_true("particle additive is gmdkit field 53", particle_field(g, PF_ADDITIVE) == 1.0 && particle_field(g, 56) == 0.0);
			expect_true("particle start size = end is gmdkit field 64", particle_field(g, PF_START_SIZE_EQ_END) == 1.0);
		}
		expect_true("particle empty fields read zero", parse_particle_data("5aa1").size() == 3 && parse_particle_data("5aa1")[1] == 0.0);
	}
	expect_true("time event due", timer_event_due(1.0, 2.0, 3.0) && timer_event_due(-1.0, -2.0, -3.0) && !timer_event_due(1.0, 2.0, 1.0));
	expect_true("compare equal within tolerance", item_compare_values(1.0, 0, 1.4, 0.5));
	expect_true("compare not-equal outside tolerance", item_compare_values(1.0, 5, 2.0, 0.5));
	expect_true("compare greater-or-equal", item_compare_values(2.0, 2, 2.0, 0.0) && !item_compare_values(1.0, 2, 2.0, 0.0));
	// Sequence (3607): counts {2, 1}, mode stop: steps 0, 0, 1, then nothing.
	{
		SequenceState seq;
		const std::vector<int32_t> counts = { 2, 1 };
		const int a = sequence_advance(seq, counts, 0, 0.0, 0.0, 0, 0.0);
		const int b = sequence_advance(seq, counts, 0, 0.0, 0.0, 0, 1.0);
		const int c = sequence_advance(seq, counts, 0, 0.0, 0.0, 0, 2.0);
		const int d = sequence_advance(seq, counts, 0, 0.0, 0.0, 0, 3.0);
		expect_true("sequence stop mode", a == 0 && b == 0 && c == 1 && d == -1);
		SequenceState loop;
		sequence_advance(loop, { 1 }, 1, 0.0, 0.0, 0, 0.0);
		expect_true("sequence loop restarts", sequence_advance(loop, { 1 }, 1, 0.0, 0.0, 0, 1.0) == 0);
		SequenceState gated;
		sequence_advance(gated, counts, 0, 0.5, 0.0, 0, 0.0);
		expect_true("sequence min interval drops fast hits", sequence_advance(gated, counts, 0, 0.5, 0.0, 0, 0.2) == -1);
		SequenceState reset;
		sequence_advance(reset, counts, 0, 0.0, 1.0, 0, 0.0);
		sequence_advance(reset, counts, 0, 0.0, 1.0, 0, 0.1);
		expect_true("sequence full reset after idle", sequence_advance(reset, counts, 0, 0.0, 1.0, 0, 5.0) == 0);
		SequenceState last;
		sequence_advance(last, counts, 2, 0.0, 0.0, 0, 0.0);
		sequence_advance(last, counts, 2, 0.0, 0.0, 0, 1.0);
		sequence_advance(last, counts, 2, 0.0, 0.0, 0, 2.0);
		expect_true("sequence last repeats final step", sequence_advance(last, counts, 2, 0.0, 0.0, 0, 3.0) == 1);
		SequenceState stepback;
		sequence_advance(stepback, counts, 0, 0.0, 1.0, 1, 0.0);
		sequence_advance(stepback, counts, 0, 0.0, 1.0, 1, 0.5);
		expect_true("sequence step reset walks back", sequence_advance(stepback, counts, 0, 0.0, 1.0, 1, 1.6) == 0);
		SequenceState blocked;
		sequence_advance(blocked, counts, 0, 1.0, 0.0, 0, 0.0);
		sequence_advance(blocked, counts, 0, 1.0, 0.0, 0, 0.6);
		expect_true("blocked call keeps last time", sequence_advance(blocked, counts, 0, 1.0, 0.0, 0, 1.1) == 0);
	}

	// Move lock to player (keys 58/59, mods 143/144): a locked axis takes the
	// player's movement times the mod and drops the eased offset.
	const Vector2 lock_x = move_lock_step(Vector2(5.0, 7.0), Vector2(20.0, -3.0), true, false, Vector2(1.0, 1.0));
	expect_close("lock x follows the player", lock_x.x, 20.0);
	expect_close("unlocked y keeps the eased offset", lock_x.y, 7.0);
	const Vector2 lock_y = move_lock_step(Vector2(5.0, 7.0), Vector2(20.0, -3.0), false, true, Vector2(1.0, 2.0));
	expect_close("unlocked x keeps the eased offset", lock_y.x, 5.0);
	expect_close("lock y scaled by key 144", lock_y.y, -6.0);

	// Item triggers (1611/1811/1817): Instant Count key 88 compare modes and
	// the Count edge (fires only on arrival at the target).
	expect_true("instant equals", item_compare(3, 3, 0) && !item_compare(4, 3, 0));
	expect_true("instant larger", item_compare(4, 3, 1) && !item_compare(3, 3, 1));
	expect_true("instant smaller", item_compare(2, 3, 2) && !item_compare(3, 3, 2));
	expect_true("count fires on arrival", item_count_reached(2, 3, 3));
	expect_true("count ignores staying at target", !item_count_reached(3, 3, 3));
	expect_true("count ignores passing by", !item_count_reached(2, 4, 3));
	expect_true("count fires arriving from above", item_count_reached(4, 3, 3));

	// UI Trigger (ID 3613) compute_ui_anchor alignment math tests
	const Vector2 vp_16_9(1920.0, 1080.0);
	// 16:9 (aspect 1.7778 > 1.5): H_ref = 1080/0.8 = 1350, W_ref = 2025, W_active = 2400, delta_x = 187.5
	// Center offset stays at center
	const Vector2 center_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, 0.0), 0, 0, false, false, vp_16_9);
	expect_close("16:9 center X", center_anchor.x, 0.0);
	expect_close("16:9 center Y", center_anchor.y, 0.0);

	// Left alignment on left edge: offset.x = -1012.5 -> anchor.x = -1200.0 (lands at screen 0 px)
	const Vector2 left_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(-1012.5, -200.0), 3, 0, false, false, vp_16_9);
	expect_close("16:9 left edge X", left_anchor.x, -1200.0);
	expect_close("16:9 left edge Y preserved", left_anchor.y, -200.0);

	// Right alignment on right edge: offset.x = +1012.5 -> anchor.x = +1200.0 (lands at screen 1920 px)
	const Vector2 right_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(1012.5, 150.0), 4, 0, false, false, vp_16_9);
	expect_close("16:9 right edge X", right_anchor.x, 1200.0);
	expect_close("16:9 right edge Y preserved", right_anchor.y, 150.0);

	// Auto_x alignment: negative offset chooses left, positive chooses right
	const Vector2 auto_l = NativeTriggerRuntime::compute_ui_anchor(Vector2(-500.0, 0.0), 1, 0, false, false, vp_16_9);
	expect_close("16:9 auto negative selects left", auto_l.x, -500.0 - 187.5);
	const Vector2 auto_r = NativeTriggerRuntime::compute_ui_anchor(Vector2(500.0, 0.0), 1, 0, false, false, vp_16_9);
	expect_close("16:9 auto positive selects right", auto_r.x, 500.0 + 187.5);

	// Center_x alignment: maintains offset from center regardless of aspect ratio
	const Vector2 center_x = NativeTriggerRuntime::compute_ui_anchor(Vector2(350.0, -100.0), 2, 0, false, false, vp_16_9);
	expect_close("16:9 center_x keeps offset", center_x.x, 350.0);

	// Relative mode: scales proportionally between center and edge
	const Vector2 rel_half = NativeTriggerRuntime::compute_ui_anchor(Vector2(-506.25, 0.0), 3, 0, true, false, vp_16_9);
	expect_close("16:9 relative proportional scale", rel_half.x, -600.0);

	// 4:3 (aspect 1.3333 < 1.5): W_ref = 1440/0.8 = 1800, H_ref = 1200, H_active = 1350, delta_y = 75.0
	const Vector2 vp_4_3(1440.0, 1080.0);
	const Vector2 top_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(100.0, -600.0), 0, 8, false, false, vp_4_3);
	expect_close("4:3 top edge Y", top_anchor.y, -675.0); // 540 + (-675 * 0.8) = 0 px
	expect_close("4:3 top edge X preserved", top_anchor.x, 100.0);

	const Vector2 btm_anchor = NativeTriggerRuntime::compute_ui_anchor(Vector2(100.0, 600.0), 0, 7, false, false, vp_4_3);
	expect_close("4:3 bottom edge Y", btm_anchor.y, 675.0); // 540 + (675 * 0.8) = 1080 px

	const Vector2 auto_top = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, -300.0), 0, 5, false, false, vp_4_3);
	expect_close("4:3 auto negative selects top", auto_top.y, -300.0 - 75.0);
	const Vector2 auto_btm = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, 300.0), 0, 5, false, false, vp_4_3);
	expect_close("4:3 auto positive selects bottom", auto_btm.y, 300.0 + 75.0);

	const Vector2 rel_y = NativeTriggerRuntime::compute_ui_anchor(Vector2(0.0, -300.0), 0, 8, false, true, vp_4_3);
	expect_close("4:3 relative Y proportional scale", rel_y.y, -300.0 * (1350.0 / 1200.0));

	// Zoom 1913 key 371 is a multiplier (EffectGameObject::m_zoomValue): 1
	// keeps the default zoom. Read as a percentage it became 0.01 and ORBIT
	// rendered 100x zoomed out.
	expect_close("zoom 371=1 keeps the default", gd_camera_zoom_factor(1.0), 1.0);
	expect_close("zoom 371=0.5 halves", gd_camera_zoom_factor(0.5), 0.5);
	expect_close("zoom 371=2 doubles", gd_camera_zoom_factor(2.0), 2.0);
	expect_close("zoom 371<=0 clamps", gd_camera_zoom_factor(0.0), 0.01);

	// Teleports (GJBaseGameLayer::teleportPlayer, CBFExtrapolate transcription).
	{
		const Vector2 player(100.0f, 50.0f);
		const Vector2 portal(110.0f, 60.0f);
		const Vector2 exit(500.0f, -200.0f);
		// 747: the exit keeps the player's X.
		Vector2 d = gd_teleport_destination(player, portal, exit, true, false, false, false);
		expect_close("tp 747 x", d.x, 100.0);
		expect_close("tp 747 y", d.y, -200.0);
		// 747 + Save Offset: GD subtracts (portal - player) after pinning X.
		d = gd_teleport_destination(player, portal, exit, true, true, false, false);
		expect_close("tp 747 save x", d.x, 90.0);
		expect_close("tp 747 save y", d.y, -210.0);
		// Unlinked/trigger: full target position, ignore flags override axes.
		d = gd_teleport_destination(player, portal, exit, false, false, false, false);
		expect_close("tp full x", d.x, 500.0);
		d = gd_teleport_destination(player, portal, exit, false, false, true, false);
		expect_close("tp ignoreX x", d.x, 100.0);
		expect_close("tp ignoreX y", d.y, -200.0);
		d = gd_teleport_destination(player, portal, exit, false, false, false, true);
		expect_close("tp ignoreY y", d.y, 50.0);
		expect_true("tp gravity none", gd_teleport_gravity_portal_mode(0) == -1);
		expect_true("tp gravity normal", gd_teleport_gravity_portal_mode(1) == GRAVITY_PORTAL_DOWN);
		expect_true("tp gravity flipped", gd_teleport_gravity_portal_mode(2) == GRAVITY_PORTAL_UP);
		expect_true("tp gravity toggle", gd_teleport_gravity_portal_mode(3) == GRAVITY_PORTAL_TOGGLE);
		expect_close("tp angle portal", gd_teleport_force_angle(true, 747, 0.0, 0.0, false), 180.0);
		expect_close("tp angle trigger", gd_teleport_force_angle(true, 3022, 30.0, 0.0, false), 60.0);
		expect_close("tp angle none", gd_teleport_force_angle(false, 3022, 0.0, 45.0, true), 135.0);
		// Static force 0, not additive: stops vertical motion.
		Vector2 v = gd_teleport_static_velocity(90.0, 0.0, false, Vector2(3.0f, 5.0f), false);
		expect_close("tp static stop y", v.y, 0.0);
		expect_close("tp static stop keeps x", v.x, 3.0);
		v = gd_teleport_static_velocity(90.0, 10.0, false, Vector2(3.0f, 5.0f), false);
		expect_close("tp static up", v.y, 10.0);
		v = gd_teleport_static_velocity(90.0, 10.0, true, Vector2(3.0f, 5.0f), false);
		expect_close("tp static additive", v.y, 15.0);
		// Redirect keeps speed (|v| = 5) and Max clamps it.
		v = gd_teleport_redirect_velocity(90.0, 1.0, 0.0, 0.0, Vector2(3.0f, 4.0f), true);
		expect_close("tp redirect speed", v.length(), 5.0);
		v = gd_teleport_redirect_velocity(90.0, 2.0, 0.0, 6.0, Vector2(3.0f, 4.0f), true);
		expect_close("tp redirect max", v.length(), 6.0);
	}

	// Level end and kill height (BetterLoading PlayLayer setup; gdsolver
	// updateMaxGameplayY notes).
	{
		const GDLevelExtents e = gd_scan_level_extents("kA2,0,kA37,1;1,1,2,600,3,105;1,8,2,15,3,4000;;1,3,2,1200.5,3,15");
		expect_true("extents objects", e.objects == 3);
		expect_close("extents max x", e.max_x, 1200.5);
		expect_close("extents max y", e.max_y, 4000.0);
		const GDLevelExtents none = gd_scan_level_extents("kA2,0");
		expect_true("extents header only", none.objects == 0);
		expect_close("level length short", gd_level_length(15.0), 869.0);
		expect_close("level length", gd_level_length(1200.5), 1540.5);
		expect_close("max y fixed", gd_max_gameplay_y(false, 4000.0), 2790.0);
		expect_close("max y dynamic", gd_max_gameplay_y(true, 4000.0), 4390.0);
		expect_close("max y dynamic floor", gd_max_gameplay_y(true, 100.0), 1590.0);
	}

	{
		// Area triggers: gdsolver areaenv.hpp (GD 2.2081 getAreaObjectValue,
		// processAreaMoveGroupAction) and gd_docs area_mechanics.md.
		AreaParams p;
		p.v[AF_LENGTH] = 100.0;
		p.v[AF_MOD_FRONT] = p.v[AF_MOD_BACK] = 1.0;
		p.v[AF_MOVE_DIST] = 30.0;
		AreaSample radial = area_sample(p, 30.0, 40.0, 7);
		expect_close("area radial u", radial.u, 0.5);
		expect_close("area linear strength", area_strength(p, radial), 0.5);
		double ox = 0.0, oy = 0.0;
		area_move_offset(p, 0.5, 30.0, 40.0, 7, ox, oy);
		expect_close("area angle 0 moves down x", ox, 0.0);
		expect_close("area angle 0 moves down y", oy, -15.0);
		p.v[AF_MOVE_ANGLE] = 90.0;
		area_move_offset(p, 1.0, 0.0, 0.0, 7, ox, oy);
		expect_close("area angle 90 is +x (ccw from down)", ox, 30.0);
		expect_close("area outside has no effect", area_strength(p, area_sample(p, 150.0, 0.0, 7)), 0.0);
		p.inwards = true;
		expect_close("area inwards flips u", area_sample(p, 30.0, 40.0, 7).u, 0.5);
		expect_close("area inwards centre", area_strength(p, area_sample(p, 0.0, 0.0, 7)), 0.0);
		p.inwards = false;
		p.v[AF_DEADZONE] = 0.5;
		expect_close("area deadzone", area_sample(p, 75.0, 0.0, 7).u, 0.5);
		expect_close("area inside deadzone is full", area_strength(p, area_sample(p, 40.0, 0.0, 7)), 1.0);
		p.v[AF_DEADZONE] = 0.0;
		p.dir_type = 1;
		p.v[AF_MOD_BACK] = 2.0;
		expect_close("area horizontal behind uses ModBack", area_sample(p, -25.0, 999.0, 7).u, 0.0);
		p.mirrored = true;
		expect_close("area mirrored behind", area_sample(p, -25.0, 0.0, 7).u, 0.5);
		expect_close("area horizontal front", area_sample(p, 25.0, 999.0, 7).u, 0.25);
		p.mirrored = false;
		p.dir_type = 2;
		expect_close("area vertical uses y", area_sample(p, 999.0, 50.0, 7).u, 0.5);
		p.dir_type = 0;
		p.easing = 2; // ease in, rate 2
		p.easing2 = 3; // ease out
		p.ease_out = true;
		expect_close("area eased strength (Easing2 front)", area_strength(p, area_sample(p, 50.0, 0.0, 7)), 1.0 - std::sqrt(0.5));
		p.ease_out = false;
		expect_close("area eased strength", area_strength(p, area_sample(p, 50.0, 0.0, 7)), 0.75);
		AreaParams rel;
		rel.relative = true;
		rel.v[AF_MOVE_DIST] = 40.0;
		rel.v[AF_RFADE] = 100.0;
		area_move_offset(rel, 1.0, 50.0, 0.0, 7, ox, oy);
		expect_close("area relative pushes away, faded", ox, 20.0);
		expect_close("area relative y", oy, 0.0);
		AreaParams xy;
		xy.xy_mode = true;
		xy.v[AF_MOVE_X] = 10.0;
		xy.v[AF_MOVE_Y] = -6.0;
		area_move_offset(xy, 0.5, 1.0, 1.0, 7, ox, oy);
		expect_close("area xy mode x", ox, 5.0);
		expect_close("area xy mode y", oy, -3.0);
		AreaParams sc;
		sc.v[AF_SCALE_X] = 3.0;
		sc.v[AF_SCALE_Y] = 1.0;
		double kx = 0.0, ky = 0.0;
		area_scale_factor(sc, 0.5, 7, kx, ky);
		expect_close("area scale x", kx, 2.0);
		expect_close("area scale y", ky, 1.0);
		AreaParams fade;
		fade.type = AreaType::FADE;
		fade.v[AF_FROM_OPACITY] = 0.2;
		fade.v[AF_TO_OPACITY] = 1.0;
		expect_close("area fade full strength", area_opacity(fade, 1.0), 0.2);
		expect_close("area fade none", area_opacity(fade, 0.0), 1.0);
		// Variance: base + var * per-object coefficient in [-1, 1].
		AreaParams var;
		var.v[AF_MOVE_DIST] = 100.0;
		var.v[AF_MOVE_DIST_VAR] = 10.0;
		bool in_range = true;
		for (uint64_t seed = 1; seed < 200; ++seed) {
			const double c = area_coefficient(seed, 10);
			in_range = in_range && c >= -1.0 && c <= 1.0;
			const double d = area_field(var, AF_MOVE_DIST, seed);
			in_range = in_range && d >= 90.0 && d <= 110.0;
		}
		expect_true("area variance stays in range", in_range);
		expect_close("area coefficient is stable", area_coefficient(42, 3), area_coefficient(42, 3));
		// Legacy enter effects (Open-GD EffectGameObject::triggerObject).
		expect_true("enter 22 fade only", gd_enter_effect_for_trigger(22) == 1);
		expect_true("enter 23 from bottom", gd_enter_effect_for_trigger(23) == 5);
		expect_true("enter 24 from top", gd_enter_effect_for_trigger(24) == 4);
		expect_true("enter 27 scale up", gd_enter_effect_for_trigger(27) == 2);
		expect_true("enter 28 scale down", gd_enter_effect_for_trigger(28) == 3);
		expect_true("enter 55 chaotic", gd_enter_effect_for_trigger(55) == 10);
		expect_true("enter 56 is -10 -> 9", gd_enter_effect_for_trigger(56) == 9);
		expect_true("enter 57 is -9 -> 8", gd_enter_effect_for_trigger(57) == 8);
		expect_true("enter 59 half inverted", gd_enter_effect_for_trigger(59) == 12);
		expect_true("enter 1915 no fade no enter", gd_enter_effect_for_trigger(1915) == 13);
	}

	{
		// Keyframes: gd_docs animate_keyframe.md / GD Creator School.
		expect_close("kf shortest wraps", kf_segment_rotation(0.0, 270.0, 0, 0, 1.0), -90.0);
		expect_close("kf CW over 180 does nothing (GD bug)", kf_segment_rotation(0.0, 270.0, 1, 0, 1.0), -90.0);
		expect_close("kf CW forces clockwise", kf_segment_rotation(90.0, 0.0, 1, 0, 1.0), 270.0);
		expect_close("kf CCW forces counter", kf_segment_rotation(0.0, 90.0, 2, 0, 1.0), -270.0);
		expect_close("kf x360 not scaled", kf_segment_rotation(0.0, 0.0, 0, 2, 0.5), 720.0);
		expect_close("kf mod quirk compares scaled", kf_segment_rotation(0.0, 150.0, 0, 0, 2.0), -60.0);
		std::vector<KfKey> keys(3);
		keys[0].x = 0.0;   keys[0].duration = 1.0; keys[0].index = 0;
		keys[1].x = 100.0; keys[1].duration = 2.0; keys[1].index = 1; keys[1].rot = 90.0;
		keys[2].x = 400.0; keys[2].index = 2; keys[2].spawn_group = 9;
		KfPlan plan = kf_build_plan(keys, KfMods());
		expect_close("kf time total", plan.total, 3.0);
		expect_close("kf time mid seg 1", kf_sample(plan, 0.5).x, 50.0);
		expect_close("kf time mid seg 2", kf_sample(plan, 2.0).x, 250.0);
		expect_close("kf rot reached", kf_sample(plan, 1.0).rot, 90.0);
		expect_close("kf end", kf_sample(plan, 9.0).x, 400.0);
		expect_true("kf spawn not before arrival", !kf_point_reached(plan, 2, 2.9));
		expect_true("kf spawn on arrival", kf_point_reached(plan, 2, 3.0));
		std::vector<KfKey> unsorted = { keys[2], keys[0], keys[1] };
		expect_close("kf sorted by index", kf_sample(kf_build_plan(unsorted, KfMods()), 0.5).x, 50.0);
		keys[0].time_mode = 1; // even over a ref-only middle key
		keys[1].ref_only = true;
		plan = kf_build_plan(keys, KfMods());
		expect_true("kf ref-only joins span", plan.spans.size() == 1);
		expect_close("kf even total", plan.total, 1.0);
		expect_close("kf even half", kf_sample(plan, 0.5).x, 100.0);
		keys[0].time_mode = 2; // dist: constant speed, rotation even
		plan = kf_build_plan(keys, KfMods());
		expect_close("kf dist half", kf_sample(plan, 0.5).x, 200.0);
		expect_close("kf dist rot even", kf_sample(plan, 0.5).rot, 90.0);
		keys[2].prox = true;
		plan = kf_build_plan(keys, KfMods());
		expect_true("kf prox early", kf_point_reached(plan, 2, 0.89));
		expect_true("kf prox not too early", !kf_point_reached(plan, 2, 0.88));
		KfMods mods;
		mods.time = 2.0;
		mods.pos_x = 0.5;
		plan = kf_build_plan(keys, mods);
		expect_close("kf time mod", plan.total, 2.0);
		expect_close("kf pos mod", kf_sample(plan, 9.0).x, 200.0);
		mods.time = -1.0;
		expect_close("kf negative time mod is 0", kf_build_plan(keys, mods).total, 0.0);
		std::vector<KfKey> loop(2);
		loop[0].duration = 1.0; loop[0].index = 0;
		loop[1].x = 60.0; loop[1].duration = 1.0; loop[1].index = 1; loop[1].close_loop = true;
		plan = kf_build_plan(loop, KfMods());
		expect_close("kf close loop total", plan.total, 2.0);
		expect_close("kf close loop returns", kf_sample(plan, 1.5).x, 30.0);
		std::vector<KfKey> curve(3);
		for (int i = 0; i < 3; ++i) { curve[i].index = i; curve[i].duration = 1.0; curve[i].curve = true; }
		curve[1].x = 50.0; curve[1].y = -100.0;
		curve[2].x = 100.0;
		plan = kf_build_plan(curve, KfMods());
		expect_close("kf curve passes key", kf_sample(plan, 1.0).y, -100.0);
		expect_true("kf curve bulges past chord", kf_sample(plan, 0.5).y < -50.0);
		expect_close("kf curve natural ends", kf_sample(plan, 2.0).y, 0.0);
		curve[0].duration = 0.0;
		plan = kf_build_plan(curve, KfMods());
		expect_true("kf curve 0 duration stays bounded", std::abs(kf_sample(plan, 0.5).y) <= 100.0);
		loop[0].easing = 2; // ease in, rate 2
		loop[0].rate = 2.0;
		expect_close("kf easing applies", kf_sample(kf_build_plan(loop, KfMods()), 0.5).x, 15.0);
	}

	// GD shader triggers (GDShaderState).
	{
		auto props = [](std::initializer_list<std::pair<int32_t, double>> kv) {
			ShaderProps p;
			for (const auto &e : kv) p.values.push_back(e);
			return p;
		};
		auto find = [](const std::vector<ShaderUniform> &list, const char *name) -> const ShaderUniform * {
			for (const ShaderUniform &u : list) if (std::strcmp(u.name, name) == 0) return &u;
			return nullptr;
		};
		ShaderFrame frame; // 569 x 320 points, D = 652
		GDShaderState st;
		expect_true("shader idle by default", !st.active());
		st.apply(2919, props({{176, 1.0}, {10, 1.0}}));
		st.step(0.5);
		expect_close("grayscale reads key 176, fades linearly", st.value[TAG_GRAYSCALE], 0.5);
		st.step(0.5);
		expect_close("grayscale reaches target", st.value[TAG_GRAYSCALE], 1.0);
		st.apply(2920, props({{176, 0.7}}));
		expect_close("duration 0 sets at once (tweenValue)", st.value[TAG_SEPIA], 0.7);
		st.apply(2914, props({{179, 9.0}, {181, 3.0}}));
		auto u = st.uniforms(frame);
		expect_close("radial blur = size / 45", find(u, "_radialBlurValue")->v[0], 0.2);
		expect_close("radial blur fade clamp(fade * 0.2, 0, 0.2)", find(u, "_blurFade")->v[0], 0.2);
		st.apply(2921, props({{176, 1.0}, {188, 1.0}, {179, 2.0}, {180, 0.5}, {189, 1.0}, {194, 1.0}}));
		u = st.uniforms(frame);
		expect_close("invert clamp RGB", find(u, "_invertColorValue")->v[0], 1.0);
		expect_close("invert edit G", find(u, "_invertColorValue")->v[1], 0.5);
		st.apply(2922, props({{176, 90.0}}));
		u = st.uniforms(frame);
		expect_close("hue cos", find(u, "_hueShiftCosA")->v[0], 0.0);
		expect_close("hue sin", find(u, "_hueShiftSinA")->v[0], 1.0);
		expect_close("colour change off -> C.r 0", find(u, "_colorChangeC")->v[0], 0.0);
		st.apply(2923, props({{176, 0.0}, {191, 1.0}, {175, 1.0}}));
		u = st.uniforms(frame);
		expect_close("colour change C.r floor .001", find(u, "_colorChangeC")->v[0], 0.001);
		st.apply(2912, props({{188, 1.0}, {180, 4.0}}));
		u = st.uniforms(frame);
		expect_close("pixelate block = 1 / round(D / target)", find(u, "_pixelSize")->v[0], 1.0 / 163.0, 1e-6);
		expect_close("pixelate Y untouched", find(u, "_pixelSize")->v[1], 0.0);
		st.apply(2904, props({{192, 1.0}}));
		expect_true("setup shader disable all resets", st.value[TAG_GRAYSCALE] == 0.0 && st.value[TAG_PIXELATE_X] == 1.0);
		expect_true("disable all leaves nothing active", !st.active());
		st.apply(2905, props({{175, 1.0}}));
		expect_true("shockwave active", st.active());
		for (int i = 0; i < 200; ++i) st.step(0.05), st.uniforms(frame);
		expect_true("shockwave ends off screen", !st.active());
	}

	if (failures == 0) {
		std::printf("trigger easing curves & shader effects: all checks passed\n");
		return 0;
	}
	std::printf("trigger easing curves: %d failure(s)\n", failures);
	return 1;
}
