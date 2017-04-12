const float PI = 3.141592653589793;

attribute vec4 a_pos_offset;
attribute vec4 a_curve_info;
attribute vec4 a_more_data;
attribute vec4 a_data;

// contents of a_size vary based on the type of property value
// used for {text,icon}-size.
// For constants, a_size is disabled.
// For source functions, we bind only one value per vertex: the value of {text,icon}-size evaluated for the current feature.
// For composite functions:
// [ text-size(lowerZoomStop, feature),
//   text-size(upperZoomStop, feature),
//   layoutSize == text-size(layoutZoomLevel, feature) ]
attribute vec3 a_size;
uniform bool u_is_size_zoom_constant;
uniform bool u_is_size_feature_constant;
uniform mediump float u_size_t; // used to interpolate between zoom stops when size is a composite function
uniform mediump float u_size; // used when size is both zoom and feature constant
uniform mediump float u_layout_size; // used when size is feature constant

#pragma mapbox: define highp vec4 fill_color
#pragma mapbox: define highp vec4 halo_color
#pragma mapbox: define lowp float opacity
#pragma mapbox: define lowp float halo_width
#pragma mapbox: define lowp float halo_blur

// matrix is for the vertex position.
uniform mat4 u_matrix;

uniform bool u_is_text;
uniform mediump float u_zoom;
uniform bool u_rotate_with_map;
uniform bool u_pitch_with_map;
uniform mediump float u_pitch;
uniform mediump float u_bearing;
uniform mediump float u_aspect_ratio;
uniform mediump float u_camera_to_center_distance;
uniform mediump float u_pitch_scale;
uniform mediump float u_collision_y_stretch;
uniform vec2 u_pitched_extrude_scale;
uniform vec2 u_unpitched_extrude_scale;

uniform vec2 u_texsize;

varying vec2 v_tex;
varying vec2 v_fade_tex;
varying float v_gamma_scale;
varying float v_size;

varying float v_hidden_glyphs;

// Used below to move the vertex out of the clip space for when the current
// zoom is out of the glyph's zoom range.
float clipUnusedGlyphAngles(const float renderSize, const float layoutSize, const float minZoom, const float maxZoom) {
    float zoomAdjust = log2(renderSize / layoutSize);
    float adjustedZoom = (u_zoom - zoomAdjust) * 10.0;
    // result: 0 if minZoom <= adjustedZoom < maxZoom, and 1 otherwise
    return 2.0 - step(minZoom, adjustedZoom) - (1.0 - step(maxZoom, adjustedZoom));
}

float interpolateNextGlyphAngle(const float renderSize,
                                const float layoutSize,
                                const float minZoom,
                                const float maxZoom,
                                const float currentAngle,
                                const float nextAngle,
                                const bool hasNextGlyph) {

    if (!hasNextGlyph) {
        return currentAngle;
    }
    // We start showing the glyph on the "next" segment (which may be left or right of us)
    // when we hit minZoom.
    // Find the zoom that gives us a position X units less than the position we'd have at minZoom
    // Interpolate between that zoom and minZoom
    float zoomAdjust = log2(renderSize / layoutSize);
    float adjustedZoom = (u_zoom - zoomAdjust) * 10.0;
    float startInterpolationZoom = minZoom + (maxZoom - minZoom) * 0.2;
    if (step(startInterpolationZoom, adjustedZoom) == 1.0) {
        return currentAngle;
    } else {
        if (abs(nextAngle - currentAngle) > PI) {
            if (nextAngle > currentAngle) {
                return mod(mix(nextAngle, currentAngle + 2.0 * PI, (adjustedZoom - minZoom) / (startInterpolationZoom - minZoom)), 2.0 * PI);
            } else {
                return mod(mix(nextAngle + 2.0 * PI, currentAngle, (adjustedZoom - minZoom) / (startInterpolationZoom - minZoom)), 2.0 * PI);
            }
        } else {
            return mix(nextAngle, currentAngle, (adjustedZoom - minZoom) / (startInterpolationZoom - minZoom));
        }
    }
}

void main() {
    #pragma mapbox: initialize highp vec4 fill_color
    #pragma mapbox: initialize highp vec4 halo_color
    #pragma mapbox: initialize lowp float opacity
    #pragma mapbox: initialize lowp float halo_width
    #pragma mapbox: initialize lowp float halo_blur

    vec2 a_pos = a_pos_offset.xy;
    vec2 a_offset = a_pos_offset.zw;

    vec2 a_label_pos = a_curve_info.xy;
    vec2 a_glyph_offset = a_curve_info.zw;

    vec2 a_tex = a_data.xy;

    mediump vec2 label_data = unpack_float(a_data[2]);
    mediump float a_labelminzoom = label_data[0];
    mediump float a_lineangle = a_more_data[1] / 10000.0 * 2.0 * PI;
    //mediump float a_lineangle = a_more_data[1];
    mediump vec2 a_zoom = unpack_float(a_data[3]);
    mediump float a_minzoom = a_zoom[0];
    mediump float a_maxzoom = a_zoom[1];
    mediump float a_anchorangle = a_more_data[0] / 10000.0 * 2.0 * PI;
    bool a_has_next_glyph = a_more_data[2] <= 10000.0;
    mediump float a_next_glyph_angle = a_more_data[2] / 10000.0 * 2.0 * PI;

    // In order to accommodate placing labels around corners in
    // symbol-placement: line, each glyph in a label could have multiple
    // "quad"s only one of which should be shown at a given zoom level.
    // The min/max zoom assigned to each quad is based on the font size at
    // the vector tile's zoom level, which might be different than at the
    // currently rendered zoom level if text-size is zoom-dependent.
    // Thus, we compensate for this difference by calculating an adjustment
    // based on the scale of rendered text size relative to layout text size.
    mediump float layoutSize;
    if (!u_is_size_zoom_constant && !u_is_size_feature_constant) {
        v_size = mix(a_size[0], a_size[1], u_size_t) / 10.0;
        layoutSize = a_size[2] / 10.0;
    } else if (u_is_size_zoom_constant && !u_is_size_feature_constant) {
        v_size = a_size[0] / 10.0;
        layoutSize = v_size;
    } else if (!u_is_size_zoom_constant && u_is_size_feature_constant) {
        v_size = u_size;
        layoutSize = u_layout_size;
    } else {
        v_size = u_size;
        layoutSize = u_size;
    }

    float fontScale = u_is_text ? v_size / 24.0 : v_size;

    vec4 projectedPoint = u_matrix * vec4(a_label_pos, 0, 1);
    highp float camera_to_anchor_distance = projectedPoint.w;
    highp float perspective_ratio = 1.0 + (1.0 - u_pitch_scale)*((camera_to_anchor_distance / u_camera_to_center_distance) - 1.0);

    v_hidden_glyphs = 0.0;

    // incidence_stretch is the ratio of how much y space a label takes up on a tile while drawn perpendicular to the viewport vs
    //  how much space it would take up if it were drawn flat on the tile
    // Using law of sines, camera_to_anchor/sin(ground_angle) = camera_to_center/sin(incidence_angle)
    // sin(incidence_angle) = 1/incidence_stretch
    // Incidence angle 90 -> head on, sin(incidence_angle) = 1, no incidence stretch
    // Incidence angle 1 -> very oblique, sin(incidence_angle) =~ 0, lots of incidence stretch
    // ground_angle = u_pitch + PI/2 -> sin(ground_angle) = cos(u_pitch)
    // This 2D calculation is only exactly correct when gl_Position.x is in the center of the viewport,
    //  but it's a close enough approximation for our purposes
    highp float incidence_stretch  = camera_to_anchor_distance / (u_camera_to_center_distance * cos(u_pitch));
    highp float legibility_expansion = 1.0;

    // pitch-alignment: map
    // rotation-alignment: map | viewport
    if (u_pitch_with_map) {
        lowp float angle = u_rotate_with_map ? a_lineangle : u_bearing;
        lowp float asin = sin(angle);
        lowp float acos = cos(angle);
        mat2 RotationMatrix = mat2(acos, asin, -1.0 * asin, acos);
        vec2 offset = RotationMatrix * (a_glyph_offset + a_offset);
        vec2 extrude = fontScale * u_pitched_extrude_scale * perspective_ratio * (offset / 64.0);

        gl_Position = u_matrix * vec4(a_pos + extrude, 0, 1);
        gl_Position.z += clipUnusedGlyphAngles(v_size*perspective_ratio, layoutSize, a_minzoom, a_maxzoom) * gl_Position.w;
    // pitch-alignment: viewport
    // rotation-alignment: map
    } else if (u_rotate_with_map) {
        // Calculate how vertical the label is in projected space, space out letters according to the angle of
        //  incidence at the point of the label anchor
        vec4 a = u_matrix * vec4(a_label_pos, 0, 1);
        vec4 b = u_matrix * vec4(a_label_pos + vec2(cos(a_anchorangle),sin(a_anchorangle)), 0, 1);
        highp float projected_label_angle = atan((b[1]/b[3] - a[1]/a[3])/u_aspect_ratio, b[0]/b[3] - a[0]/a[3]);
        legibility_expansion += abs(sin(projected_label_angle)) * (incidence_stretch - 1.0);

        // Place the center of the glyph in tile space
        lowp float asin = sin(a_lineangle);
        lowp float acos = cos(a_lineangle);
        mat2 TileRotationMatrix = mat2(acos, asin, -1.0 * asin, acos);
        vec2 glyph_center_offset = TileRotationMatrix * a_glyph_offset;
        vec2 glyph_center_extrude = fontScale * u_pitched_extrude_scale * perspective_ratio * legibility_expansion * (glyph_center_offset / 64.0) ;

        // Rotate and extrude the corners of the glyph in projected space
        highp float next_angle = interpolateNextGlyphAngle(v_size*perspective_ratio*legibility_expansion,
                                                           layoutSize,
                                                           a_minzoom,
                                                           a_maxzoom,
                                                           a_lineangle,
                                                           a_next_glyph_angle,
                                                           a_has_next_glyph);
        a = u_matrix * vec4(a_pos, 0, 1);
        b = u_matrix * vec4(a_pos + vec2(cos(next_angle),sin(next_angle)), 0, 1);
        highp float projected_line_angle = atan((b[1]/b[3] - a[1]/a[3])/u_aspect_ratio, b[0]/b[3] - a[0]/a[3]);
        highp float sin_projected_angle = sin(projected_line_angle);
        highp float cos_projected_angle = cos(projected_line_angle);
        mat2 ProjectedRotationMatrix = mat2(cos_projected_angle,
                                            -1.0 * sin_projected_angle,
                                            sin_projected_angle,
                                            cos_projected_angle);

        vec2 glyph_vertex_offset = ProjectedRotationMatrix * a_offset;
        vec2 glyph_vertex_extrude = fontScale * u_unpitched_extrude_scale * perspective_ratio * (glyph_vertex_offset / 64.0);

        gl_Position = u_matrix * vec4(a_pos + glyph_center_extrude, 0, 1);
        gl_Position += vec4(glyph_vertex_extrude, 0, 0);
        v_hidden_glyphs = clipUnusedGlyphAngles(v_size*perspective_ratio*legibility_expansion, layoutSize, a_minzoom, a_maxzoom) / 4.0;
        gl_Position.z += clipUnusedGlyphAngles(v_size*perspective_ratio*legibility_expansion, layoutSize, a_minzoom, a_maxzoom) * gl_Position.w;
    // pitch-alignment: viewport
    // rotation-alignment: viewport
    } else {
        vec2 extrude = fontScale * u_unpitched_extrude_scale * perspective_ratio * ((a_offset+a_glyph_offset) / 64.0);
        gl_Position = u_matrix * vec4(a_pos, 0, 1) + vec4(extrude, 0, 0);
    }

    v_gamma_scale = gl_Position.w / perspective_ratio;

    v_tex = a_tex / u_texsize;

    // incidence_stretch only applies to the y-axis, but without re-calculating the collision tile, we can't
    // adjust the size of only one axis. So, we do a crude approximation at placement time to get the aspect ratio
    // about right, and then do the rest of the adjustment here: there will be some extra padding on the x-axis,
    // but hopefully not too much.
    highp float collision_adjustment = incidence_stretch / u_collision_y_stretch;

    highp float perspective_zoom_adjust = log2(perspective_ratio * collision_adjustment * legibility_expansion)*10.0 / 255.0;
    v_fade_tex = vec2((a_labelminzoom / 255.0) + perspective_zoom_adjust, 0.0);
}
