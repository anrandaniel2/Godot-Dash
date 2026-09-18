shader_type canvas_item;
uniform vec2 scale = vec2(1.0, 1.0);
uniform float alpha = 0.0;
uniform float inner_radius = 0.0;
uniform float outer_radius = 1.0;

void fragment() {
    float dist = length(UV * scale * 2.0 - 1.0);
    float q = clamp(1.0 - (1.0 - dist / outer_radius) / (1.0 - inner_radius), 0.0, 1.0);
    COLOR = vec4(0.0, 0.0, 0.0, q * alpha);
}