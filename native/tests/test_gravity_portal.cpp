// Pure-math checks for gravity portals. No Godot required:
//   g++ -std=c++17 -O2 native/tests/test_gravity_portal.cpp -o /tmp/gravity_portal_test
//   /tmp/gravity_portal_test

#include "../src/gravity_portal.h"

#include <cstdio>
#include <cmath>

static int failures = 0;

static void expect_true(const char *name, bool condition) {
	if (!condition) {
		std::printf("FAIL %s\n", name);
		++failures;
	}
}

static void expect_close(const char *name, double actual, double expected) {
	if (std::fabs(actual - expected) > 1e-6) {
		std::printf("FAIL %s: expected %f, got %f\n", name, expected, actual);
		++failures;
	}
}

int main() {
	expect_true("blue id is down", gravity_portal_mode_from_id(10, -1) == GRAVITY_PORTAL_DOWN);
	expect_true("yellow id is up", gravity_portal_mode_from_id(11, -1) == GRAVITY_PORTAL_UP);
	expect_true("green id is toggle", gravity_portal_mode_from_id(2926, -1) == GRAVITY_PORTAL_TOGGLE);
	expect_true("explicit mode wins", gravity_portal_mode_from_id(11, GRAVITY_PORTAL_TOGGLE) == GRAVITY_PORTAL_TOGGLE);

	const GravityPortalResult already = compute_gravity_portal(1.0, 400.0, GRAVITY_PORTAL_DOWN);
	expect_true("blue portal is a no-op while already upright", !already.changed);
	expect_close("blue portal keeps speed", already.local_velocity_y, 400.0);

	const GravityPortalResult yellow = compute_gravity_portal(1.0, 900.0, GRAVITY_PORTAL_UP);
	expect_true("yellow portal flips", yellow.changed);
	expect_close("yellow portal gravity", yellow.gravity_flip, -1.0);
	expect_close("yellow portal halves fall speed, keeps direction", yellow.local_velocity_y, 450.0);

	const GravityPortalResult grounded = compute_gravity_portal(1.0, 0.0, GRAVITY_PORTAL_UP);
	expect_true("grounded yellow portal flips", grounded.changed);
	expect_close("grounded launch follows the new fall", grounded.local_velocity_y, -180.0);

	const GravityPortalResult toggled = compute_gravity_portal(-1.0, -500.0, GRAVITY_PORTAL_TOGGLE);
	expect_true("green portal toggles back to down", toggled.changed);
	expect_close("green portal gravity", toggled.gravity_flip, 1.0);
	expect_close("green portal halves speed, keeps direction", toggled.local_velocity_y, -250.0);

	const GravityPortalResult capped = compute_gravity_portal(1.0, -8000.0, GRAVITY_PORTAL_UP);
	expect_close("kept speed is terminal-clamped", capped.local_velocity_y, -3000.0);

	const GravityPortalResult slow = compute_gravity_portal(1.0, 100.0, GRAVITY_PORTAL_UP);
	expect_close("slow speed gets the nudge into the new fall", slow.local_velocity_y, -180.0);

	if (failures != 0) {
		std::printf("%d failure(s)\n", failures);
		return 1;
	}
	std::printf("gravity portal math ok\n");
	return 0;
}
