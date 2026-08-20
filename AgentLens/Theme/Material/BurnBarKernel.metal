//  BurnBarKernel.metal
//
//  The dashboard's living field, as a fragment program.
//
//  WHY A SHADER, WHEN THERE IS ALREADY A WORKING WEBGL FIELD.
//
//  The field shipped as a WebGL2 bundle inside a `WKWebView`
//  (`Views/Dashboard/Components/KernelBackdropView.swift`). It looks right, and it is
//  the wrong kind of object. A `WKWebView` is a *sealed rectangle in the compositor*:
//  its pixels live in another process and are composited by the window server after
//  SwiftUI is done. Concretely, that rectangle
//
//    * cannot be rasterised by `drawingGroup()`,
//    * cannot be refracted by `layerEffect` — so `burnBarGlassLens` next door cannot
//      bend it, which means every glass plate in the app floats over a field it
//      cannot see,
//    * cannot be captured by `ImageRenderer` (no share sheet, no snapshot tests),
//    * and cannot be sampled by macOS 26 `glassEffect`, which is the whole point of
//      the material work: system glass reads what is behind it, and behind it was a
//      hole.
//
//  Written as a `[[stitchable]]` fill shader the field becomes ordinary SwiftUI
//  content: a `ShapeStyle` on a `Rectangle`. Everything above can sample it. As a
//  bonus it removes a second WebContent process and a ~255 KB JavaScript bundle from
//  a menu-bar app that is meant to be the cheap observer, not the expensive one.
//
//  The floor is macOS 14 / iOS 17 (`project.yml:4-6`). `Shader`, `ShaderLibrary` and
//  the `ShapeStyle` conformance all land at exactly macOS 14.0 / iOS 17.0
//  (SwiftUICore.swiftinterface:8167 / 8180 / 25067), so this is the baseline tier for
//  the entire install base rather than a 26-only flourish. Same argument as
//  `BurnBarGlass.metal`, same conclusion.
//
//  WHAT THE FIELD IS SAYING.
//
//  It is not decoration with a colour picker. Every visible property is derived from
//  what the fleet is actually doing, via `SwarmColorDriver` (which already models
//  weighted provider bands, quota pressure and a burn-rate intensity curve):
//
//    * COLOUR BANDS  — each provider owns a ribbon of the field whose *width is its
//                      share of spend*. Reading the field top to bottom is reading
//                      the day's provider mix. Band colours arrive already tinted
//                      toward warning red by quota pressure (the driver does that).
//    * ENERGY        — burn rate. Drives filament amplitude, not merely brightness:
//                      a busy fleet reads as more *structure*, because "brighter" is
//                      what a screensaver does and "more structure" is what a system
//                      under load does.
//    * TURBULENCE    — quota pressure. Widens the domain warp so the ribbons churn,
//                      and switches the filaments from steady to *pulsing*. A limit
//                      approaching is a throb, not a churn; churn alone reads as
//                      activity, which is the opposite of the message.
//    * DETAIL        — the accessibility axis. Reduce Transparency collapses the
//                      field toward a near-flat opaque substrate that still carries
//                      the same provider colours in the same order.
//
//  COST. Per pixel: 2 fBm evaluations for the domain warp + 1 ridged fBm for the
//  filaments, 3 octaves each, 4 lattice hashes per octave = 36 hashes ≈ 360 ALU,
//  plus ~60 ALU of composition. No texture reads, no dependent sampling, no loops
//  over any data-dependent count — the cost is exactly O(pixels) and identical for
//  one provider or forty. Per frame on the CPU: about thirty floats — three phases,
//  three scalars, a colour and four band vectors. There is no display list, no
//  allocation, and nothing to invalidate. The plume term is derived from
//  the warp fBm that was computed anyway rather than a fourth noise call, which is
//  a 25% saving for a term that *should* correlate with the flow.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Lattice noise

/// Hash a 2D lattice point to [0,1).
///
/// Hoskins' `hash12`: three multiplies, a dot and two `fract`s. Deliberately *not*
/// the `fract(sin(dot(...)) * 43758.5453)` hash every shader tutorial uses — that one
/// costs a transcendental-unit round trip, and this function is evaluated 36 times
/// per pixel, which is exactly where a "cheap" `sin` stops being cheap.
static float hash12(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

/// Bilinear value noise with a smoothstep fade.
///
/// Value rather than gradient (Perlin/simplex) noise because the field is a slow
/// atmospheric wash with no fast edges: the directional character gradient noise buys
/// is invisible here, and it costs twice the hashes.
static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    // `f*f*(3-2f)` is the C1 fade. Without it the lattice shows as a visible grid of
    // diamonds, which is the classic tell of hand-rolled noise.
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Three-octave fBm, normalised to 0…1.
///
/// Three is the floor at which the result stops reading as "one blob" and the ceiling
/// beyond which nothing is visible at backdrop scale. The per-octave offset and the
/// slightly-off lacunarity (2.03, not 2.0) stop the octaves sharing lattice points,
/// which is what produces the faint cross-hatch you see in naive fBm.
static float fieldFBM(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int octave = 0; octave < 3; ++octave) {
        sum += amplitude * valueNoise(p);
        p = p * 2.03 + float2(11.7, 3.1);
        amplitude *= 0.5;
    }
    return sum / 0.875;  // 0.5 + 0.25 + 0.125
}

/// Ridged fBm — the filaments.
///
/// `1 - |2n - 1|` folds the noise about its midline, turning smooth hills into
/// creases; squaring sharpens them. This is the term that reads as burning threads
/// rather than fog, and it is the only reason the field looks alive rather than
/// merely coloured.
static float fieldRidge(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int octave = 0; octave < 3; ++octave) {
        float ridge = 1.0 - abs(valueNoise(p) * 2.0 - 1.0);
        sum += amplitude * ridge * ridge;
        p = p * 2.11 + float2(4.3, 9.7);
        amplitude *= 0.5;
    }
    return sum / 0.875;
}

// MARK: - Provider bands

/// Resolve the provider colour at band coordinate `s` (0…1).
///
/// Each `band` carries `rgb` plus, in `w`, the *cumulative upper edge* of its share —
/// so the widths are the spend shares and the lookup is three cross-fades with no
/// branching and no loop. The edges arrive non-decreasing and the last one is exactly
/// 1, which is what makes the chained `mix` correct: once `s` passes an edge the
/// later fades own the result.
///
/// A provider with zero share arrives carrying the *previous* band's colour (see
/// `BurnBarKernelMath.bands`), so a degenerate zero-width ribbon cross-fades to itself
/// instead of flashing an unrelated hue through the seam.
static float3 usageBandColor(float s, float4 b0, float4 b1, float4 b2, float4 b3, float blend) {
    float w = max(blend, 0.001);
    float3 color = b0.rgb;
    color = mix(color, b1.rgb, smoothstep(b0.w - w, b0.w + w, s));
    color = mix(color, b2.rgb, smoothstep(b1.w - w, b1.w + w, s));
    color = mix(color, b3.rgb, smoothstep(b2.w - w, b2.w + w, s));
    return color;
}

// MARK: - The field

/// BurnBar's usage field.
///
/// - `position`    fill coordinate, in the filled shape's user space
/// - `bounds`      the shape's bounding rect (`.boundingRect`); origin + size
/// - `phase`       drift / swirl / pulse phases in radians, 0…2π (see "eternal drift")
/// - `energy`      0…1 burn rate
/// - `turbulence`  0…1 churn, derived from quota pressure
/// - `detail`      0…1 structural amplitude; Reduce Transparency drives this down
/// - `ground`      the opaque page colour the field settles onto
/// - `band0…3`     rgb + cumulative upper edge, widths proportional to spend share
///
/// Split into a shared body plus two entry points so the SAME weather can be drawn
/// two ways. The page draws it as a fill (`Rectangle().fill(shader)`); a glass plate
/// draws it as a `colorEffect` over its own bounds, passing a `bounds` whose origin is
/// the NEGATED plate origin — which makes the plate's local uv resolve to the page's
/// uv, so the patch under the plate is the same weather the page would have painted
/// there. That registration is what lets a plate refract the field instead of
/// refracting a decorative gradient that merely resembles it.
static half4 burnBarUsageFieldBody(float2 position,
                                   float4 bounds,
                                   float3 phase,
                                   float energy,
                                   float turbulence,
                                   float detail,
                                   half4 ground,
                                   float4 band0,
                                   float4 band1,
                                   float4 band2,
                                   float4 band3) {
    float2 size = max(bounds.zw, float2(1.0));
    float2 uv = (position - bounds.xy) / size;

    // Aspect-correct the noise domain, or the ribbons stretch into stripes on a wide
    // window and squash into blobs on a narrow one. The field should look like the
    // same weather at any window size.
    float aspect = size.x / size.y;
    float2 p = float2(uv.x * aspect, uv.y);

    float structureAmount = clamp(detail, 0.0, 1.0);
    float burn = clamp(energy, 0.0, 1.0);
    float churn = clamp(turbulence, 0.0, 1.0);

    // --- Eternal drift ---------------------------------------------------------
    // The drift is a *circle*, not a line. A linear `t * speed` offset would need a
    // monotonically growing time, and a `float` has 24 bits of mantissa: one day of
    // uptime puts the time quantum at ~16 ms and one week at ~125 ms, so a menu-bar
    // app left open over a weekend would visibly stutter. Orbiting the noise domain
    // makes each layer exactly 2π-periodic, so the CPU can hand us phases wrapped
    // into 0…2π forever — no precision loss, and no seam at the wrap, because
    // `cos(2π) == cos(0)` exactly. Three mutually incommensurate periods (191 s,
    // 47 s, 9 s) put the visible repeat many hours away.
    float2 driftA = float2(cos(phase.x), sin(phase.x)) * 0.62;
    float2 driftB = float2(cos(phase.y), -sin(phase.y)) * 0.28;

    // --- Domain warp -----------------------------------------------------------
    // Flow, done the cheap way: displace the sampling domain by noise instead of
    // simulating advection. Quota pressure widens the displacement, so the ribbons
    // stop being laminar exactly when the fleet stops being comfortable.
    float warpX = fieldFBM(p * 1.35 + driftA);
    float warpY = fieldFBM(p * 1.35 + driftB + float2(7.31, 2.17));
    float2 warp = float2(warpX, warpY) - 0.5;
    float2 q = p + warp * ((0.16 + 0.42 * churn) * structureAmount);

    // --- Provider ribbons ------------------------------------------------------
    // The band axis is vertical with a slight tilt, so the ribbons read as weather
    // crossing the window rather than as a bar chart lying on its side.
    float s = clamp(q.y + (q.x - aspect * 0.5) * 0.08, 0.0, 1.0);
    float3 band = usageBandColor(s, band0, band1, band2, band3, 0.055 + 0.03 * structureAmount);

    // On a paper-light ground a saturated ribbon reads as a stain sitting *in front
    // of* the text. Lift the band toward white in proportion to how bright the ground
    // is, judged from the ground itself rather than from a light/dark flag — that way
    // the shader stays correct for the editorial skin and for any future surface.
    float groundLuma = dot(float3(ground.rgb), float3(0.2126, 0.7152, 0.0722));
    float paper = smoothstep(0.35, 0.75, groundLuma);
    band = mix(band, float3(1.0), 0.66 * paper);

    // --- Light -----------------------------------------------------------------
    // The plumes are the warp itself, read as a difference rather than resampled:
    // the field is brightest where the flow diverges, which is where a real fluid
    // thins. Free, and more physically honest than an independent noise field.
    float plume = clamp(0.5 + (warpX - warpY) * 1.15, 0.0, 1.0);
    float bodyLight = 0.34 + 0.66 * plume;

    // Under pressure the filaments pulse, and the pulse travels *along* the band axis
    // so it sweeps rather than blinks. At `churn` 0 the factor is exactly 1 and the
    // term disappears, so the idle floor leaves a breath rather than a heartbeat.
    float throb = 0.5 + 0.5 * sin(phase.z + s * 6.2831853);
    float pulse = mix(1.0, 0.55 + 0.9 * throb, churn);

    // Cubing the ridge is what separates threads from haze: it crushes the broad
    // shoulder and keeps only the creases.
    float filament = fieldRidge(q * 3.4 - driftA * 0.9);
    float threads = pow(filament, 3.0) * (0.22 + 0.78 * burn) * structureAmount * pulse;

    // Filaments tint toward warm white rather than pure white. Pure white highlights
    // are the tell of a fake material — the same rule `BurnBarGlass.metal` follows.
    float3 hot = mix(band, float3(1.0, 0.965, 0.925), 0.5);
    float3 lit = band * bodyLight + hot * threads;

    // A quiet radial falloff. Corners are where window chrome and scroll edges live;
    // letting the field peak there fights the frame.
    float2 centred = uv - 0.5;
    lit *= 1.0 - 0.55 * dot(centred, centred);

    // --- Settle onto the page --------------------------------------------------
    // This is the legibility contract, and the reason the field is opaque: text sits
    // on top of it, so the field commits to a known ground instead of leaving the
    // compositor to decide. `presence` is how much of the field survives that mix —
    // it rises with burn rate, falls with Reduce Transparency, and is damped on paper
    // because a light ground has far less contrast headroom to give away.
    float presence = clamp((0.20 + 0.55 * burn) * (0.34 + 0.66 * structureAmount), 0.0, 1.0);
    presence *= mix(1.0, 0.70, paper);

    float3 result = mix(float3(ground.rgb), lit, presence);
    return half4(half3(clamp(result, 0.0, 1.0)), 1.0h);
}

// MARK: - Entry points

/// The page: an ordinary fill over the whole window.
[[ stitchable ]] half4 burnBarUsageField(float2 position,
                                         float4 bounds,
                                         float3 phase,
                                         float energy,
                                         float turbulence,
                                         float detail,
                                         half4 ground,
                                         float4 band0,
                                         float4 band1,
                                         float4 band2,
                                         float4 band3) {
    return burnBarUsageFieldBody(position, bounds, phase, energy, turbulence, detail,
                                 ground, band0, band1, band2, band3);
}

/// A glass plate's interior.
///
/// `colorEffect` hands in the existing colour; it is discarded on purpose. The plate
/// paints an opaque ground first precisely so this can overwrite it with the page's
/// own weather at the plate's page position — the point is registration, not blending.
[[ stitchable ]] half4 burnBarUsageFieldColor(float2 position,
                                              half4 color,
                                              float4 bounds,
                                              float3 phase,
                                              float energy,
                                              float turbulence,
                                              float detail,
                                              half4 ground,
                                              float4 band0,
                                              float4 band1,
                                              float4 band2,
                                              float4 band3) {
    (void)color;
    return burnBarUsageFieldBody(position, bounds, phase, energy, turbulence, detail,
                                 ground, band0, band1, band2, band3);
}
