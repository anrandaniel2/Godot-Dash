// Geometry Dash 2.2 shader-trigger post process (triggers 2904-2924).
// Port of GD's ShaderLayer fragment shader as shipped by
// cgytrus/LevelShadersFix resources/shaders/pp-frag.glsl. Coordinates follow
// GD: v_texCoord is the GL screen UV (y up) and scaledTexCoord = v_texCoord *
// _robHack measures the screen in units of its diagonal. Every uniform is
// written by the native ShaderLayer runtime (gdash_native.cpp GDShaderState).
// Deviations: GD pixelates by rendering to a smaller target; here sampleTex
// snaps to the same block grid (_pixelSize, square units). Camera rotation is
// not applied (_camRot stays (1, 0)).
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

uniform vec2 _robHack = vec2(1.0);
uniform vec2 _camRot = vec2(1.0, 0.0);
uniform vec2 _pixelSize = vec2(0.0);

uniform vec2 _textureScale = vec2(1.0);
uniform vec2 _textureScaleInv = vec2(1.0);

uniform float _shockWaveTime;
uniform float _shockWaveTime1;
uniform float _shockWaveTime2;
uniform float _shockWaveTime3;
uniform float _shockWaveTime4;
uniform float _shockWaveStrength;
uniform float _shockWaveWaves;
uniform vec2 _shockWaveCenter;
uniform bool _shockWaveInvert;
uniform float _shockWaveMinSize;
uniform float _shockWaveMaxSize;
uniform float _shockWaveMaxDistVal;

uniform float _shockLineTime;
uniform float _shockLineTime1;
uniform float _shockLineTime2;
uniform float _shockLineTime3;
uniform float _shockLineTime4;
uniform bool _shockLineAxis;
uniform bool _shockLineDirection;
uniform bool _shockLineDual;
uniform float _shockLineWaves;
uniform vec2 _shockLineStrength;
uniform float _shockLineCenter;
uniform float _shockLineMaxDistVal;

uniform float _glitchBot;
uniform float _glitchTop;
uniform float _glitchXOffset;
uniform vec2 _glitchColOffset;
uniform float _glitchRnd;

uniform float _chromaticXOff;
uniform float _chromaticYOff;

uniform vec2 _lensCircleOrigin;
uniform float _lensCircleStart;
uniform float _lensCircleEnd;
uniform float _lensCircleStrength;
uniform vec3 _lensCircleTint;
uniform bool _lensCircleAdditive;

uniform vec2 _bulgeOrigin;
uniform float _bulgeValue;
uniform float _bulgeValue2;
uniform float _bulgeRadius;

uniform vec2 _pinchCenterPos;
uniform vec2 _pinchValue;
uniform vec2 _pinchCalc1;
uniform float _pinchRadius;

uniform bool _blurUseRef;
uniform vec3 _blurRefColor;
uniform float _blurIntensity;
uniform float _blurFade;
uniform bool _blurOnlyEmpty;

uniform vec2 _radialBlurCenter;
uniform float _radialBlurValue;

uniform vec2 _motionBlurValue;
uniform float _motionBlurMult;
uniform bool _motionBlurDual;

uniform float _cGTime;
uniform float _cGRGBOffset;
uniform float _cGYOffset;
uniform float _cGStrength;
uniform float _cGHeight;
uniform float _cGLineStrength;
uniform float _cGLineThick;

uniform float _sepiaValue;
uniform vec4 _invertColorValue;
uniform float _grayscaleValue;
uniform vec3 _grayscaleTint = vec3(1.0);
uniform bool _grayscaleUseLum;
uniform float _hueShiftCosA;
uniform float _hueShiftSinA;
uniform vec3 _colorChangeC;
uniform vec3 _colorChangeB;

uniform float _rowmod = 1.0;
uniform float _colmod = 1.0;
uniform float _rowmodCalc;
uniform float _colmodCalc;
uniform float _splitXStart;
uniform float _splitXRange = 1.0;
uniform float _splitXRangeMult = 1.0;
uniform float _splitYStart;
uniform float _splitYRange = 1.0;
uniform float _splitYRangeMult = 1.0;

const int RADIAL_BLUR_SAMPLES = 10;
const float RADIAL_BLUR_SAMPLES_INV = 0.1;
const float MB_SAMPLES_LOOP = 9.0;
const float MB_SAMPLES_INV = 1.0 / 9.0;
const float MB_SAMPLES_LOOP_DUAL = 5.0;
const float MB_SAMPLES_DUAL_INV = 1.0 / 9.0;
// GLSL mat4(...) is column-major; gl_FragColor * sepiaMat multiplies the row
// vector, so each output channel is the dot with one column.
const mat4 SEPIA_MAT = mat4(vec4(0.393, 0.769, 0.189, 0.0), vec4(0.349, 0.686, 0.168, 0.0), vec4(0.272, 0.534, 0.131, 0.0), vec4(0.0));
const vec3 HUE_SHIFT_K = vec3(0.57735, 0.57735, 0.57735);

float inside_range(float v, float bottom, float top) {
	return step(bottom, v) - step(top, v);
}

float rand(vec2 n) {
	return fract(sin(dot(n, vec2(12.9898, 4.1414))) * 437.5854);
}

float noise(vec2 n) {
	const vec2 d = vec2(0.0, 1.0);
	vec2 b = floor(n);
	vec2 f = smoothstep(vec2(0.0), vec2(1.0), fract(n));
	return mix(mix(rand(b), rand(b + d.yx), f.x), mix(rand(b + d.xy), rand(b + d.yy), f.x), f.y);
}

vec2 apply_rotation(vec2 uv) {
	uv -= vec2(0.5) / _robHack;
	uv = vec2(_camRot.x * uv.x - _camRot.y * uv.y, _camRot.y * uv.x + _camRot.x * uv.y);
	return uv + vec2(0.5) / _robHack;
}

vec2 undo_rotation(vec2 uv) {
	uv -= vec2(0.5) / _robHack;
	uv = vec2(_camRot.x * uv.x + _camRot.y * uv.y, -_camRot.y * uv.x + _camRot.x * uv.y);
	return uv + vec2(0.5) / _robHack;
}

vec4 sample_tex(vec2 uv) {
	vec2 square = undo_rotation(uv);
	if (_pixelSize.x > 0.0) square.x = (floor(square.x / _pixelSize.x) + 0.5) * _pixelSize.x;
	if (_pixelSize.y > 0.0) square.y = (floor(square.y / _pixelSize.y) + 0.5) * _pixelSize.y;
	vec2 gl_uv = square / _robHack;
	return texture(screen_texture, vec2(gl_uv.x, 1.0 - gl_uv.y));
}

void fragment() {
	vec2 v_tex_coord = vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y);
	vec2 scaled_tex_coord = apply_rotation(v_tex_coord * _robHack);
	vec2 target_vec = scaled_tex_coord;

	if (_shockWaveTime > 0.0) {
		vec2 p = target_vec * _textureScaleInv - apply_rotation(_shockWaveCenter);
		float dis = max(length(p), 0.0001);
		float k = _shockWaveMaxDistVal != 0.0 ? clamp(1.0 - dis * _shockWaveMaxDistVal, 0.0, 1.0) : 1.0;
		if (_shockWaveInvert) dis = _shockWaveMaxSize - max(dis, _shockWaveMinSize);
		k *= clamp(smoothstep(_shockWaveTime1, _shockWaveTime2, dis) - smoothstep(_shockWaveTime3, _shockWaveTime4, dis), 0.0, 1.0);
		target_vec += k * ((p / dis) * sin(dis * _shockWaveWaves - _shockWaveTime) * _shockWaveStrength);
	}

	if (_shockLineTime != 0.0) {
		float dis = (_shockLineAxis ? target_vec.y : target_vec.x) - _shockLineCenter;
		float k = _shockLineMaxDistVal == 0.0 ? 1.0 : clamp(1.0 + (dis < 0.0 ? 1.0 : -1.0) * dis * _shockLineMaxDistVal, 0.0, 1.0);
		if (_shockLineDual) dis = abs(dis);
		if (_shockLineDirection) dis = 1.0 - dis;
		k *= clamp(smoothstep(_shockLineTime1, _shockLineTime2, dis) - smoothstep(_shockLineTime3, _shockLineTime4, dis), 0.0, 1.0);
		target_vec += k * sin(dis * _shockLineWaves - _shockLineTime) * _shockLineStrength;
	}

	if (_bulgeValue > 0.0) {
		vec2 d = target_vec * _textureScaleInv - apply_rotation(_bulgeOrigin);
		float di = length(d);
		if (di < _bulgeRadius) {
			float fade_value = pow(di / _bulgeRadius, 3.0);
			vec2 bulged_vec = (apply_rotation(_bulgeOrigin) + normalize(d) * tan(sqrt(dot(d, d)) * _bulgeValue) * _bulgeValue2) * _textureScale;
			target_vec = target_vec * fade_value + bulged_vec * (1.0 - fade_value);
		}
	}

	if (_pinchValue.x != 0.0 || _pinchValue.y != 0.0) {
		vec2 d = target_vec * _textureScaleInv - apply_rotation(_pinchCenterPos);
		float di = length(d);
		if (di < _pinchRadius) {
			float fade_value = pow(di / _pinchRadius, 2.0);
			vec2 pinched_vec = (apply_rotation(_pinchCenterPos) + normalize(d) * atan(sqrt(dot(d, d)) * -_pinchValue * 20.0) * _pinchCalc1) * _textureScale;
			target_vec = target_vec * fade_value + pinched_vec * (1.0 - fade_value);
		}
	}

	if (_glitchTop > 0.0) {
		target_vec.x += _glitchXOffset * inside_range(target_vec.y, _glitchBot, _glitchTop);
	}

	if (_colmod != 1.0 || _rowmod != 1.0) {
		target_vec = undo_rotation(target_vec);
		float normalized_x = (target_vec.x - _splitXStart) * _splitXRangeMult;
		normalized_x = normalized_x < 0.5 * _textureScale.x ? normalized_x * _colmod : normalized_x * _colmod + _colmodCalc;
		target_vec.x = _splitXStart + fract(normalized_x) * _splitXRange;
		float normalized_y = (target_vec.y - _splitYStart) * _splitYRangeMult;
		normalized_y = normalized_y < 0.5 * _textureScale.y ? normalized_y * _rowmod : normalized_y * _rowmod + _rowmodCalc;
		target_vec.y = _splitYStart + fract(normalized_y) * _splitYRange;
		target_vec = apply_rotation(target_vec);
	}

	vec4 frag = sample_tex(target_vec);

	if (_cGRGBOffset != 0.0) {
		float c_val = (scaled_tex_coord.y + _cGYOffset) * 50.0 * _cGHeight;
		target_vec.x += (noise(vec2(_cGTime, c_val)) - noise(vec2(0.0, c_val))) * _cGStrength;
		vec4 r = sample_tex(vec2(target_vec.x - _cGRGBOffset, target_vec.y));
		vec4 g = sample_tex(target_vec);
		vec4 b = sample_tex(vec2(target_vec.x + _cGRGBOffset, target_vec.y));
		vec3 color = vec3(r.r, g.g, b.b);
		if (_cGLineThick > 0.0) {
			color -= smoothstep(_cGLineThick - 0.01, _cGLineThick + 0.01, sin((scaled_tex_coord.y + _cGYOffset) * 300.0 * _cGHeight)) * _cGLineStrength;
		}
		frag = vec4(color, (r.a + g.a + b.a) * 0.3333);
	}

	if (_glitchTop > 0.0) {
		vec4 col2 = sample_tex(target_vec + _glitchColOffset);
		if (_glitchRnd < 0.33) {
			frag.r = col2.r;
		} else if (_glitchRnd < 0.66) {
			frag.g = col2.g;
		} else {
			frag.b = col2.b;
		}
		frag.a = max(frag.a, col2.a);
	}

	if (_chromaticXOff != 0.0 || _chromaticYOff != 0.0) {
		vec4 r = sample_tex(target_vec + vec2(_chromaticXOff, _chromaticYOff));
		vec4 b = sample_tex(target_vec - vec2(_chromaticXOff, _chromaticYOff));
		frag = vec4(r.r, frag.g, b.b, max(r.a, max(frag.a, b.a)));
	}

	if (_radialBlurValue != 0.0) {
		vec4 result = frag;
		if (!_blurOnlyEmpty || result.a < 0.1) {
			vec2 uv = target_vec;
			vec2 blur_vector = (apply_rotation(_radialBlurCenter) - uv) * _radialBlurValue;
			float mod_val = 1.0 + 4.5 * _blurFade;
			result *= mod_val;
			for (int i = 1; i < RADIAL_BLUR_SAMPLES; i++) {
				mod_val -= _blurFade;
				uv += blur_vector;
				result += sample_tex(uv) * mod_val;
			}
			result *= RADIAL_BLUR_SAMPLES_INV;
			frag = _blurUseRef ? vec4(result.rgb + _blurRefColor * (1.0 - result.a), result.a * _blurIntensity) : result;
		}
	} else if (_motionBlurValue.x != 0.0 || _motionBlurValue.y != 0.0) {
		vec4 result = frag;
		if (!_blurOnlyEmpty || result.a < 0.1) {
			if (_motionBlurDual) {
				for (float i = 1.0; i < MB_SAMPLES_LOOP_DUAL; i += 1.0) {
					float mod_val = 1.0 - i * _blurFade;
					vec2 offset = _motionBlurValue * (i * MB_SAMPLES_DUAL_INV);
					result += sample_tex(target_vec + offset) * mod_val;
					result += sample_tex(target_vec - offset) * mod_val;
				}
			} else {
				for (float i = 1.0; i < MB_SAMPLES_LOOP; i += 1.0) {
					float mod_val = 1.0 - i * _blurFade;
					vec2 offset = _motionBlurValue * (i * MB_SAMPLES_INV);
					result += sample_tex(target_vec + offset) * mod_val;
				}
			}
			result *= _motionBlurMult;
			frag = _blurUseRef ? vec4(result.rgb + _blurRefColor * (1.0 - result.a), result.a * _blurIntensity) : result;
		}
	}

	if (_grayscaleValue > 0.0) {
		float gray = !_grayscaleUseLum ? (frag.r + frag.g + frag.b) * 0.333 : dot(frag.rgb, vec3(0.299, 0.587, 0.114));
		frag.rgb = frag.rgb * (1.0 - _grayscaleValue) + vec3(gray) * _grayscaleValue * _grayscaleTint;
	}

	if (_sepiaValue > 0.0) {
		vec4 tex_color = frag * SEPIA_MAT;
		frag.rgb = frag.rgb * (1.0 - _sepiaValue) + tex_color.rgb * _sepiaValue;
	}

	if (_invertColorValue.a > 0.0) {
		vec4 tex_color = 1.0 - frag;
		frag.rgb = frag.rgb * (1.0 - _invertColorValue.rgb) + tex_color.rgb * _invertColorValue.rgb;
	}

	if (_hueShiftCosA != 0.0) {
		frag.rgb = frag.rgb * _hueShiftCosA + cross(HUE_SHIFT_K, frag.rgb) * _hueShiftSinA + HUE_SHIFT_K * dot(HUE_SHIFT_K, frag.rgb) * (1.0 - _hueShiftCosA);
	}

	if (_colorChangeC.r > 0.0) {
		frag.rgb = frag.rgb * _colorChangeC + _colorChangeB;
	}

	if (_lensCircleStrength > 0.0) {
		float dist = distance(scaled_tex_coord * _textureScaleInv, apply_rotation(_lensCircleOrigin));
		float k = _lensCircleStart == _lensCircleEnd ? (dist >= _lensCircleEnd ? _lensCircleStrength : 0.0) : _lensCircleStrength * (1.0 - smoothstep(_lensCircleEnd, _lensCircleStart, dist));
		frag.rgb = _lensCircleAdditive ? frag.rgb + _lensCircleTint * k : frag.rgb * (1.0 - k) + _lensCircleTint * k;
	}

	COLOR = vec4(frag.rgb, 1.0);
}
