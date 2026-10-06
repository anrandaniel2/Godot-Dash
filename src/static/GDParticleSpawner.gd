class_name GDParticleSpawner
## Twin of the native Spawn Particle (3608) helpers in gdash_native.cpp
## (parse_particle_data, particle_burst_count, spawn_particle_burst).
## Particle object data (key 145) is 'a'-separated in the gmdkit
## models/prop/particle.py field order; burst rules follow UHDanke/gd_docs
## docs/triggers/animate/spawn_particle.md.

const MAX := 0
const DURATION := 1
const LIFETIME := 2
const LIFETIME_RAND := 3
const EMISSION := 4
const ANGLE := 5
const ANGLE_RAND := 6
const SPEED := 7
const SPEED_RAND := 8
const POSVAR_X := 9
const POSVAR_Y := 10
const GRAVITY_X := 11
const GRAVITY_Y := 12
const ACCEL_RAD := 13
const ACCEL_RAD_RAND := 14
const ACCEL_TAN := 15
const ACCEL_TAN_RAND := 16
const START_SIZE := 17
const START_SIZE_RAND := 18
const START_SPIN := 19
const START_SPIN_RAND := 20
const START_R := 21
const START_G := 23
const START_B := 25
const START_A := 27
const END_SIZE := 29
const END_SPIN := 31
const END_R := 33
const END_G := 35
const END_B := 37
const END_A := 39
const ADDITIVE := 56
const PX_PER_UNIT: float = 128.0 / 30.0


static func parse(raw: String) -> PackedFloat64Array:
	var fields := PackedFloat64Array()
	for part: String in raw.split("a"):
		fields.append(float(part) if not part.is_empty() else 0.0)
	return fields


static func field(f: PackedFloat64Array, index: int) -> float:
	return f[index] if index < f.size() else 0.0


static func burst_count(f: PackedFloat64Array) -> int:
	var max_particles: float = field(f, MAX)
	var duration: float = field(f, DURATION)
	var emission: float = field(f, EMISSION)
	if max_particles <= 0.0:
		return 0
	if emission < 0.0:
		return int(max_particles)
	if duration <= 0.0:
		return 0
	return int(minf(max_particles, ceilf(emission * duration)))


static func spawn(f: PackedFloat64Array, at: Vector2, rotation_deg: float, scale: float, parent: Node) -> void:
	var count: int = burst_count(f)
	if count <= 0 or parent == null:
		return
	var p := CPUParticles2D.new()
	p.amount = count
	p.one_shot = true
	p.explosiveness = 1.0 if field(f, EMISSION) < 0.0 else 0.0
	var lifetime: float = maxf(0.01, field(f, LIFETIME))
	p.lifetime = lifetime
	p.lifetime_randomness = clampf(field(f, LIFETIME_RAND) / lifetime, 0.0, 1.0)
	var angle: float = deg_to_rad(field(f, ANGLE))
	p.direction = Vector2(cos(angle), -sin(angle))
	p.spread = field(f, ANGLE_RAND)
	p.initial_velocity_min = (field(f, SPEED) - field(f, SPEED_RAND)) * PX_PER_UNIT
	p.initial_velocity_max = (field(f, SPEED) + field(f, SPEED_RAND)) * PX_PER_UNIT
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(field(f, POSVAR_X), field(f, POSVAR_Y)) * PX_PER_UNIT
	p.gravity = Vector2(field(f, GRAVITY_X), -field(f, GRAVITY_Y)) * PX_PER_UNIT
	p.radial_accel_min = (field(f, ACCEL_RAD) - field(f, ACCEL_RAD_RAND)) * PX_PER_UNIT
	p.radial_accel_max = (field(f, ACCEL_RAD) + field(f, ACCEL_RAD_RAND)) * PX_PER_UNIT
	p.tangential_accel_min = -(field(f, ACCEL_TAN) + field(f, ACCEL_TAN_RAND)) * PX_PER_UNIT
	p.tangential_accel_max = -(field(f, ACCEL_TAN) - field(f, ACCEL_TAN_RAND)) * PX_PER_UNIT
	var start_size: float = maxf(0.0, field(f, START_SIZE))
	p.scale_amount_min = maxf(0.0, start_size - field(f, START_SIZE_RAND)) * PX_PER_UNIT
	p.scale_amount_max = (start_size + field(f, START_SIZE_RAND)) * PX_PER_UNIT
	var size_curve := Curve.new()
	var end_ratio: float = maxf(0.0, field(f, END_SIZE)) / start_size if start_size > 0.0 else 1.0
	size_curve.max_value = maxf(1.0, end_ratio)
	size_curve.add_point(Vector2(0.0, 1.0))
	size_curve.add_point(Vector2(1.0, end_ratio))
	p.scale_amount_curve = size_curve
	p.angle_min = -(field(f, START_SPIN) + field(f, START_SPIN_RAND))
	p.angle_max = -(field(f, START_SPIN) - field(f, START_SPIN_RAND))
	var spin_speed: float = -(field(f, END_SPIN) - field(f, START_SPIN)) / lifetime
	p.angular_velocity_min = spin_speed
	p.angular_velocity_max = spin_speed
	var ramp := Gradient.new()
	ramp.set_color(0, Color(field(f, START_R), field(f, START_G), field(f, START_B), field(f, START_A)))
	ramp.set_color(1, Color(field(f, END_R), field(f, END_G), field(f, END_B), field(f, END_A)))
	p.color_ramp = ramp
	if field(f, ADDITIVE) != 0.0:
		var material := CanvasItemMaterial.new()
		material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		p.material = material
	parent.add_child(p)
	p.global_position = at
	p.rotation = deg_to_rad(rotation_deg)
	p.scale = Vector2.ONE * scale
	p.finished.connect(p.queue_free)
	p.emitting = true
