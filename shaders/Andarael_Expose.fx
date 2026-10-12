/*
    Andarael_Expose: exposure control in a reconstructed HDR space, with a choice of tone curves.

    The displayed image is already tone mapped. To change its exposure without clipping or flattening
    the highlights, the shader:
      1. decodes the frame to linear light (SDR power gamma, scRGB or HDR10),
      2. expands it with the inverse of a tone curve, so highlights near white get their range back,
      3. multiplies by the exposure (manual, plus optional auto exposure),
      4. compresses it with the tone curve and encodes it again.
    When steps 2 and 4 use the same curve, 0 EV gives back the original image: the curve only decides
    how highlights and shadows respond when the exposure moves. Expanding with one curve and compressing
    with another re-tonemaps the image (the look changes even at 0 EV).

    Tone curves:
      - Linear: no compression, pushed highlights clip.
      - Reinhard: x / (1 + x), long soft shoulder.
      - Hable: John Hable's Uncharted 2 filmic curve, with a toe.
      - ACES: Stephen Hill's fit of the ACES RRT + ODT (sRGB output), more contrast, gamut matrices.
      - AgX: Troy Sobotka's AgX, log2 encoding + sigmoid between inset/outset matrices.
        Highlights travel smoothly towards white without the hue skews of per-channel curves.
      - Khronos PBR Neutral: keeps colours unchanged below 0.76, then compresses the max channel and
        desaturates towards white. Its desaturation cannot be inverted, so when it is used for both
        expansion and compression it only applies to the brightening that the exposure adds.
    Linear, Reinhard and Hable can run per channel, on luminance or on the max channel.
    The other curves have their own colour handling.

    Channel crosstalk mixes each channel towards the channel average before expansion and undoes it after
    compression. Saturated highlights then desaturate towards white when pushed, as on film, instead of
    clipping per channel.

    The colour space is taken from ReShade (BUFFER_COLOR_SPACE). Force it with ANDARAEL_EXPOSE_COLOUR_SPACE
    (1 = SDR, 2 = scRGB, 3 = HDR10). HDR is processed in linear BT.2020 normalised to the peak brightness;
    the ACES and AgX matrices are converted to and from their own primaries (BT.709 and BT.2020).

    The idea of exposing in an inverse tone mapped space comes from Pascal Gilcher's SOLARIS.
    No code from it is used.

    Curve credits:
      - Hable filmic curve: John Hable, "Filmic Tonemapping Operators" (2010).
      - ACES fit: Stephen Hill (@self_shadow), as published in MJP's Baking Lab (MIT).
      - AgX: polynomial sigmoid fit by Benjamin Wrensch ("Minimal AgX implementation"),
        inset/outset matrices and log range as in three.js (MIT), derived from Filament / Blender.
      - Khronos PBR Neutral: Khronos Group (github.com/KhronosGroup/ToneMapping).
    The inverses are derived here.

    MIT License - Copyright (c) 2026 Andarael
*/

#include "ReShade.fxh"

#ifndef ANDARAEL_EXPOSE_COLOUR_SPACE
    #if (BUFFER_COLOR_SPACE == 2)
        #define ANDARAEL_EXPOSE_COLOUR_SPACE 2
    #elif (BUFFER_COLOR_SPACE == 3)
        #define ANDARAEL_EXPOSE_COLOUR_SPACE 3
    #else
        #define ANDARAEL_EXPOSE_COLOUR_SPACE 1
    #endif
#endif

#define EXPOSE_HDR (ANDARAEL_EXPOSE_COLOUR_SPACE >= 2)

// --- UI ------------------------------------------------------------------------------------------

uniform float ExposureEV <
    ui_category = "Exposure";
    ui_type = "drag"; ui_min = -5.0; ui_max = 5.0; ui_step = 0.05;
    ui_label = "Exposure (EV)";
    ui_tooltip = "Exposure in stops. With auto exposure, an offset added to the metered exposure.";
> = 0.0;

uniform bool AutoExposure <
    ui_category = "Auto exposure";
    ui_label = "Enable auto exposure";
    ui_tooltip = "Meters the scene and exposes it towards the target brightness, with a smooth adaptation.";
> = false;

uniform float AutoTarget <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = 0.02; ui_max = 0.5; ui_step = 0.005;
    ui_label = "Target brightness";
    ui_tooltip = "Linear display brightness the scene average is exposed to (0.18 = middle grey).\n"
                 "In HDR it is relative to the paper white.";
> = 0.18;

uniform float AutoAmount <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Adaptation amount";
    ui_tooltip = "1 = full correction towards the target, 0.5 = half of it (keeps some of the scene's mood).";
> = 0.7;

uniform float2 AutoRange <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = -6.0; ui_max = 6.0; ui_step = 0.1;
    ui_label = "Auto exposure min / max (EV)";
    ui_tooltip = "Limits of the metered correction, in stops.";
> = float2(-2.0, 3.0);

uniform float2 AutoSpeed <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = 0.05; ui_max = 10.0; ui_step = 0.05;
    ui_label = "Adaptation speed to bright / to dark";
    ui_tooltip = "How fast the exposure follows the scene when it gets brighter / darker.\n"
                 "Eyes adapt to darkness more slowly.";
> = float2(2.0, 1.0);

uniform float AutoCentre <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Centre weighting";
    ui_tooltip = "0 = whole frame counts equally, 1 = the edges are ignored.";
> = 0.6;

uniform int ToneCurve <
    ui_category = "Tone curve";
    ui_type = "combo";
    ui_items = "Linear (clip)\0Reinhard\0Hable (Uncharted 2)\0ACES (Hill fit)\0AgX\0Khronos PBR Neutral\0";
    ui_label = "Tone curve";
    ui_tooltip = "Curve used to compress the exposed image back to the display.\n"
                 "With the default expansion it is also used, inverted, to expand the input,\n"
                 "so it shapes how highlights and shadows respond to the exposure.";
> = 1;

uniform int ColourMode <
    ui_category = "Tone curve";
    ui_type = "combo";
    ui_items = "Per channel\0Luminance (keeps saturation)\0Max channel (keeps hue)\0";
    ui_label = "Colour handling";
    ui_tooltip = "Linear, Reinhard and Hable only.\n"
                 "Per channel: bright colours drift towards white and their hue can shift (orange -> yellow).\n"
                 "Luminance: hue and saturation are kept; colours that overflow are desaturated just enough.\n"
                 "Max channel: hue and saturation are kept, bright saturated colours never reach white.";
> = 0;

uniform float Headroom <
    ui_category = "Tone curve";
    ui_type = "drag"; ui_min = 0.0; ui_max = 8.0; ui_step = 0.05;
    ui_label = "Highlight headroom (stops)";
    ui_tooltip = "Scene brightness, in stops above 1.0, that the curve maps to display white.\n"
                 "Higher: near-white highlights are expanded more, so they stay bright when you lower the\n"
                 "exposure and roll off more softly when you raise it. Lower: they behave more like the input.\n"
                 "AgX tops out at about 4 stops.";
> = 4.0;

uniform float Crosstalk <
    ui_category = "Tone curve";
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.6; ui_step = 0.01;
    ui_label = "Channel crosstalk";
    ui_tooltip = "0 = off. Mixes the channels before expansion and unmixes them after compression,\n"
                 "so pushed saturated highlights desaturate towards white instead of clipping per channel.\n"
                 "Mostly useful with per-channel curves; ACES and AgX already have their own matrices.";
> = 0.3;

uniform int ExpansionMode <
    ui_category = "Expansion";
    ui_type = "combo";
    ui_items = "Inverse of the tone curve (0 EV = unchanged)\0Inverse of another curve (re-tonemap)\0None (input is already scene-linear)\0";
    ui_label = "Expansion";
    ui_tooltip = "How the input is turned into scene light before the exposure.\n"
                 "Inverse of the tone curve: 0 EV returns the original image.\n"
                 "Inverse of another curve: expands with the curve below, compresses with the tone curve.\n"
                 "None: for linear buffers that were not tone mapped yet (e.g. with REST).";
> = 0;

uniform int ExpansionCurve <
    ui_category = "Expansion";
    ui_type = "combo";
    ui_items = "Linear (clip)\0Reinhard\0Hable (Uncharted 2)\0ACES (Hill fit)\0AgX\0Khronos PBR Neutral\0";
    ui_label = "Expansion curve";
    ui_tooltip = "Only for 'Inverse of another curve'. Best set to the curve the game itself seems to use.";
> = 1;

#if EXPOSE_HDR
uniform float PeakNits <
    ui_category = "Display";
    ui_type = "drag"; ui_min = 200.0; ui_max = 10000.0; ui_step = 10.0;
    ui_label = "Peak brightness (nits)";
    ui_tooltip = "Brightest value of the game's HDR output. It becomes the curve's white;\n"
                 "anything brighter in the input is clipped to it.";
> = 1000.0;

uniform float PaperWhiteNits <
    ui_category = "Display";
    ui_type = "drag"; ui_min = 80.0; ui_max = 500.0; ui_step = 1.0;
    ui_label = "Paper white (nits)";
    ui_tooltip = "Only used to place the auto exposure target.";
> = 203.0;
#else
uniform float SdrGamma <
    ui_category = "Display";
    ui_type = "drag"; ui_min = 1.8; ui_max = 2.6; ui_step = 0.01;
    ui_label = "SDR gamma";
    ui_tooltip = "Power gamma used to decode and re-encode the SDR image.";
> = 2.2;
#endif

uniform bool Dither <
    ui_category = "Display";
    ui_label = "Dither";
    ui_tooltip = "Adds noise below one code value to avoid banding in smooth gradients. No effect in scRGB.";
> = true;

uniform float FrameTime < source = "frametime"; >;
uniform int FrameCount < source = "framecount"; >;

// --- Colour spaces -------------------------------------------------------------------------------

static const float3x3 BT709_TO_BT2020 = float3x3(
    0.6274040, 0.3292820, 0.0433136,
    0.0690970, 0.9195400, 0.0113612,
    0.0163916, 0.0880132, 0.8955950);

static const float3x3 BT2020_TO_BT709 = float3x3(
     1.6604910, -0.5876411, -0.0728499,
    -0.1245505,  1.1328999, -0.0083494,
    -0.0181508, -0.1005789,  1.1187297);

#if EXPOSE_HDR
static const float3 LUMA = float3(0.2627, 0.6780, 0.0593); // working space: linear BT.2020
#else
static const float3 LUMA = float3(0.2126, 0.7152, 0.0722); // working space: linear BT.709
#endif

static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

float3 PqToLinear(float3 e)
{
    float3 p = pow(saturate(e), rcp(PQ_M2));
    return pow(max(p - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * p), rcp(PQ_M1));
}

float3 LinearToPq(float3 l)
{
    float3 y = pow(max(l, 0.0), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0 + PQ_C3 * y), PQ_M2);
}

// Back buffer -> linear working space, 1.0 = display white (SDR) or peak brightness (HDR).
float3 Decode(float3 c)
{
#if (ANDARAEL_EXPOSE_COLOUR_SPACE == 2)
    return mul(BT709_TO_BT2020, c * (80.0 / PeakNits));
#elif (ANDARAEL_EXPOSE_COLOUR_SPACE == 3)
    return PqToLinear(c) * (10000.0 / PeakNits);
#else
    return pow(saturate(c), SdrGamma);
#endif
}

float3 Encode(float3 c)
{
    c = saturate(c);
#if (ANDARAEL_EXPOSE_COLOUR_SPACE == 2)
    return mul(BT2020_TO_BT709, c) * (PeakNits / 80.0);
#elif (ANDARAEL_EXPOSE_COLOUR_SPACE == 3)
    return LinearToPq(c * (PeakNits / 10000.0));
#else
    return pow(c, rcp(SdrGamma));
#endif
}

float3 WorkingToBT709(float3 c)
{
#if EXPOSE_HDR
    return mul(BT2020_TO_BT709, c);
#else
    return c;
#endif
}

float3 BT709ToWorking(float3 c)
{
#if EXPOSE_HDR
    return mul(BT709_TO_BT2020, c);
#else
    return c;
#endif
}

float3 WorkingToBT2020(float3 c)
{
#if EXPOSE_HDR
    return c;
#else
    return mul(BT709_TO_BT2020, c);
#endif
}

float3 BT2020ToWorking(float3 c)
{
#if EXPOSE_HDR
    return c;
#else
    return mul(BT2020_TO_BT709, c);
#endif
}

// --- Curve helpers -------------------------------------------------------------------------------

#define CURVE_LINEAR   0
#define CURVE_REINHARD 1
#define CURVE_HABLE    2
#define CURVE_ACES     3
#define CURVE_AGX      4
#define CURVE_NEUTRAL  5

// Positive root of a x^2 + b x + c = 0 with a < 0 <= c, without cancellation.
float3 PositiveRoot(float3 a, float3 b, float3 c)
{
    float3 s = sqrt(max(b * b - 4.0 * a * c, 0.0));
    float3 r_pos = (b + s) / (-2.0 * a);
    float3 r_neg = 2.0 * c / max(s - b, 1e-12);
    return (b >= 0.0) ? r_pos : r_neg;
}

float WhitePoint()
{
    return exp2(Headroom);
}

// Reinhard
float3 ReinhardFwd(float3 x) { return x / (1.0 + x); }
float3 ReinhardInv(float3 y) { return y / (1.0 - y); }

// Hable / Uncharted 2
static const float HA = 0.15, HB = 0.50, HC = 0.10, HD = 0.20, HE = 0.02, HF = 0.30;

float3 HableFwd(float3 x)
{
    return (x * (HA * x + HC * HB) + HD * HE) / (x * (HA * x + HB) + HD * HF) - HE / HF;
}

float3 HableInv(float3 y)
{
    float3 t = y + HE / HF;
    return PositiveRoot(HA * (t - 1.0), HB * (t - HC), HD * (HF * t - HE));
}

// ACES (Stephen Hill's fit). Matrices are for mul(M, v) on linear BT.709.
static const float3x3 ACES_IN = float3x3(
    0.59719, 0.35458, 0.04823,
    0.07600, 0.90834, 0.01566,
    0.02840, 0.13383, 0.83777);

static const float3x3 ACES_IN_INV = float3x3(
     1.764740972, -0.675777678, -0.088963294,
    -0.147027852,  1.160251512, -0.013223660,
    -0.036336830, -0.162436437,  1.198773267);

static const float3x3 ACES_OUT = float3x3(
     1.60475, -0.53108, -0.07367,
    -0.10208,  1.10813, -0.00605,
    -0.00327, -0.07276,  1.07602);

static const float3x3 ACES_OUT_INV = float3x3(
    0.643038249, 0.311186752, 0.045775457,
    0.059268690, 0.931436487, 0.009294916,
    0.005961901, 0.063929016, 0.930118384);

float3 AcesFit(float3 v)
{
    return (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081);
}

float3 AcesFitInv(float3 y)
{
    // The fit reaches 1/0.983729 at infinity; stay just below it.
    y = clamp(y, AcesFit(0.0).x, 1.0165);
    return PositiveRoot(0.983729 * y - 1.0, 0.4329510 * y - 0.0245786, 0.238081 * y + 0.000090537);
}

float3 AcesFwd(float3 x) { return BT709ToWorking(mul(ACES_OUT, AcesFit(mul(ACES_IN, WorkingToBT709(x))))); }
float3 AcesInv(float3 y) { return BT709ToWorking(mul(ACES_IN_INV, AcesFitInv(mul(ACES_OUT_INV, WorkingToBT709(y))))); }

// AgX. Matrices are for mul(M, v) on linear BT.2020.
static const float3x3 AGX_INSET = float3x3(
    0.856627153, 0.095121241, 0.048251606,
    0.137318973, 0.761241991, 0.101439036,
    0.111898213, 0.076799419, 0.811302368);

static const float3x3 AGX_INSET_INV = float3x3(
     1.197441077, -0.144261513, -0.053179564,
    -0.196474626,  1.354095132, -0.157620505,
    -0.146557417, -0.108284059,  1.254841476);

static const float3x3 AGX_OUTSET = float3x3(
     1.127100582, -0.110606643, -0.016493939,
    -0.141329763,  1.157823702, -0.016493939,
    -0.141329763, -0.110606643,  1.251936407);

static const float3x3 AGX_OUTSET_INV = float3x3(
    0.899796956, 0.087199619, 0.013003425,
    0.111420989, 0.875575586, 0.013003425,
    0.111420989, 0.087199619, 0.801379392);

static const float AGX_MIN_EV = -12.47393;
static const float AGX_MAX_EV = 4.026069;

float3 AgxPoly(float3 x)
{
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}

// The polynomial is strictly increasing on [0, 1]: bisection, then two Newton steps.
float3 AgxPolyInv(float3 y)
{
    y = clamp(y, AgxPoly(0.0).x, AgxPoly(1.0).x);
    float3 lo = 0.0;
    float3 hi = 1.0;
    [unroll] for (int i = 0; i < 16; i++)
    {
        float3 m = 0.5 * (lo + hi);
        float3 below = step(AgxPoly(m), y);
        lo = lerp(lo, m, below);
        hi = lerp(m, hi, below);
    }
    float3 x = 0.5 * (lo + hi);
    [unroll] for (int j = 0; j < 2; j++)
    {
        float3 x2 = x * x;
        float3 x4 = x2 * x2;
        float3 d = 93.0 * x4 * x - 200.7 * x4 + 127.84 * x2 * x - 20.604 * x2 + 0.8596 * x + 0.1191;
        x = saturate(x - (AgxPoly(x) - y) / max(d, 1e-4));
    }
    return x;
}

float3 AgxFwd(float3 x)
{
    float3 v = mul(AGX_INSET, WorkingToBT2020(x));
    v = saturate((log2(max(v, 1e-10)) - AGX_MIN_EV) / (AGX_MAX_EV - AGX_MIN_EV));
    v = mul(AGX_OUTSET, AgxPoly(v));
    return BT2020ToWorking(pow(max(v, 0.0), 2.2));
}

float3 AgxInv(float3 y)
{
    float3 v = mul(AGX_OUTSET_INV, pow(max(WorkingToBT2020(y), 0.0), rcp(2.2)));
    v = exp2(AgxPolyInv(v) * (AGX_MAX_EV - AGX_MIN_EV) + AGX_MIN_EV);
    return BT2020ToWorking(mul(AGX_INSET_INV, v));
}

// Khronos PBR Neutral, split so the invertible part can be undone.
static const float NEUTRAL_START = 0.76;
static const float NEUTRAL_D = 0.24;
static const float NEUTRAL_DESAT = 0.15;

// Desaturation weight Neutral would apply to x.
float NeutralDesat(float3 x)
{
    float m = min(x.r, min(x.g, x.b));
    float offset = (m < 0.08) ? m - 6.25 * m * m : 0.04;
    float peak = max(x.r, max(x.g, x.b)) - offset;
    if (peak < NEUTRAL_START)
        return 0.0;
    float new_peak = 1.0 - NEUTRAL_D * NEUTRAL_D / (peak + NEUTRAL_D - NEUTRAL_START);
    return 1.0 - rcp(NEUTRAL_DESAT * (peak - new_peak) + 1.0);
}

// desat_sub is subtracted from the desaturation weight (see header).
float3 NeutralFwd(float3 x, float desat_sub)
{
    float m = min(x.r, min(x.g, x.b));
    x -= (m < 0.08) ? m - 6.25 * m * m : 0.04;
    float peak = max(x.r, max(x.g, x.b));
    if (peak < NEUTRAL_START)
        return x;
    float new_peak = 1.0 - NEUTRAL_D * NEUTRAL_D / (peak + NEUTRAL_D - NEUTRAL_START);
    x *= new_peak / peak;
    float g = max(1.0 - rcp(NEUTRAL_DESAT * (peak - new_peak) + 1.0) - desat_sub, 0.0);
    return lerp(x, new_peak, g);
}

// Inverse of NeutralFwd without its desaturation.
float3 NeutralInv(float3 y)
{
    float new_peak = max(y.r, max(y.g, y.b));
    if (new_peak >= NEUTRAL_START)
    {
        float peak = NEUTRAL_D * NEUTRAL_D / (1.0 - new_peak) - NEUTRAL_D + NEUTRAL_START;
        y *= peak / new_peak;
    }
    float m = max(min(y.r, min(y.g, y.b)), 0.0);
    float x = (m < 0.04) ? sqrt(m / 6.25) : m + 0.04;
    return y + (x - m);
}

// Grey value each curve gives to the white point, used to map the white point to 1.
float CurveWhite(int id)
{
    float w = WhitePoint();
    if (id == CURVE_REINHARD) return ReinhardFwd(w).x;
    if (id == CURVE_HABLE)    return HableFwd(w).x;
    if (id == CURVE_ACES)     return AcesFit(w).x;
    if (id == CURVE_AGX)
    {
        float u = saturate((log2(w) - AGX_MIN_EV) / (AGX_MAX_EV - AGX_MIN_EV));
        return pow(AgxPoly(u).x, 2.2);
    }
    if (id == CURVE_NEUTRAL)  return NeutralFwd(w, 0.0).x;
    return 1.0;
}

// Scalar curves (Linear, Reinhard, Hable), normalised so the white point maps to 1.
float3 ScalarFwd(int id, float3 x, float white)
{
    if (id == CURVE_REINHARD) return ReinhardFwd(x) / white;
    if (id == CURVE_HABLE)    return HableFwd(x) / white;
    return min(x, 1.0);
}

float3 ScalarInv(int id, float3 y, float white)
{
    y = min(y, 1.0) * white;
    if (id == CURVE_REINHARD) return ReinhardInv(y);
    if (id == CURVE_HABLE)    return HableInv(y);
    return y;
}

// --- Tone curve with colour handling, white point -> 1 ----------------------------------------

float3 CurveFwd(int id, float3 x, float desat_sub)
{
    float white = CurveWhite(id);
    if (id == CURVE_ACES)    return AcesFwd(x) / white;
    if (id == CURVE_AGX)     return AgxFwd(x) / white;
    if (id == CURVE_NEUTRAL) return NeutralFwd(x, desat_sub) / white;

    if (ColourMode == 1)
    {
        float y = dot(x, LUMA);
        if (y <= 0.0)
            return 0.0;
        float y_out = ScalarFwd(id, y, white).x;
        float3 c = x * (y_out / y);
        // Out of range: desaturate towards the target luminance until the max channel is 1.
        y_out = min(y_out, 1.0);
        float mx = max(c.r, max(c.g, c.b));
        if (mx > 1.0)
            c = y_out + (c - y_out) * (1.0 - y_out) / max(mx - y_out, 1e-6);
        return c;
    }
    if (ColourMode == 2)
    {
        float mx = max(x.r, max(x.g, x.b));
        return (mx > 0.0) ? x * (ScalarFwd(id, mx, white).x / mx) : 0.0;
    }
    return ScalarFwd(id, x, white);
}

float3 CurveInv(int id, float3 y)
{
    float white = CurveWhite(id);
    y = saturate(y);
    if (id == CURVE_ACES)    return AcesInv(y * white);
    if (id == CURVE_AGX)     return AgxInv(y * white);
    if (id == CURVE_NEUTRAL) return NeutralInv(y * white);

    if (ColourMode == 1)
    {
        float l = dot(y, LUMA);
        return (l > 0.0) ? y * (ScalarInv(id, l, white).x / l) : 0.0;
    }
    if (ColourMode == 2)
    {
        float mx = max(y.r, max(y.g, y.b));
        return (mx > 0.0) ? y * (ScalarInv(id, mx, white).x / mx) : 0.0;
    }
    return ScalarInv(id, y, white);
}

// --- Pipeline pieces ----------------------------------------------------------------------------

float3 CrosstalkMix(float3 c)
{
    return lerp(c, dot(c, 1.0 / 3.0), Crosstalk);
}

float3 CrosstalkUnmix(float3 c)
{
    return (c - Crosstalk * dot(c, 1.0 / 3.0)) / (1.0 - Crosstalk);
}

int ExpansionCurveId()
{
    return (ExpansionMode == 1) ? ExpansionCurve : ToneCurve;
}

// Linear working-space input -> scene light.
float3 Expand(float3 c)
{
    if (ExpansionMode == 2)
        return max(c, 0.0);
    return CurveInv(ExpansionCurveId(), CrosstalkMix(c));
}

// Scene light -> linear working-space output. scene_ref is the unexposed scene value.
float3 Compress(float3 x, float3 scene_ref)
{
    float desat_sub = 0.0;
    if (ToneCurve == CURVE_NEUTRAL && ExpansionMode != 2 && ExpansionCurveId() == CURVE_NEUTRAL)
        desat_sub = NeutralDesat(scene_ref);
    float3 c = CurveFwd(ToneCurve, x, desat_sub);
    return (ExpansionMode == 2) ? c : CrosstalkUnmix(c);
}

// --- Auto exposure -----------------------------------------------------------------------------

#define METER_SIZE 256
#define METER_MIPS 9

texture2D ExposeMeterTex { Width = METER_SIZE; Height = METER_SIZE; Format = RG16F; MipLevels = METER_MIPS; };
sampler2D sExposeMeter { Texture = ExposeMeterTex; };

// Adapted log2 luminance of the scene: this frame / previous frame.
texture2D ExposeAdaptCur  { Width = 1; Height = 1; Format = R32F; };
texture2D ExposeAdaptPrev { Width = 1; Height = 1; Format = R32F; };
sampler2D sExposeAdaptCur  { Texture = ExposeAdaptCur;  MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
sampler2D sExposeAdaptPrev { Texture = ExposeAdaptPrev; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

sampler2D sBackPoint { Texture = ReShade::BackBufferTex; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

float ExposureScale()
{
    float ev = ExposureEV;
    if (AutoExposure)
    {
#if EXPOSE_HDR
        float target = AutoTarget * PaperWhiteNits / PeakNits;
#else
        float target = AutoTarget;
#endif
        // Target expressed in scene light, through the same expansion as the image.
        float target_log = log2(max(dot(Expand(target), LUMA), 1e-6));
        float scene_log = tex2Dfetch(sExposeAdaptCur, int2(0, 0)).r;
        ev += clamp(target_log - scene_log, AutoRange.x, AutoRange.y) * AutoAmount;
    }
    return exp2(ev);
}

// Weighted log2 luminance of the expanded scene, averaged down the mip chain.
float2 PS_Meter(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!AutoExposure)
        return 0.0;
    float3 c = Expand(Decode(tex2Dlod(sBackPoint, float4(uv, 0, 0)).rgb));
    float l = log2(max(dot(c, LUMA), 1e-6));
    float2 d = uv - 0.5;
    float w = 1.0 - AutoCentre * saturate(dot(d, d) * 4.0);
    return float2(l * w, w);
}

float PS_Adapt(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!AutoExposure)
        return 0.0;
    float2 s = tex2Dlod(sExposeMeter, float4(0.5, 0.5, 0, METER_MIPS - 1)).rg;
    float cur = s.x / max(s.y, 1e-6);

    float prev = tex2Dfetch(sExposeAdaptPrev, int2(0, 0)).r;
    if (prev == 0.0 || !(abs(prev) < 1e6)) // first frame / garbage
        return cur;
    float speed = (cur > prev) ? AutoSpeed.x : AutoSpeed.y;
    float k = 1.0 - exp(-max(FrameTime, 0.0) * 0.001 * speed);
    return lerp(prev, cur, saturate(k));
}

float PS_StoreAdapt(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dfetch(sExposeAdaptCur, int2(0, 0)).r;
}

// --- Main ---------------------------------------------------------------------------------------

float3 TriangularNoise(float2 pos)
{
    float2 p = pos + float(FrameCount % 64) * float2(37.0, 17.0);
    float3 a = frac(sin(dot(p, float2(12.9898, 78.233)) + float3(0.0, 1.7, 3.1)) * 43758.5453);
    float3 b = frac(sin(dot(p, float2(39.3468, 11.135)) + float3(0.0, 1.7, 3.1)) * 24634.6345);
    return a - b; // in (-1, 1), triangular
}

float4 PS_Expose(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 src = tex2Dfetch(sBackPoint, int2(pos.xy));

    float3 scene = Expand(Decode(src.rgb));
    float3 c = Encode(Compress(scene * ExposureScale(), scene));

#if (ANDARAEL_EXPOSE_COLOUR_SPACE != 2)
    if (Dither)
        c += TriangularNoise(pos.xy) / (exp2(BUFFER_COLOR_BIT_DEPTH) - 1.0);
#endif
    return float4(c, src.a);
}

technique Andarael_Expose <
    ui_label = "Andarael Expose";
    ui_tooltip = "Exposure in a reconstructed HDR space, with selectable tone curves.\n"
                 "With the default expansion, 0 EV leaves the image unchanged.";
>
{
    pass Meter      { VertexShader = PostProcessVS; PixelShader = PS_Meter;      RenderTarget = ExposeMeterTex; }
    pass Adapt      { VertexShader = PostProcessVS; PixelShader = PS_Adapt;      RenderTarget = ExposeAdaptCur; }
    pass StoreAdapt { VertexShader = PostProcessVS; PixelShader = PS_StoreAdapt; RenderTarget = ExposeAdaptPrev; }
    pass Expose     { VertexShader = PostProcessVS; PixelShader = PS_Expose; }
}
