#include <metal_stdlib>
using namespace metal;

// The planet, projected as an actual sphere.
//
// The scene used to slide a flat band of the equirectangular map behind a
// circular mask. It was cheap and it was a lie: nothing foreshortened toward the
// limb, the poles behaved like the top edge of a photograph, and dragging moved
// a picture rather than turning a world. This maps every pixel of the disc onto
// the ball, rotates it in three dimensions and samples the map there — so the
// ground compresses as it runs away to the horizon, the way it does from orbit.
//
// The terminator comes with it. Once each pixel knows its own point on the
// sphere, the sun's height there is one dot product, so day and night meet along
// a real curve across the surface instead of a gradient painted across the disc.

constant float kMapSampleBias = 0.0;

constexpr sampler mapSampler(filter::linear, address::clamp_to_edge);

/// Where a point on the unit sphere falls on a plate carrée map.
static inline float2 equirectangularUV(float3 point) {
    float latitude = asin(clamp(point.y, -1.0, 1.0));
    float longitude = atan2(point.x, point.z);
    return float2(longitude / (2.0 * M_PI_F) + 0.5, 0.5 - latitude / M_PI_F);
}

[[ stitchable ]] half4 orbitGlobe(
    float2 position,
    half4 currentColor,
    float2 center,
    float radius,
    // Where the viewer is standing over: the point at the middle of the disc,
    // which for this crop sits well below the bottom of the screen.
    float nadirLatitude,
    float nadirLongitude,
    float sunDeclination,
    float subsolarLongitude,
    // 0 for the two fixed skies, which light the whole face the same way.
    float sunFollows,
    float fixedIllumination,
    float hasNightMap,
    texture2d<half> dayMap,
    texture2d<half> nightMap
) {
    float2 offset = (position - center) / radius;
    // Screen y runs down; the sphere's does not.
    float x = offset.x;
    float y = -offset.y;
    float radiusSquared = x * x + y * y;
    if (radiusSquared >= 1.0) { return half4(0.0h); }

    // The near face of the ball: z toward the viewer.
    float z = sqrt(max(0.0, 1.0 - radiusSquared));
    float3 viewPoint = float3(x, y, z);

    // Into the globe's own frame, so the map can be read off it. Tilt by the
    // nadir's latitude first, then turn by its longitude — the inverse of aiming
    // the camera at that point.
    float tiltCos = cos(-nadirLatitude);
    float tiltSin = sin(-nadirLatitude);
    float3 tilted = float3(viewPoint.x,
                           viewPoint.y * tiltCos - viewPoint.z * tiltSin,
                           viewPoint.y * tiltSin + viewPoint.z * tiltCos);

    float turnCos = cos(nadirLongitude);
    float turnSin = sin(nadirLongitude);
    float3 spherePoint = float3(tilted.x * turnCos + tilted.z * turnSin,
                                tilted.y,
                                -tilted.x * turnSin + tilted.z * turnCos);

    float2 uv = equirectangularUV(spherePoint);
    uv.x = fract(uv.x);
    half3 color = dayMap.sample(mapSampler, uv, level(kMapSampleBias)).rgb;

    // How lit this exact point is. The surface normal of a unit sphere is the
    // point itself, so the sun's height here is one dot product — and the line
    // where that crosses zero is the terminator, curved because the sphere is.
    float illumination = fixedIllumination;
    if (sunFollows > 0.5) {
        float3 sun = float3(cos(sunDeclination) * sin(subsolarLongitude),
                            sin(sunDeclination),
                            cos(sunDeclination) * cos(subsolarLongitude));
        float elevation = asin(clamp(dot(spherePoint, sun), -1.0, 1.0)) * (180.0 / M_PI_F);
        // Lit through the first degrees of dusk, dark by the end of civil
        // twilight — the same curve the sky above the globe is drawn from.
        illumination = smoothstep(-6.0, 4.0, elevation);
    }
    float darkness = 1.0 - illumination;

    // Night falls warm where it is only just falling: that band is the sunset
    // seen from above. It goes flat black once it has fallen.
    float toBlack = saturate((darkness - 0.15) / 0.6);
    half3 duskShade = half3(0.36h, 0.15h, 0.06h) * half(1.0 - toBlack);
    color = mix(color, duskShade, half(darkness * 0.94));

    // Lights on top of the dark, never under it: the other order dims them with
    // the very night that is meant to reveal them.
    if (hasNightMap > 0.5) {
        half3 lights = nightMap.sample(mapSampler, uv, level(kMapSampleBias)).rgb;
        lights *= half(pow(darkness, 1.4));
        color = 1.0h - (1.0h - color) * (1.0h - lights);
    }

    // One pixel of feather on the limb, so the horizon is an edge rather than a
    // staircase. Premultiplied, as SwiftUI wants it.
    float edge = 1.0 - smoothstep(1.0 - (1.5 / radius), 1.0, sqrt(radiusSquared));
    return half4(color * half(edge), half(edge));
}
