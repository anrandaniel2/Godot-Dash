#pragma once

// NativeSpriteTick: C++ twin of Player._update_sprites_rotation, the largest
// remaining per-physics-tick GDScript function (240 Hz per player, ~60
// statements and ~20 node writes). The math below mirrors the GDScript
// implementation statement for statement — including its double conversions
// (rotation_degrees round-trips, lerpf/lerp_angle/snapped semantics) — so
// the native path and the GDScript fallback are visually interchangeable.
//
// The player still computes the tick's inputs (replay-aware input, floor
// angle history, dash velocity angle) and packs them into a PackedFloat64Array
// exactly like the existing compute_player_velocity_packed seam; everything
// this class does is write node transforms directly. Absence of this class
// changes nothing: Player keeps the GDScript path.

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/transform2d.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cmath>

namespace godot {

class NativeSpriteTick : public RefCounted {
	GDCLASS(NativeSpriteTick, RefCounted)

	// Player.Gamemode order (CUBE..SWING); keep in sync with src/Player.gd.
	enum Gamemode {
		GAMEMODE_CUBE = 0,
		GAMEMODE_SHIP = 1,
		GAMEMODE_UFO = 2,
		GAMEMODE_BALL = 3,
		GAMEMODE_WAVE = 4,
		GAMEMODE_ROBOT = 5,
		GAMEMODE_SPIDER = 6,
		GAMEMODE_SWING = 7,
	};

	// Visual state owned by this object while active (Player keeps its own
	// copies for the GDScript fallback; only one path ever runs). The shared
	// fire clock (_fire_sprite_time) stays in the player: the swing/robot
	// fire sprite animations still read it from GDScript, so the player
	// increments it itself.
	double sprite_floor_angle = 0.0;
	double wave_rotation_goal = 0.0;
	double ball_grounded_look_factor = 0.0;

	// Cached scene nodes, resolved once at bind time.
	Node2D *icon = nullptr;
	Node2D *corner_snapping = nullptr;
	Node2D *ground_particles_origin = nullptr;
	Node2D *icon_cube = nullptr;
	Node2D *icon_ship = nullptr;
	Node2D *icon_swing = nullptr;
	Node2D *icon_wave = nullptr;
	Node2D *icon_ufo = nullptr;
	Node2D *icon_jetpack = nullptr;
	Node2D *icon_ball = nullptr;
	Node2D *icon_spider = nullptr;
	Node2D *icon_robot = nullptr;
	Node2D *dash_flame = nullptr;
	// GPUParticles2D is outside the trimmed build profile: these are used
	// through generic Object property sets instead of typed accessors.
	Node2D *ship_particles = nullptr;
	Node2D *jetpack_particles = nullptr;
	Node2D *dash_particles = nullptr;
	Object *dash_material = nullptr;
	// Swing (FireBoostTop/Middle/Bottom) and robot (foot Fire) flame sprites
	// and their particle emitters, driven by tick_swing_fire/tick_robot_fire.
	Node2D *swing_fire[3] = { nullptr, nullptr, nullptr };
	Node2D *swing_fire_particles[3] = { nullptr, nullptr, nullptr };
	Node2D *robot_fire[2] = { nullptr, nullptr };
	Node2D *robot_fire_particles[2] = { nullptr, nullptr };

	// Godot 4 semantics of the GDScript built-ins used by the twin.
	static inline double lerpf(double p_from, double p_to, double p_weight) {
		return p_from + (p_to - p_from) * p_weight;
	}

	// Godot 4 remap: lerpf(ostart, ostop, inverse_lerp(istart, istop, value)),
	// unclamped. The fire animations remap sin() from [-1, 1] onto the
	// flame-scale band.
	static inline double remap_01(double p_value, double p_ostart, double p_ostop) {
		return lerpf(p_ostart, p_ostop, (p_value + 1.0) / 2.0);
	}

	static inline double lerp_angle(double p_from, double p_to, double p_weight) {
		const double tau = 2.0 * Math::PI;
		double difference = std::fmod(p_to - p_from, tau);
		difference = std::fmod(2.0 * difference, tau) - difference;
		return p_from + difference * p_weight;
	}

	static inline double snapped(double p_value, double p_step) {
		return p_step != 0.0 ? Math::floor(p_value / p_step + 0.5) * p_step : p_value;
	}

	// Math.polar_polygon_normalized (src/static/Math.gd), sides = 5 and
	// curvature = 2.0 inlined for the ball's resting pose.
	static inline double polar_polygon_normalized5(double p_angle) {
		constexpr double SIDES = 5.0;
		constexpr double CURVATURE = 2.0;
		const auto sec = [](double angle) { return 1.0 / std::cos(angle); };
		const auto polar_polygon = [&](double angle) {
			return sec(Math::PI * (Math::fposmod((SIDES * angle) / (2.0 * Math::PI), 1.0) - 0.5)
					* CURVATURE / (SIDES / 2.0));
		};
		return polar_polygon(p_angle) / polar_polygon(0.0);
	}

	// Transform2D.IDENTITY.rotated(-sfa).scaled(Vector2(dir, 1)).rotated(sfa)
	// with a zero origin throughout, i.e. the 2x2 basis product
	// R(sfa) * S(dir, 1) * R(-sfa).
	static Transform2D flip_transform(double sfa, double dir) {
		const double cos_m = std::cos(-sfa);
		const double sin_m = std::sin(-sfa);
		const double cos_p = std::cos(sfa);
		const double sin_p = std::sin(sfa);
		const Vector2 c0(cos_m * (real_t)dir, sin_m * (real_t)dir);
		const Vector2 c1(-sin_m, cos_m);
		const Vector2 r0(cos_p * c0.x - sin_p * c0.y, sin_p * c0.x + cos_p * c0.y);
		const Vector2 r1(cos_p * c1.x - sin_p * c1.y, sin_p * c1.x + cos_p * c1.y);
		return Transform2D(r0, r1, Vector2());
	}

	// rotation_degrees += amount, with the same rad->deg->rad double
	// conversion the GDScript property performs.
	static void add_rotation_degrees(Node2D *node, double p_degrees) {
		if (!node) return;
		node->set_rotation(Math::deg_to_rad(Math::rad_to_deg(node->get_rotation()) + p_degrees));
	}

	static void set_rotation_degrees(Node2D *node, double p_degrees) {
		if (!node) return;
		node->set_rotation(Math::deg_to_rad(p_degrees));
	}

	static void set_scale_y(Node2D *node, double p_y) {
		if (!node) return;
		Vector2 scale = node->get_scale();
		scale.y = (real_t)p_y;
		node->set_scale(scale);
	}

	static void set_scale_x(Node2D *node, double p_x) {
		if (!node) return;
		Vector2 scale = node->get_scale();
		scale.x = (real_t)p_x;
		node->set_scale(scale);
	}

	static void set_particles_emitting(Node2D *particles, bool p_visible, bool p_emitting) {
		if (!particles) return;
		// GDScript: emitting = visible and jump_state > 0.
		particles->set("emitting", Variant(p_visible && p_emitting));
		particles->set("interp_to_end", Variant(p_visible ? 0.0 : 1.0));
	}

	static void set_particles_raw(Node2D *particles, bool p_emitting, double p_interp_to_end) {
		// Raw emitting/interp writes used by the fire twins, which set the
		// two fields separately instead of deriving them from visibility.
		if (!particles) return;
		particles->set("emitting", Variant(p_emitting));
		particles->set("interp_to_end", Variant(p_interp_to_end));
	}

	static void set_particles_emitting_flag(Node2D *particles, bool p_emitting) {
		if (!particles) return;
		particles->set("emitting", Variant(p_emitting));
	}

	static void set_particles_interp(Node2D *particles, double p_interp_to_end) {
		if (!particles) return;
		particles->set("interp_to_end", Variant(p_interp_to_end));
	}

	static void set_position_y(Node2D *node, double p_y) {
		if (!node) return;
		Vector2 position = node->get_position();
		position.y = (real_t)p_y;
		node->set_position(position);
	}

	static double fire_scale(double p_fire_sprite_time, double p_index, double p_count, double p_band) {
		// remap(sin(PI * (time + i / count) * 10), -1, 1, 0.95, 1.05) * band
		const double sine = std::sin(Math::PI * (p_fire_sprite_time + p_index / p_count) * 10.0);
		return remap_01(sine, 0.95, 1.05) * p_band;
	}

	Node2D *resolve_node2d(Node *root, const char *path) {
		// get_node_or_null + NodePath(const char*) is the exact call shape the
		// rest of this TU uses; MSVC rejects the get_node(String) overload set.
		Node *node = root->get_node_or_null(NodePath(path));
		return Object::cast_to<Node2D>(node);
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("bind_player", "player", "dash_material"), &NativeSpriteTick::bind_player);
		ClassDB::bind_method(D_METHOD("reset"), &NativeSpriteTick::reset);
		ClassDB::bind_method(D_METHOD("tick", "params"), &NativeSpriteTick::tick);
		ClassDB::bind_method(D_METHOD("tick_swing_fire", "delta", "gravity_flip", "displayed_gamemode", "fire_sprite_time"), &NativeSpriteTick::tick_swing_fire);
		ClassDB::bind_method(D_METHOD("tick_robot_fire", "delta", "jump_state", "displayed_gamemode", "fire_sprite_time"), &NativeSpriteTick::tick_robot_fire);
	}

public:
	// Resolves the icon/collider node references from the player scene's
	// fixed paths (the same $NodePaths the GDScript @onready vars use).
	bool bind_player(Object *player, Object *dash_material_object) {
		Node *player_node = Object::cast_to<Node>(player);
		if (!player_node) return false;
		icon = resolve_node2d(player_node, "Icon");
		icon_cube = resolve_node2d(player_node, "Icon/Cube");
		icon_ship = resolve_node2d(player_node, "Icon/Ship");
		ship_particles = resolve_node2d(player_node, "Icon/Ship/ShipParticles");
		icon_swing = resolve_node2d(player_node, "Icon/Swing");
		icon_wave = resolve_node2d(player_node, "Icon/Wave");
		icon_ufo = resolve_node2d(player_node, "Icon/UFO");
		icon_jetpack = resolve_node2d(player_node, "Icon/Jetpack");
		jetpack_particles = resolve_node2d(player_node, "Icon/Jetpack/JetpackParticles");
		icon_ball = resolve_node2d(player_node, "Icon/Ball");
		icon_spider = resolve_node2d(player_node, "Icon/Spider");
		icon_robot = resolve_node2d(player_node, "Icon/Robot");
		corner_snapping = resolve_node2d(player_node, "CornerSnapping");
		ground_particles_origin = resolve_node2d(player_node, "GroundParticlesOrigin");
		dash_particles = resolve_node2d(player_node, "DashParticles");
		dash_flame = resolve_node2d(player_node, "DashFlame");
		dash_material = dash_material_object;
		swing_fire[0] = resolve_node2d(player_node, "Icon/Swing/FireBoostTop");
		swing_fire[1] = resolve_node2d(player_node, "Icon/Swing/FireBoostMiddle");
		swing_fire[2] = resolve_node2d(player_node, "Icon/Swing/FireBoostBottom");
		swing_fire_particles[0] = resolve_node2d(player_node, "Icon/Swing/FireBoostTop/FireParticles");
		swing_fire_particles[1] = resolve_node2d(player_node, "Icon/Swing/FireBoostMiddle/FireParticles");
		swing_fire_particles[2] = resolve_node2d(player_node, "Icon/Swing/FireBoostBottom/FireParticles");
		robot_fire[0] = resolve_node2d(player_node, "Icon/Robot/RobotSprites/Head/ConnectorBack/LegBack/FootBack/Fire");
		robot_fire[1] = resolve_node2d(player_node, "Icon/Robot/RobotSprites/Head/ConnectorFront/LegFront/FootFront/Fire");
		robot_fire_particles[0] = resolve_node2d(player_node, "Icon/Robot/RobotSprites/Head/ConnectorBack/LegBack/FootBack/Fire/FireParticles");
		robot_fire_particles[1] = resolve_node2d(player_node, "Icon/Robot/RobotSprites/Head/ConnectorFront/LegFront/FootFront/Fire/FireParticles");
		return true;
	}

	// Player.reset(): the visual accumulators start from the same values
	// the GDScript members do.
	void reset() {
		sprite_floor_angle = 0.0;
		wave_rotation_goal = 0.0;
		ball_grounded_look_factor = 0.0;
	}

	// Bit flags returned by tick():
	static constexpr int64_t RESULT_SPAWN_UFO_PARTICLE = 1;

	// One physics tick of Player._update_sprites_rotation. Params (26):
	//  0 delta              9  corrected_direction  18 dash_angle
	//  1 velocity.x         10 direction            19 snap_sprite_rotation
	//  2 velocity.y         11 slope_collider        20 displayed_gamemode
	//  3 gameplay_rotation  12 floor_angle_signed    21 on_floor
	//  4 gravity_flip       13 floor_normal_nonzero  22 on_ceiling
	//  5 gravity_multiplier 14 last_collision_valid  23 up_direction.x
	//  6 speed_multiplier   15 last_collision_n.x   24 up_direction.y
	//  7 speed.x            16 last_collision_n.y   25 gameplay_rotation_degrees
	//  8 jump_state         17 dash_active
	// The shared fire clock (_fire_sprite_time) is incremented by the player
	// itself: the swing/robot fire animations still read it from GDScript.
	int64_t tick(const PackedFloat64Array &params) {
		if (params.size() < 26) return 0;
		const double *p = params.ptr();
		const double delta = p[0];
		const Vector2 velocity((real_t)p[1], (real_t)p[2]);
		const double gameplay_rotation = p[3];
		const double gravity_flip = p[4];
		const double gravity_multiplier = p[5];
		const double speed_multiplier = p[6];
		const double speed_x = p[7];
		const double jump_state = p[8];
		const double corrected_direction = p[9];
		const double direction = p[10];
		const bool slope_collider = p[11] != 0.0;
		const double floor_angle_signed = p[12];
		const bool floor_normal_nonzero = p[13] != 0.0;
		const bool last_collision_valid = p[14] != 0.0;
		const Vector2 last_collision_normal((real_t)p[15], (real_t)p[16]);
		const bool dash_active = p[17] != 0.0;
		const double dash_angle = p[18];
		const bool snap_sprite_rotation = p[19] != 0.0;
		const int displayed_gamemode = (int)p[20];
		const bool on_floor = p[21] != 0.0;
		const bool on_ceiling = p[22] != 0.0;
		const Vector2 up_direction((real_t)p[23], (real_t)p[24]);
		const double gameplay_rotation_degrees = p[25];

		const Vector2 local_velocity = velocity.rotated((real_t)-gameplay_rotation);
		const double velocity_angle = std::atan2((double)local_velocity.y, std::abs((double)local_velocity.x)) + gameplay_rotation;
		const double floor_lerp_weight = 0.5 * delta * 60.0;
		const double snap_weight = snap_sprite_rotation ? 1.0 : floor_lerp_weight;

		if (slope_collider) {
			if (floor_normal_nonzero) {
				if (!Math::is_zero_approx(floor_angle_signed)) {
					sprite_floor_angle = lerp_angle(sprite_floor_angle,
							-floor_angle_signed + gameplay_rotation, floor_lerp_weight);
				}
			} else if (last_collision_valid && last_collision_normal != Vector2()) {
				const double collision_angle = -(double)last_collision_normal.angle_to(up_direction);
				const double ceiling_slide_rotation =
						(collision_angle < 0.0 || std::abs(collision_angle) > Math::PI / 2.0) ? Math::PI : 0.0;
				sprite_floor_angle = lerp_angle(sprite_floor_angle,
						-collision_angle + gameplay_rotation + ceiling_slide_rotation, snap_weight);
			}
		} else {
			sprite_floor_angle = lerp_angle(sprite_floor_angle, gameplay_rotation, floor_lerp_weight);
		}

		set_scale_y(ground_particles_origin, gravity_flip);
		set_scale_x(ground_particles_origin, corrected_direction);
		if (ground_particles_origin) ground_particles_origin->set_rotation((real_t)sprite_floor_angle);

		if (corrected_direction != 0.0) {
			if (icon) {
				if (displayed_gamemode == GAMEMODE_CUBE || displayed_gamemode == GAMEMODE_BALL) {
					icon->set_transform(Transform2D());
				} else {
					icon->set_transform(flip_transform(sprite_floor_angle, corrected_direction));
				}
			}
			if (corner_snapping) {
				corner_snapping->set_rotation((real_t)gameplay_rotation);
				set_scale_x(corner_snapping, corrected_direction);
				set_scale_y(corner_snapping, gravity_flip);
			}
		}

		set_scale_y(icon_cube, gravity_flip);
		set_scale_y(icon_ship, gravity_flip);
		if (icon_ship) set_particles_emitting(ship_particles, icon_ship->is_visible(), jump_state > 0.0);
		set_scale_y(icon_swing, 1.0);
		set_scale_y(icon_wave, 1.0);
		set_scale_y(icon_ufo, gravity_flip);
		set_scale_y(icon_jetpack, gravity_flip);
		if (icon_jetpack) set_particles_emitting(jetpack_particles, icon_jetpack->is_visible(), jump_state > 0.0);
		set_scale_y(icon_ball, gravity_flip);
		set_scale_y(icon_spider, gravity_flip);
		set_scale_y(icon_robot, gravity_flip);

		// Ball spin and resting-pose squash.
		if (speed_multiplier > 0.0) {
			double rotation_delta = delta * 0.45 * gravity_multiplier * ((double)local_velocity.x / speed_multiplier);
			if (!dash_active) {
				rotation_delta *= gravity_flip;
			} else {
				rotation_delta *= 1.5;
			}
			add_rotation_degrees(icon_ball, rotation_delta);
		}
		const bool ball_slow = (std::abs((double)local_velocity.x) / speed_multiplier) < speed_x * 0.5;
		ball_grounded_look_factor = lerpf(ball_grounded_look_factor, ball_slow ? 1.0 : 0.0, 10.0 * delta);
		if (icon_ball) {
			const double ball_rotation_in_air =
					polar_polygon_normalized5((double)icon_ball->get_rotation() + Math::deg_to_rad(72.0 / 2.0));
			const double pose_offset = lerpf(0.0, lerpf(0.0, 10.0, ball_rotation_in_air), ball_grounded_look_factor);
			const Vector2 pose(0.0, (real_t)pose_offset);
			icon_ball->set_position(pose.rotated((real_t)gameplay_rotation));
		}

		// Dash fire overrides every gamemode's rotation and stops the rest.
		if (dash_active) {
			if (dash_particles) {
				dash_particles->set("emitting", Variant(velocity.length() > (real_t)0.0));
				dash_particles->set_rotation((real_t)velocity_angle);
			}
			if (dash_material) {
				const double dash_degrees = Math::rad_to_deg(dash_angle);
				dash_material->set("angle_min", Variant(dash_degrees));
				dash_material->set("angle_max", Variant(dash_degrees));
			}
			if (dash_flame) dash_flame->set_rotation((real_t)dash_angle);
			add_rotation_degrees(icon_cube, delta * 800.0 * corrected_direction * gravity_flip);
			const double dash_lerp = 0.5 * delta * 60.0;
			if (icon_ship) icon_ship->set_rotation((real_t)lerp_angle((double)icon_ship->get_rotation(), velocity_angle, dash_lerp));
			if (icon_swing) icon_swing->set_rotation((real_t)lerp_angle((double)icon_swing->get_rotation(), velocity_angle, dash_lerp));
			if (icon_ufo) icon_ufo->set_rotation((real_t)lerp_angle((double)icon_ufo->get_rotation(), velocity_angle, dash_lerp));
			if (icon_jetpack) icon_jetpack->set_rotation((real_t)lerp_angle((double)icon_jetpack->get_rotation(), velocity_angle, dash_lerp));
			if (icon_spider) icon_spider->set_rotation((real_t)lerp_angle((double)icon_spider->get_rotation(), velocity_angle, dash_lerp));
			if (icon_robot) icon_robot->set_rotation((real_t)lerp_angle((double)icon_robot->get_rotation(), velocity_angle, dash_lerp));
			if (icon_wave) icon_wave->set_rotation((real_t)lerp_angle((double)icon_wave->get_rotation(), velocity_angle, dash_lerp));
			return 0;
		}

		switch (displayed_gamemode) {
			case GAMEMODE_CUBE: {
				if (!on_floor && !on_ceiling && speed_multiplier != 0.0) {
					add_rotation_degrees(icon_cube, delta * gravity_flip * 390.0 * direction * gravity_multiplier);
				} else if (icon_cube) {
					icon_cube->set_rotation((real_t)lerp_angle((double)icon_cube->get_rotation(),
							snapped((double)icon_cube->get_rotation() - sprite_floor_angle, Math::PI / 2.0) + sprite_floor_angle,
							snap_weight));
				}
				break;
			}
			case GAMEMODE_SHIP: {
				if (!on_floor && !on_ceiling && speed_multiplier > 0.0) {
					if (icon_ship) icon_ship->set_rotation((real_t)lerp_angle((double)icon_ship->get_rotation(),
							velocity_angle, 0.15 * delta * 60.0));
				} else if (icon_ship) {
					icon_ship->set_rotation((real_t)lerp_angle((double)icon_ship->get_rotation(),
							sprite_floor_angle, snap_weight));
				}
				break;
			}
			case GAMEMODE_SWING: {
				if (!on_floor && !on_ceiling && speed_multiplier > 0.0) {
					if (icon_swing) icon_swing->set_rotation((real_t)lerp_angle((double)icon_swing->get_rotation(),
							velocity_angle, 0.15 * delta * 60.0));
				} else if (icon_swing) {
					icon_swing->set_rotation((real_t)lerp_angle((double)icon_swing->get_rotation(),
							sprite_floor_angle, snap_weight));
				}
				break;
			}
			case GAMEMODE_WAVE: {
				if (direction != 0.0 || jump_state != 0.0) {
					wave_rotation_goal = velocity_angle;
					if (on_floor) {
						wave_rotation_goal = sprite_floor_angle;
					}
					if (icon_wave) icon_wave->set_rotation((real_t)lerp_angle((double)icon_wave->get_rotation(),
							wave_rotation_goal, 0.25 * delta * 60.0));
				}
				break;
			}
			case GAMEMODE_UFO: {
				if (!on_floor && !on_ceiling && speed_multiplier > 0.0) {
					if (icon_ufo) {
						set_rotation_degrees(icon_ufo, lerpf(Math::rad_to_deg((double)icon_ufo->get_rotation()),
								(double)local_velocity.y * delta * direction * 0.5 + gameplay_rotation_degrees,
								floor_lerp_weight));
					}
				} else if (icon_ufo) {
					icon_ufo->set_rotation((real_t)lerp_angle((double)icon_ufo->get_rotation(),
							sprite_floor_angle, snap_weight));
				}
				const double jetpack_target = !Math::is_zero_approx(speed_multiplier)
						? Math::deg_to_rad(std::abs((double)local_velocity.x) / speed_multiplier * delta * 5.0)
						: 0.0;
				if (icon_jetpack) {
					icon_jetpack->set_rotation((real_t)lerp_angle((double)icon_jetpack->get_rotation(),
							jetpack_target + sprite_floor_angle, snap_weight));
				}
				if (jump_state > 0.0) {
					return RESULT_SPAWN_UFO_PARTICLE;
				}
				break;
			}
			case GAMEMODE_SPIDER: {
				if (icon_spider) icon_spider->set_rotation((real_t)lerp_angle((double)icon_spider->get_rotation(),
						sprite_floor_angle, snap_weight));
				break;
			}
			case GAMEMODE_ROBOT: {
				if (icon_robot) icon_robot->set_rotation((real_t)lerp_angle((double)icon_robot->get_rotation(),
						sprite_floor_angle, snap_weight));
				break;
			}
			default:
				break;
		}
		return 0;
	}

	// One physics tick of Player._update_swing_fire (GDScript fallback
	// twin; gravity_flip arrives as a float because the comparison is < 0).
	void tick_swing_fire(double delta, double gravity_flip, int64_t displayed_gamemode, double fire_sprite_time) {
		constexpr double SWING_FIRE_BAND = 0.6;
		if (displayed_gamemode != GAMEMODE_SWING) {
			for (int i = 0; i < 3; ++i) {
				set_particles_raw(swing_fire_particles[i], false, 1.0);
			}
			return;
		}
		for (int i = 0; i < 3; ++i) {
			set_scale_x(swing_fire[i], fire_scale(fire_sprite_time, (double)i, 3.0, SWING_FIRE_BAND));
		}
		// Middle emits; all three interp_to_end values reset to 0.
		set_particles_raw(swing_fire_particles[1], true, 0.0);
		set_particles_interp(swing_fire_particles[0], 0.0);
		set_particles_interp(swing_fire_particles[2], 0.0);
		const double settle = 1.0 - std::exp(-delta * 12.0);
		if (gravity_flip < 0.0) {
			if (swing_fire[0]) swing_fire[0]->set_position(swing_fire[0]->get_position().lerp(Vector2(), (real_t)settle));
			if (swing_fire[2]) swing_fire[2]->set_position(swing_fire[2]->get_position().lerp(Vector2((real_t)-54.0, (real_t)63.0), (real_t)settle));
			set_particles_emitting_flag(swing_fire_particles[0], false);
			set_particles_emitting_flag(swing_fire_particles[2], true);
		} else {
			if (swing_fire[0]) swing_fire[0]->set_position(swing_fire[0]->get_position().lerp(Vector2((real_t)-54.0, (real_t)-63.0), (real_t)settle));
			if (swing_fire[2]) swing_fire[2]->set_position(swing_fire[2]->get_position().lerp(Vector2(), (real_t)settle));
			set_particles_emitting_flag(swing_fire_particles[0], true);
			set_particles_emitting_flag(swing_fire_particles[2], false);
		}
	}

	// One physics tick of Player._update_robot_fire.
	void tick_robot_fire(double delta, int64_t jump_state, int64_t displayed_gamemode, double fire_sprite_time) {
		constexpr double ROBOT_FIRE_SCALE = 0.9;
		for (int i = 0; i < 2; ++i) {
			Node2D *emitter = robot_fire_particles[i];
			if (!emitter) continue;
			emitter->set("interp_to_end", Variant(0.0));
			if (displayed_gamemode != GAMEMODE_ROBOT) {
				emitter->set("emitting", Variant(false));
				continue;
			}
			Node2D *fire_sprite = robot_fire[i];
			if (!fire_sprite) continue;
			set_scale_x(fire_sprite, fire_scale(fire_sprite_time, (double)i, 2.0, ROBOT_FIRE_SCALE));
			const double settle = 1.0 - std::exp(-delta * 12.0);
			if (jump_state < 1) {
				emitter->set("emitting", Variant(false));
				set_position_y(fire_sprite, lerpf((double)fire_sprite->get_position().y, 8.0, settle));
				set_scale_y(fire_sprite, lerpf((double)fire_sprite->get_scale().y, 0.0, settle));
			} else {
				emitter->set("emitting", Variant(true));
				set_position_y(fire_sprite, lerpf((double)fire_sprite->get_position().y, 44.0, settle));
				set_scale_y(fire_sprite, lerpf((double)fire_sprite->get_scale().y, ROBOT_FIRE_SCALE, settle));
			}
		}
	}
};

} // namespace godot
