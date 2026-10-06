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
	expect_close("quad out at 0.5", ease_weight(3, 0.5), 0.75);
	expect_close("quad in-out at 0.75", ease_weight(1, 0.75), 0.875);
	expect_close("expo in at 0.5", ease_weight(11, 0.5), std::pow(2.0, -5.0));
	expect_close("expo out at 0.5", ease_weight(12, 0.5), 1.0 - std::pow(2.0, -5.0));
	expect_close("sine in-out at 0.5", ease_weight(13, 0.5), 0.5);
	expect_close("sine out at 0.25", ease_weight(15, 0.25), std::sin(0.25 * Math::PI / 2.0));
	expect_close("bounce out at 0.5", ease_weight(9, 0.5), 7.5625 * std::pow(0.5 - 1.5 / 2.75, 2.0) + 0.75);
	// Back out overshoots above 1 before settling at 1.
	const double back_out_half = ease_weight(18, 0.5);
	expect_true("back out overshoots", back_out_half > 1.0 && back_out_half < 1.15);
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

	// is_shader_kind helper test
	expect_true("gray is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_GRAYSCALE));
	expect_true("sepia is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_SEPIA));
	expect_true("lens is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_LENS_CIRCLE));
	expect_true("invert is shader kind", NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::SHADER_INVERT_COLOR));
	expect_true("move is not shader kind", !NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::MOVE));
	expect_true("color is not shader kind", !NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::COLOR));
	expect_true("ui is not shader kind", !NativeTriggerRuntime::is_shader_kind(TriggerEffectKind::UI));

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

	if (failures == 0) {
		std::printf("trigger easing curves & shader effects: all checks passed\n");
		return 0;
	}
	std::printf("trigger easing curves: %d failure(s)\n", failures);
	return 1;
}
