// Pure-math checks for composite decoration spin (sawblades built from quarters).
// No Godot required:
//   g++ -std=c++17 -O2 native/tests/test_decoration_spin.cpp -o /tmp/decoration_spin_test
//   /tmp/decoration_spin_test
//
// Guard: before the fix the runtime used rotated_local (spin_local_space_legacy
// below). For a mirrored quarter that turns the sprite -30 degrees while its
// orbit goes +30, so the first mirrored check fails on that formula.

#include "../src/decoration_spin.h"

#include <cstdio>
#include <cmath>
#include <string>

static int failures = 0;
static const double PI = 3.14159265358979323846;

static void expect_close(const char *name, double actual, double expected, double tolerance = 1e-9) {
	if (std::fabs(actual - expected) > tolerance) {
		std::printf("FAIL %s: expected %.9f, got %.9f\n", name, expected, actual);
		++failures;
	}
}

// Angle of the sprite's x axis, in degrees, as Godot's Transform2D reads it.
static double axis_angle_deg(const SpinTransform2D &t) {
	return std::atan2(t.xy, t.xx) * 180.0 / PI;
}

static double wrap_deg(double degrees) {
	while (degrees < 0.0) degrees += 360.0;
	while (degrees >= 360.0) degrees -= 360.0;
	return degrees;
}

static void test_normal_quarter_turns_with_orbit() {
	SpinTransform2D quarter; // unmirrored, origin 10 px right of the pivot
	quarter.ox = 10.0;
	const double angle = 30.0 * PI / 180.0;
	SpinTransform2D spun = spin_about_pivot(quarter, 0.0, 0.0, angle);
	expect_close("normal quarter turns +30", wrap_deg(axis_angle_deg(spun) - axis_angle_deg(quarter)), 30.0, 1e-7);
	expect_close("normal quarter origin orbits +30", std::atan2(spun.oy, spun.ox) * 180.0 / PI, 30.0, 1e-7);
}

static void test_mirrored_quarter_turns_with_orbit() {
	SpinTransform2D mirrored; // sx = -1: negative determinant
	mirrored.xx = -1.0;
	mirrored.yy = 1.0;
	mirrored.ox = 10.0;
	const double angle = 30.0 * PI / 180.0;

	SpinTransform2D fixed = spin_about_pivot(mirrored, 0.0, 0.0, angle);
	expect_close("mirrored quarter turns +30 (fixed)", wrap_deg(axis_angle_deg(fixed) - axis_angle_deg(mirrored)), 30.0, 1e-7);
	expect_close("mirrored quarter origin orbits +30", std::atan2(fixed.oy, fixed.ox) * 180.0 / PI, 30.0, 1e-7);
	// A rigid rotation keeps the determinant sign: still mirrored after the spin.
	expect_close("mirrored quarter determinant kept", fixed.xx * fixed.yy - fixed.xy * fixed.yx, -1.0, 1e-9);

	// The old local-space update reversed the sprite relative to its orbit.
	SpinTransform2D legacy = spin_local_space_legacy(mirrored, 0.0, 0.0, angle);
	expect_close("legacy local-space spin turns mirrored sprite -30 (the bug)", wrap_deg(axis_angle_deg(legacy) - axis_angle_deg(mirrored)), 330.0, 1e-7);
}

// A sawblade of four quarters around one pivot: two mirrored, two not, with the
// trim offset of each quarter's own sprite origin off the saw centre.
static void test_composite_quarters_stay_rigid() {
	const double px = 200.0;
	const double py = -80.0;
	SpinTransform2D parts[4];
	parts[0] = SpinTransform2D{ 1.0, 0.0, 0.0, 1.0, px + 24.0, py + 6.0 };
	parts[1] = SpinTransform2D{ -1.0, 0.0, 0.0, 1.0, px - 18.0, py + 20.0 };
	parts[2] = SpinTransform2D{ 1.0, 0.0, 0.0, -1.0, px + 5.0, py - 30.0 };
	parts[3] = SpinTransform2D{ -1.0, 0.0, 0.0, -1.0, px - 12.0, py - 9.0 };

	const double angle_deg = 37.0;
	const double angle = angle_deg * PI / 180.0;
	const char *names[4] = { "quarter 0", "quarter 1 (mirrored)", "quarter 2 (flipped)", "quarter 3 (mirrored+flipped)" };
	for (int i = 0; i < 4; ++i) {
		SpinTransform2D after = spin_about_pivot(parts[i], px, py, angle);
		expect_close((std::string(names[i]) + " turns with the saw").c_str(),
				wrap_deg(axis_angle_deg(after) - axis_angle_deg(parts[i])), angle_deg, 1e-7);
		// Its origin keeps its distance from the saw centre.
		const double before_radius = std::hypot(parts[i].ox - px, parts[i].oy - py);
		const double after_radius = std::hypot(after.ox - px, after.oy - py);
		expect_close((std::string(names[i]) + " keeps radius").c_str(), after_radius, before_radius, 1e-9);
		// The axes stay unit length (no scale drift from repeated spins).
		expect_close((std::string(names[i]) + " unit x axis").c_str(), std::hypot(after.xx, after.xy), 1.0, 1e-9);
	}
}

static void test_steps_accumulate_to_one_turn() {
	// advance_animation is called once per frame with delta; many small steps must
	// give the same pose as one step.
	SpinTransform2D mirrored{ -1.0, 0.0, 0.0, 1.0, 40.0, 0.0 };
	SpinTransform2D stepped = mirrored;
	const int steps = 200;
	const double total = 90.0 * PI / 180.0;
	for (int i = 0; i < steps; ++i) stepped = spin_about_pivot(stepped, 0.0, 0.0, total / steps);
	SpinTransform2D once = spin_about_pivot(mirrored, 0.0, 0.0, total);
	expect_close("stepped spin equals one spin (x)", stepped.ox, once.ox, 1e-7);
	expect_close("stepped spin equals one spin (y)", stepped.oy, once.oy, 1e-7);
	expect_close("stepped spin equals one spin (axis)", axis_angle_deg(stepped), axis_angle_deg(once), 1e-6);
}

int main() {
	test_normal_quarter_turns_with_orbit();
	test_mirrored_quarter_turns_with_orbit();
	test_composite_quarters_stay_rigid();
	test_steps_accumulate_to_one_turn();
	if (failures == 0) {
		std::printf("decoration spin: all checks passed\n");
		return 0;
	}
	std::printf("decoration spin: %d failure(s)\n", failures);
	return 1;
}
