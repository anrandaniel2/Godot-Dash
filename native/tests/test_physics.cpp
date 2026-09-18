#include <cmath>
#include <iostream>
#include <algorithm>

struct Vector2D {
	double x = 0.0;
	double y = 0.0;

	Vector2D() : x(0.0), y(0.0) {}
	Vector2D(double px, double py) : x(px), y(py) {}

	Vector2D rotated(double angle) const {
		double c = std::cos(angle);
		double s = std::sin(angle);
		return Vector2D(x * c - y * s, x * s + y * c);
	}
};

static constexpr double PLAYER_GRAVITY = 10600.0;
static constexpr double PLAYER_FLY_GRAVITY_MULTIPLIER = 0.5;
static constexpr double PLAYER_UFO_GRAVITY_MULTIPLIER = 0.7;
static constexpr double PLAYER_SPIDER_GRAVITY_MULTIPLIER = 0.65;
static constexpr double PLAYER_FLY_TERMINAL_VELOCITY_Y = 1800.0;
static constexpr double PLAYER_TERMINAL_VELOCITY_Y = 3000.0;
static constexpr double PLAYER_PLATFORMER_ACCELERATION = 5.0;

struct PlayerPhysicsState {
	double delta = 1.0 / 60.0;
	Vector2D previous_velocity;
	int64_t direction = 1;
	int64_t jump_state = 0;
	bool was_sliding_on_slope = false;
	bool has_last_slide_collision = false;
	double floor_angle = 0.0;
	double floor_max_angle = 0.785398;
	Vector2D slope_velocity;
	int64_t internal_gamemode = 0;
	int64_t player_scale = 1;
	Vector2D speed = Vector2D(1250.0, 2395.0);
	double speed_multiplier = 1.0;
	double gravity_flip = 1.0;
	double gravity_multiplier = 1.0;
	double gameplay_rotation = 0.0;
	bool is_on_floor = false;
	bool is_on_ceiling = false;
	bool is_platformer = false;
	bool colliding_pad = false;
	bool has_dash_control = false;
	bool orb_queue_empty = true;
	double robot_timer_time_left = 0.0;
	bool deferred_velocity_redirect = false;
	double coyote_time = 0.0;
	int64_t spider_dash_frames = 0;
	int64_t slope_exit_velocity_frames = 0;
};

struct PlayerPhysicsResult {
	Vector2D local_velocity;
	Vector2D velocity;
	Vector2D slope_velocity;
	double gravity_flip = 1.0;
	double coyote_time = 0.0;
	int64_t spider_dash_frames = 0;
	int64_t slope_exit_velocity_frames = 0;
	int64_t instant_jump_mode = -1;
};

static double move_toward_val(double from, double to, double delta) {
	if (std::abs(to - from) <= delta) return to;
	return from + std::copysign(delta, to - from);
}

static double clamp_val(double val, double min, double max) {
	if (val < min) return min;
	if (val > max) return max;
	return val;
}

PlayerPhysicsResult compute_player_velocity_core(const PlayerPhysicsState &state) {
	Vector2D local_velocity = state.previous_velocity.rotated(-state.gameplay_rotation);
	Vector2D slope_velocity = state.slope_velocity;
	double gravity_flip = state.gravity_flip;
	double coyote_time = state.coyote_time;
	int64_t spider_dash_frames = state.spider_dash_frames;
	int64_t slope_exit_velocity_frames = state.slope_exit_velocity_frames;

	if (spider_dash_frames > 0) {
		spider_dash_frames--;
	}
	if (slope_exit_velocity_frames > 0) {
		slope_exit_velocity_frames--;
	}

	// Slope physics
	if (state.was_sliding_on_slope && state.has_last_slide_collision) {
		if (std::abs(std::sin(state.floor_angle)) < std::sin(state.floor_max_angle)) {
			slope_velocity.y = std::tan(-state.floor_angle) * std::abs(local_velocity.x) * state.direction;
			slope_exit_velocity_frames = 4;
		}
	}

	// Ball or Swing gravity flip on jump press
	if ((state.internal_gamemode == 7 /*SWING*/ || state.internal_gamemode == 3 /*BALL*/) && state.jump_state == 1 && state.orb_queue_empty) {
		gravity_flip *= -1.0;
	}

	if (!state.has_dash_control) {
		if (state.internal_gamemode == 1 /*SHIP*/) {
			local_velocity.y += PLAYER_GRAVITY * state.delta * gravity_flip * state.gravity_multiplier * state.jump_state * -1.0 * PLAYER_FLY_GRAVITY_MULTIPLIER;
			local_velocity.y = clamp_val(local_velocity.y, -PLAYER_FLY_TERMINAL_VELOCITY_Y, PLAYER_FLY_TERMINAL_VELOCITY_Y);
		} else if (state.internal_gamemode == 7 /*SWING*/) {
			local_velocity.y += PLAYER_GRAVITY * state.delta * gravity_flip * state.gravity_multiplier * PLAYER_FLY_GRAVITY_MULTIPLIER;
			local_velocity.y = clamp_val(local_velocity.y, -PLAYER_FLY_TERMINAL_VELOCITY_Y, PLAYER_FLY_TERMINAL_VELOCITY_Y);
		} else if (state.internal_gamemode == 4 /*WAVE*/) {
			local_velocity.y = 1250.0 * gravity_flip * state.gravity_multiplier * state.jump_state * -1.0;
			if (state.speed_multiplier > 0.0) {
				local_velocity.y *= state.speed_multiplier;
			}
			if (state.player_scale == 0 /*MINI*/) {
				local_velocity.y *= 2.0;
			} else if (state.player_scale == 2 /*BIG*/) {
				local_velocity.y *= 0.5;
			}
		} else if (state.internal_gamemode == 6 /*SPIDER*/) {
			local_velocity.y += PLAYER_GRAVITY * state.delta * gravity_flip * state.gravity_multiplier * state.jump_state * -1.0 * PLAYER_SPIDER_GRAVITY_MULTIPLIER;
			local_velocity.y = clamp_val(local_velocity.y, -PLAYER_TERMINAL_VELOCITY_Y, PLAYER_TERMINAL_VELOCITY_Y);
		} else if (!state.is_on_floor) {
			if (state.internal_gamemode == 2 /*UFO*/) {
				local_velocity.y += PLAYER_GRAVITY * state.delta * gravity_flip * state.gravity_multiplier * PLAYER_UFO_GRAVITY_MULTIPLIER;
			} else {
				local_velocity.y += PLAYER_GRAVITY * state.delta * gravity_flip * state.gravity_multiplier;
			}
		}
	}

	bool flying_gamemode_slope_boost = (state.internal_gamemode == 1 || state.internal_gamemode == 7) &&
		((state.is_on_ceiling && state.jump_state >= 0) ||
		(state.is_on_floor && state.has_last_slide_collision && state.floor_angle != 0.0 && state.direction != 0 && state.jump_state == 1));
	bool isnt_jumping = state.is_on_floor && state.jump_state <= 0 && !state.deferred_velocity_redirect;

	if ((!state.colliding_pad && flying_gamemode_slope_boost) || isnt_jumping) {
		local_velocity.y = slope_velocity.y;
	}

	// Robot hold jump
	if (state.jump_state == 1 && state.robot_timer_time_left > 0.0 && state.internal_gamemode == 5 /*ROBOT*/) {
		local_velocity.y = 1250.0 * gravity_flip * -1.0;
	}

	int64_t instant_jump_mode = -1;
	bool is_instant_jump = (state.internal_gamemode == 6 || state.internal_gamemode == 3 || state.internal_gamemode == 2 || state.internal_gamemode == 0);
	if (is_instant_jump && state.jump_state == 1 && !state.colliding_pad && state.orb_queue_empty) {
		instant_jump_mode = state.internal_gamemode;
		if (state.internal_gamemode == 3 /*BALL*/) {
			local_velocity.y = state.speed.y * gravity_flip * 0.5;
		} else if (state.internal_gamemode == 2 /*UFO*/) {
			local_velocity.y = -state.speed.y * gravity_flip * PLAYER_UFO_GRAVITY_MULTIPLIER;
		} else if (state.internal_gamemode == 0 /*CUBE*/) {
			local_velocity.y = -state.speed.y * gravity_flip;
		}
	}

	// Horizontal velocity
	if (!state.is_platformer || state.internal_gamemode == 4 /*WAVE*/) {
		if (state.direction != 0) {
			local_velocity.x = state.direction * state.speed.x * state.speed_multiplier;
		} else {
			local_velocity.x = 0.0;
		}
	} else {
		double target_x = state.direction != 0 ? state.direction * state.speed.x * state.speed_multiplier : 0.0;
		local_velocity.x = move_toward_val(
			local_velocity.x, target_x,
			state.speed.x * state.delta * state.speed_multiplier * PLAYER_PLATFORMER_ACCELERATION);
	}

	// Coyote time
	bool is_falling = local_velocity.y * gravity_flip > 0.0;
	if (state.is_on_floor) {
		coyote_time = 2.0 / 60.0;
	} else {
		if (is_falling) {
			coyote_time = std::max(0.0, coyote_time - state.delta);
		} else {
			coyote_time = 0.0;
		}
	}

	// Reset slope velocity if needed
	if (!state.is_on_floor && slope_exit_velocity_frames == 0) {
		slope_velocity = Vector2D();
	}

	Vector2D world_velocity = local_velocity.rotated(state.gameplay_rotation);

	PlayerPhysicsResult result;
	result.local_velocity = local_velocity;
	result.velocity = world_velocity;
	result.slope_velocity = slope_velocity;
	result.gravity_flip = gravity_flip;
	result.coyote_time = coyote_time;
	result.spider_dash_frames = spider_dash_frames;
	result.slope_exit_velocity_frames = slope_exit_velocity_frames;
	result.instant_jump_mode = instant_jump_mode;
	return result;
}

struct CollisionFlags {
	bool is_floor = false;
	bool is_ceiling = false;
	bool is_wall = false;
	bool is_slope = false;
};

int64_t classify_collision_flags_core(double collision_angle, double floor_max_angle) {
	int64_t flags = 0;
	constexpr double PI = 3.14159265358979323846;
	if (collision_angle <= (10.0 * PI / 180.0)) {
		flags |= 1; // is_floor
	} else if (collision_angle >= (170.0 * PI / 180.0)) {
		flags |= 2; // is_ceiling
	} else if (collision_angle > floor_max_angle && collision_angle < (PI - floor_max_angle)) {
		flags |= 4; // is_wall
	} else {
		flags |= 8; // is_slope
	}
	return flags;
}

CollisionFlags classify_collision_core(double collision_angle, double floor_max_angle) {
	const int64_t flags = classify_collision_flags_core(collision_angle, floor_max_angle);
	CollisionFlags result;
	result.is_floor = (flags & 1) != 0;
	result.is_ceiling = (flags & 2) != 0;
	result.is_wall = (flags & 4) != 0;
	result.is_slope = (flags & 8) != 0;
	return result;
}

static int failures = 0;

void check_true(const char *name, bool cond) {
	if (cond) {
		std::cout << "PASS: " << name << std::endl;
	} else {
		std::cout << "FAIL: " << name << std::endl;
		failures++;
	}
}

int main() {
	std::cout << "--- Testing Player Physics Kernel in C++ ---" << std::endl;

	// 1. Cube falling with gravity
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(0, 0);
		p.direction = 1;
		p.jump_state = 0;
		p.internal_gamemode = 0; // CUBE
		p.is_on_floor = false;
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		double expected_y = PLAYER_GRAVITY * (1.0 / 60.0);
		check_true("Cube falls with gravity", std::abs(res.velocity.y - expected_y) < 1e-2);
		check_true("Cube horizontal velocity set", std::abs(res.velocity.x - 1250.0) < 1e-2);
	}

	// 2. Cube instant jump
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 0);
		p.direction = 1;
		p.jump_state = 1;
		p.internal_gamemode = 0; // CUBE
		p.is_on_floor = true;
		p.speed = Vector2D(1250, 2395);
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		check_true("Cube jump gives upward velocity (-2395)", std::abs(res.velocity.y - (-2395.0)) < 1e-2);
		check_true("Cube instant jump mode reported", res.instant_jump_mode == 0);
	}

	// 3. Ship flying up with jump_state = 1
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 0);
		p.direction = 1;
		p.jump_state = 1;
		p.internal_gamemode = 1; // SHIP
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		double expected_y = PLAYER_GRAVITY * (1.0 / 60.0) * 1.0 * 1.0 * 1.0 * -1.0 * PLAYER_FLY_GRAVITY_MULTIPLIER;
		check_true("Ship accelerates upward when holding jump", std::abs(res.velocity.y - expected_y) < 1e-2);
	}

	// 4. Wave constant vertical speed
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 0);
		p.direction = 1;
		p.jump_state = 1;
		p.internal_gamemode = 4; // WAVE
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		check_true("Wave rising at 45 deg (-1250)", std::abs(res.velocity.y - (-1250.0)) < 1e-2);
		check_true("Wave horizontal (1250)", std::abs(res.velocity.x - 1250.0) < 1e-2);

		p.jump_state = -1;
		res = compute_player_velocity_core(p);
		check_true("Wave falling at 45 deg (+1250)", std::abs(res.velocity.y - 1250.0) < 1e-2);
	}

	// 5. Ball gravity flip on jump
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 0);
		p.direction = 1;
		p.jump_state = 1;
		p.internal_gamemode = 3; // BALL
		p.gravity_flip = 1.0;
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		check_true("Ball flips gravity flip to -1", std::abs(res.gravity_flip - (-1.0)) < 1e-2);
	}

	// 6. Slope sliding velocity
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 0);
		p.direction = 1;
		p.jump_state = 0;
		p.was_sliding_on_slope = true;
		p.has_last_slide_collision = true;
		p.floor_angle = - (45.0 * 3.141592653589793 / 180.0); // 45 deg slope down
		p.floor_max_angle = 46.0 * 3.141592653589793 / 180.0;
		p.is_on_floor = true;
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		check_true("Slope velocity computed correctly", std::abs(res.slope_velocity.y - 1250.0) < 1.0);
	}

	// 7. Platformer move_toward acceleration
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(0, 0);
		p.direction = 1;
		p.is_platformer = true;
		p.internal_gamemode = 0;
		p.speed = Vector2D(1250, 2395);
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		check_true("Platformer accelerates smoothly", res.velocity.x > 50.0 && res.velocity.x < 200.0);
	}

	// 8. Collision classification
	{
		constexpr double PI = 3.14159265358979323846;
		CollisionFlags col_floor = classify_collision_core(5.0 * PI / 180.0, 45.0 * PI / 180.0);
		check_true("Angle 5 deg is floor", col_floor.is_floor);
		check_true("Angle 5 deg is not wall", !col_floor.is_wall);

		CollisionFlags col_wall = classify_collision_core(90.0 * PI / 180.0, 45.0 * PI / 180.0);
		check_true("Angle 90 deg is wall", col_wall.is_wall);
		check_true("Angle 90 deg is not floor", !col_wall.is_floor);

		CollisionFlags col_ceil = classify_collision_core(175.0 * PI / 180.0, 45.0 * PI / 180.0);
		check_true("Angle 175 deg is ceiling", col_ceil.is_ceiling);

		CollisionFlags col_slope = classify_collision_core(30.0 * PI / 180.0, 45.0 * PI / 180.0);
		check_true("Angle 30 deg is slope", col_slope.is_slope);

		int64_t flags_floor = classify_collision_flags_core(5.0 * PI / 180.0, 45.0 * PI / 180.0);
		check_true("Flags floor bit 0 set", (flags_floor & 1) != 0);
		check_true("Flags wall bit 2 not set for 5 deg", (flags_floor & 4) == 0);

		int64_t flags_wall = classify_collision_flags_core(90.0 * PI / 180.0, 45.0 * PI / 180.0);
		check_true("Flags wall bit 2 set", (flags_wall & 4) != 0);
	}

	// 9. Robot jumping and variable height
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 0);
		p.direction = 1;
		p.jump_state = 1;
		p.internal_gamemode = 5; // ROBOT
		p.robot_timer_time_left = 0.2;
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		check_true("Robot holding jump gives -1250 boost", std::abs(res.velocity.y - (-1250.0)) < 1e-2);
	}

	// 10. Mini and Big wave vertical speed scaling
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 0);
		p.direction = 1;
		p.jump_state = 1;
		p.internal_gamemode = 4; // WAVE
		p.player_scale = 0; // MINI
		PlayerPhysicsResult res_mini = compute_player_velocity_core(p);
		check_true("Mini wave has 2x vertical speed (-2500)", std::abs(res_mini.velocity.y - (-2500.0)) < 1e-2);

		p.player_scale = 2; // BIG
		PlayerPhysicsResult res_big = compute_player_velocity_core(p);
		check_true("Big wave has 0.5x vertical speed (-625)", std::abs(res_big.velocity.y - (-625.0)) < 1e-2);
	}

	// 11. UFO jump impulse
	{
		PlayerPhysicsState p;
		p.delta = 1.0 / 60.0;
		p.previous_velocity = Vector2D(1250, 500);
		p.direction = 1;
		p.jump_state = 1;
		p.internal_gamemode = 2; // UFO
		p.speed = Vector2D(1250, 2395);
		PlayerPhysicsResult res = compute_player_velocity_core(p);
		double expected_ufo_y = -2395.0 * PLAYER_UFO_GRAVITY_MULTIPLIER;
		check_true("UFO jump gives immediate upward impulse", std::abs(res.velocity.y - expected_ufo_y) < 1e-2);
		check_true("UFO instant jump mode reported", res.instant_jump_mode == 2);
	}

	if (failures == 0) {
		std::cout << "\nALL PHYSICS TESTS PASSED (0 failures)\n" << std::endl;
		return 0;
	} else {
		std::cout << "\nPHYSICS TESTS FAILED: " << failures << " failures\n" << std::endl;
		return 1;
	}
}
