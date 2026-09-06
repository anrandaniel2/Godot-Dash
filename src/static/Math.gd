@abstract
class_name Math

static func sec(angle: float) -> float:
	return 1 / cos(angle)


static func polar_polygon(angle: float, sides: int, curvature: float) -> float:
	return sec(
		PI * (fposmod((sides * angle) / TAU, 1.0) - 0.5) * curvature
		/ (sides / 2.0),
	)


static func polar_polygon_normalized(angle: float, sides: int, curvature: float) -> float:
	return polar_polygon(angle, sides, curvature) / polar_polygon(0, sides, curvature)
