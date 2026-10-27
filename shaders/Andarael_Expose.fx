/*
    Andarael_Expose: exposure control in a reconstructed HDR space, with a choice of tone curves.

    The displayed image is already tone mapped. To change its exposure without clipping or flattening
    the highlights, the shader:
      1. decodes the frame to linear light (SDR: with the viewing curve, scRGB or HDR10),
      2. expands it with the inverse of a tone curve, so highlights near white get their range back,
      3. multiplies by the exposure (manual, plus optional auto exposure),
      4. compresses it with the tone curve and encodes it again (SDR: with the game's curve).
    When steps 2 and 4 use the same curve, 0 EV gives back the original image: the curve only decides
    how highlights and shadows respond when the exposure moves. Expanding with one curve and compressing
    with another re-tonemaps the image (the look changes even at 0 EV).

    Tone curves:
      - Linear: no compression, pushed highlights clip.
      - Reinhard: x / (1 + x), long soft shoulder.
      - AgX (default): Troy Sobotka's AgX, log2 encoding + sigmoid between inset/outset matrices.
        Highlights travel smoothly towards white without the hue skews of per-channel curves.
      - Hable: John Hable's Uncharted 2 filmic curve, with a toe.
      - ACES: Stephen Hill's fit of the ACES RRT + ODT (sRGB output), more contrast, gamut matrices.
    Linear, Reinhard and Hable can run per channel, on luminance or on the max channel.
    The other curves have their own colour handling.

    Channel crosstalk mixes each channel towards the channel average before expansion and undoes it after
    compression. Saturated highlights then desaturate towards white when pushed, as on film, instead of
    clipping per channel.

    SDR curves: the game encodes its image with the game curve (also the monitor's); the viewing curve
    is how you want to see it. The frame is decoded with the viewing curve, so the exposure works on the
    light you actually see, and encoded with the game curve for the monitor. Both the same: unchanged.
    Each curve is a power gamma with a linear toe offset, as in sRGB (offset 5.5%, about gamma 2.2):
    the gamma moves the whole image, the offset only the shadows. Shadow depth puts an offset on the game
    curve (+) or on the viewing curve (-). More offset on the game side deepens the shadows, raises their
    contrast and purifies dark colours, channel by channel, while the mid tones and white stay.
    It can follow the exposure, since brightening also lifts the shadows.

    The colour space is taken from ReShade (BUFFER_COLOR_SPACE). Force it with ANDARAEL_EXPOSE_COLOUR_SPACE
    (1 = SDR, 2 = scRGB, 3 = HDR10). HDR is processed in linear BT.2020 normalised to the peak brightness;
    the ACES and AgX matrices are converted to and from their own primaries (BT.709 and BT.2020).

    The idea of exposing in an inverse tone mapped space comes from Pascal Gilcher's SOLARIS.
    No code from it is used.

    Curve sources (the inverses are derived here):
      - Hable filmic curve: John Hable, "Filmic Tonemapping Operators" (2010).
      - ACES fit: Stephen Hill (@self_shadow), from MJP's Baking Lab (MIT, notice below).
      - AgX: polynomial sigmoid fit (Benjamin Wrensch), inset/outset matrices and log range,
        from three.js (MIT, notice below).

    License: MIT.

    Copyright (c) 2026 Andarael
    Copyright (c) 2016 MJP
    Copyright (c) 2010-2026 three.js authors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
    THE SOFTWARE.
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

uniform float AutoNeutral <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = 1.0; ui_max = 100.0; ui_step = 1.0; ui_format = "%.0f%%";
    ui_label = "Neutral brightness";
    ui_tooltip = "Average screen brightness that auto exposure leaves alone.\n"
                 "Darker scenes are brightened towards it, brighter scenes darkened.\n"
                 "In % of white as it looks on screen (50% = mid grey). Lower it if dark scenes get too bright.\n"
                 "In HDR it is relative to the paper white.";
> = 35.0;

uniform float AutoAmount <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Adaptation amount";
    ui_tooltip = "1 = full correction towards the neutral brightness, 0.5 = half of it (keeps some of the scene's mood).";
> = 0.7;

uniform float2 AutoRange <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = -10.0; ui_max = 10.0; ui_step = 0.1;
    ui_label = "Auto exposure min / max (EV)";
    ui_tooltip = "Limits of the metered correction, in stops.";
> = float2(-2.0, 2.0);

uniform float2 AutoSpeed <
    ui_category = "Auto exposure";
    ui_type = "drag"; ui_min = 0.01; ui_max = 50.0; ui_step = 0.05;
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
    ui_items = "Linear (clip)\0Reinhard\0AgX\0Hable (Uncharted 2)\0ACES (Hill fit)\0";
    ui_label = "Tone curve";
    ui_tooltip = "Curve used to compress the exposed image back to the display.\n"
                 "With the default expansion it is also used, inverted, to expand the input,\n"
                 "so it shapes how highlights and shadows respond to the exposure.";
> = 2;

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
    ui_type = "drag"; ui_min = 0.0; ui_max = 16.0; ui_step = 0.05;
    ui_label = "Highlight headroom (stops)";
    ui_tooltip = "Scene brightness, in stops above 1.0, that the curve maps to display white.\n"
                 "Higher: near-white highlights are expanded more, so they stay bright when you lower the\n"
                 "exposure and roll off more softly when you raise it. Lower: they behave more like the input.\n"
                 "Above 4 stops, AgX stretches its range to it (less contrast when the exposure moves).";
> = 4.0;

uniform float Crosstalk <
    ui_category = "Tone curve";
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.95; ui_step = 0.01;
    ui_label = "Channel crosstalk";
    ui_tooltip = "0 = off. Mixes the channels before expansion and unmixes them after compression,\n"
                 "so pushed saturated highlights desaturate towards white instead of clipping per channel.\n"
                 "Mostly useful with per-channel curves; ACES and AgX already have their own matrices.";
> = 0.3;

uniform int Expansion <
    ui_category = "Expansion";
    ui_type = "combo";
    ui_items = "Same as tone curve (0 EV = unchanged)\0Linear (clip)\0Reinhard\0AgX\0Hable (Uncharted 2)\0ACES (Hill fit)\0None (input is already scene-linear)\0";
    ui_label = "Expansion";
    ui_tooltip = "Curve whose inverse turns the input into scene light before the exposure.\n"
                 "Same as tone curve: 0 EV returns the original image.\n"
                 "Another curve: re-tonemaps the image (the look changes even at 0 EV).\n"
                 "Best set to the curve the game itself seems to use.\n"
                 "None: for linear buffers that were not tone mapped yet (e.g. with REST).";
> = 0;

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

// Shadow depth is SDR only.
static const float ShadowDepth = 0.0;
static const bool ShadowDepthEnabled = false;
static const float2 ShadowDepthPerEV = 0.0;
#else
uniform bool ShadowDepthEnabled <
    ui_category = "Shadow depth";
    ui_label = "Enable shadow depth";
    ui_tooltip = "Turns the whole section on or off: the depth at 0 EV and its change with the exposure.";
> = false;

uniform float ShadowDepth <
    ui_category = "Shadow depth";
    ui_type = "drag"; ui_min = -25.0; ui_max = 25.0; ui_step = 0.1; ui_format = "%+.1f%%";
    ui_label = "Shadow depth (at 0 EV)";
    ui_tooltip = "Black offset between the game curve and the viewing curve, as in sRGB (5.5%).\n"
                 "+: deeper shadows with more contrast and purer dark colours. -: lighter, flatter shadows.\n"
                 "Mid tones and white do not move. 0 = unchanged.";
> = 0.0;

uniform float2 ShadowDepthPerEV <
    ui_category = "Shadow depth";
    ui_type = "drag"; ui_min = -20.0; ui_max = 20.0; ui_step = 0.1; ui_format = "%+.1f%% per EV";
    ui_label = "Depth per EV, exposure up / down";
    ui_tooltip = "Shadow depth change for each stop of exposure (manual + auto).\n"
                 "First value: when the exposure goes up (dark scenes brightened by auto exposure).\n"
                 "Second value: when it goes down (bright scenes darkened).\n"
                 "In both: + deepens the shadows, - lightens them.\n"
                 "Example: depth 5%, +3% / -3%: +1 EV gives 8%, -1 EV gives 2%. 0 / 0: fixed depth.\n"
                 "The change never takes the depth below 0 (or below the base value if it is negative).";
> = float2(3.0, -3.0);

uniform float ViewGamma <
    ui_category = "Display";
    ui_type = "drag"; ui_min = 1.0; ui_max = 3.0; ui_step = 0.01;
    ui_label = "Viewing gamma";
    ui_tooltip = "Gamma you want to see the game with, for the whole image. White does not move.\n"
                 "Same as the game gamma (2.2): unchanged. Higher (2.4, usual for a dim room): darker and\n"
                 "more contrasted everywhere. Lower: lighter. The exposure works on the light it gives.";
> = 2.2;
#endif

uniform bool Dither <
    ui_category = "Display";
    ui_label = "Dither";
    ui_tooltip = "Adds noise below one code value to avoid banding in smooth gradients. No effect in scRGB.";
> = true;

#if !EXPOSE_HDR
uniform float SdrGamma <
    ui_category = "Advanced";
    ui_category_closed = true;
    ui_type = "drag"; ui_min = 1.0; ui_max = 3.0; ui_step = 0.01;
    ui_label = "Game gamma";
    ui_tooltip = "Gamma the game encodes its image with, which is also your monitor's: 2.2 almost always.\n"
                 "Only change it if the game or the monitor really uses another gamma.";
> = 2.2;
#endif

#if (ANDARAEL_EXPOSE_COLOUR_SPACE == 2)
    #define EXPOSE_COLOUR_SPACE_NAME "2 (scRGB)"
#elif (ANDARAEL_EXPOSE_COLOUR_SPACE == 3)
    #define EXPOSE_COLOUR_SPACE_NAME "3 (HDR10)"
#else
    #define EXPOSE_COLOUR_SPACE_NAME "1 (SDR)"
#endif

uniform int PreprocessorInfo <
    ui_category = "Preprocessor definitions";
    ui_category_closed = true;
    ui_type = "radio";
    ui_label = " ";
    ui_text = "ANDARAEL_EXPOSE_COLOUR_SPACE = " EXPOSE_COLOUR_SPACE_NAME "\n"
              "Format of the game's image: 1 = SDR, 2 = scRGB, 3 = HDR10.\n"
              "Set automatically from what ReShade detects. Only define it if the detection is wrong,\n"
              "e.g. ReShade reports SDR while the game outputs HDR.";
> = 0;

uniform float FrameTime < source = "frametime"; >;
uniform int FrameCount < source = "framecount"; >;

// --- Colour spaces and tone curves, shared with ExposureBracket ------------------------------------

#define TONECURVES_WORKING_BT2020 EXPOSE_HDR
#include "Andarael_ToneCurves.fxh"

#define BT709_TO_BT2020 ToneCurves::BT709_TO_BT2020
#define BT2020_TO_BT709 ToneCurves::BT2020_TO_BT709
#define LUMA            ToneCurves::LUMA

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

#if !EXPOSE_HDR
// SDR curves: power with a linear toe, V = (1 + a) L^(1/e) - a above the toe, V = k L below, continuous
// in value and slope (sRGB: a = 0.055, e = 2.4). e is chosen so mid grey (0.18) gets V = 0.18^(1/gamma).
// Returns 1/e, toe end in light, toe slope k.
float3 SdrCurve(float gamma, float a)
{
    float ie = log((exp2(log2(0.18) / gamma) + a) / (1.0 + a)) / log(0.18);
    float l0 = pow(a / ((1.0 + a) * (1.0 - ie)), rcp(ie));
    return float3(ie, l0, (1.0 + a) * ie * pow(max(l0, 1e-10), ie - 1.0));
}

float3 SdrEotf(float3 v, float gamma, float offset)
{
    float a = offset * 0.01;
    if (a <= 0.0)
        return pow(v, gamma);
    float3 c = SdrCurve(gamma, a);
    return (v < c.z * c.y) ? v / c.z : pow((v + a) / (1.0 + a), rcp(c.x));
}

float3 SdrOetf(float3 l, float gamma, float offset)
{
    float a = offset * 0.01;
    if (a <= 0.0)
        return pow(l, rcp(gamma));
    float3 c = SdrCurve(gamma, a);
    return (l < c.y) ? l * c.z : (1.0 + a) * pow(l, c.x) - a;
}
#endif

// Back buffer -> linear working space, 1.0 = display white (SDR) or peak brightness (HDR).
// depth: shadow depth in %, + on the game curve, - on the viewing curve.
float3 Decode(float3 c, float depth)
{
#if (ANDARAEL_EXPOSE_COLOUR_SPACE == 2)
    return mul(BT709_TO_BT2020, c * (80.0 / PeakNits));
#elif (ANDARAEL_EXPOSE_COLOUR_SPACE == 3)
    return PqToLinear(c) * (10000.0 / PeakNits);
#else
    return SdrEotf(saturate(c), ViewGamma, max(-depth, 0.0));
#endif
}

float3 Encode(float3 c, float depth)
{
    c = saturate(c);
#if (ANDARAEL_EXPOSE_COLOUR_SPACE == 2)
    return mul(BT2020_TO_BT709, c) * (PeakNits / 80.0);
#elif (ANDARAEL_EXPOSE_COLOUR_SPACE == 3)
    return LinearToPq(c * (PeakNits / 10000.0));
#else
    return SdrOetf(c, SdrGamma, max(depth, 0.0));
#endif
}

// Encode is the exact inverse of Decode.
bool SameCurves(float depth)
{
#if EXPOSE_HDR
    return true;
#else
    return ViewGamma == SdrGamma && depth == 0.0;
#endif
}

// --- Tone curve with this effect's settings ----------------------------------------------------

float3 CurveFwd(int id, float3 x) { return ToneCurves::Forward(id, x, Headroom, ColourMode); }
float3 CurveInv(int id, float3 y) { return ToneCurves::Inverse(id, y, Headroom, ColourMode); }

// --- Pipeline pieces ----------------------------------------------------------------------------

float3 CrosstalkMix(float3 c)   { return ToneCurves::CrosstalkMix(c, Crosstalk); }
float3 CrosstalkUnmix(float3 c) { return ToneCurves::CrosstalkUnmix(c, Crosstalk); }

#define EXPANSION_NONE 6

// Curve used for the expansion. Menu: 0 = same as tone curve, 1-5 = curve 0-4, 6 = none.
int ExpansionCurveId()
{
    return (Expansion == 0) ? ToneCurve : Expansion - 1;
}

// Scene light a curve maps to display black (AgX, ACES), kept at 0 through the exposure.
float3 CurveBlack(int id)
{
    return ToneCurves::Black(id, Headroom);
}

// Linear working-space input -> scene light, display black -> 0.
float3 Expand(float3 c)
{
    if (Expansion == EXPANSION_NONE)
        return max(c, 0.0);
    int id = ExpansionCurveId();
    return CurveInv(id, CrosstalkMix(c)) - CurveBlack(id);
}

// Scene light -> linear working-space output.
float3 Compress(float3 x)
{
    float3 c = CurveFwd(ToneCurve, x + CurveBlack(ToneCurve));
    return (Expansion == EXPANSION_NONE) ? c : CrosstalkUnmix(c);
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

// Exposure multiplier and shadow depth of the main pass, computed once per frame.
texture2D ExposeScale { Width = 1; Height = 1; Format = RG32F; };
sampler2D sExposeScale { Texture = ExposeScale; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

// Weighted log2 luminance of the expanded scene, averaged down the mip chain.
float2 PS_Meter(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if (!AutoExposure)
        return 0.0;
    float3 c = Expand(Decode(tex2Dlod(sBackPoint, float4(uv, 0, 0)).rgb, ShadowDepthEnabled ? ShadowDepth : 0.0));
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

float2 PS_Scale(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float ev = ExposureEV;
    if (AutoExposure)
    {
        // Neutral brightness: on-screen % -> linear.
#if EXPOSE_HDR
        float target = pow(AutoNeutral * 0.01, 2.2) * PaperWhiteNits / PeakNits;
#else
        float target = SdrEotf(AutoNeutral * 0.01, SdrGamma, ShadowDepthEnabled ? max(ShadowDepth, 0.0) : 0.0).x;
#endif
        // Target expressed in scene light, through the same expansion as the image.
        float target_log = log2(max(dot(Expand(target), LUMA), 1e-6));
        float scene_log = tex2Dfetch(sExposeAdaptCur, int2(0, 0)).r;
        ev += clamp(target_log - scene_log, AutoRange.x, AutoRange.y) * AutoAmount;
    }
    float depth = 0.0;
    if (ShadowDepthEnabled)
    {
        depth = ShadowDepth + abs(ev) * (ev > 0.0 ? ShadowDepthPerEV.x : ShadowDepthPerEV.y);
        // The exposure never turns the depth into lifted shadows (the viewing-side offset).
        depth = max(depth, min(ShadowDepth, 0.0));
    }
    return float2(exp2(ev), min(depth, 50.0));
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

    float2 scale = tex2Dfetch(sExposeScale, int2(0, 0)).rg;
    float exposure = scale.x;
    float depth = scale.y;

    // Fast path: expanding and compressing with the same curve at x1 gives back the input.
    bool same_light = Expansion != EXPANSION_NONE && ExpansionCurveId() == ToneCurve && exposure == 1.0;
    if (same_light && SameCurves(depth))
        return src;

    float3 c = Decode(src.rgb, depth);
    if (!same_light)
        c = Compress(Expand(c) * exposure);
    c = Encode(c, depth);

#if (ANDARAEL_EXPOSE_COLOUR_SPACE != 2)
    if (Dither)
        c += TriangularNoise(pos.xy) / (exp2(BUFFER_COLOR_BIT_DEPTH) - 1.0);
#endif
    return float4(c, src.a);
}

technique Andarael_Expose <
    ui_label = "Andarael Expose";
    ui_tooltip = "Exposure in a reconstructed HDR space, with selectable tone curves.\n"
                 "With the default expansion and output, 0 EV leaves the image unchanged.";
>
{
    pass Meter      { VertexShader = PostProcessVS; PixelShader = PS_Meter;      RenderTarget = ExposeMeterTex; }
    pass Adapt      { VertexShader = PostProcessVS; PixelShader = PS_Adapt;      RenderTarget = ExposeAdaptCur; }
    pass Scale      { VertexShader = PostProcessVS; PixelShader = PS_Scale;      RenderTarget = ExposeScale; }
    pass StoreAdapt { VertexShader = PostProcessVS; PixelShader = PS_StoreAdapt; RenderTarget = ExposeAdaptPrev; }
    pass Expose     { VertexShader = PostProcessVS; PixelShader = PS_Expose; }
}
