/*
    Andarael_ToneCurves.fxh: tone curves and their inverses, shared by Andarael_Expose and ExposureBracket.

    Every curve maps scene light to display light in [0, 1], with a chosen white point (the scene light
    that reaches 1), and has an exact inverse:
      - Linear: no compression, clips at the white point.
      - Reinhard: x / (1 + x), long soft shoulder.
      - AgX: Troy Sobotka's AgX, log2 encoding + sigmoid between inset/outset matrices.
      - Hable: John Hable's Uncharted 2 filmic curve, with a toe.
      - ACES: Stephen Hill's fit of the ACES RRT + ODT (sRGB output), with its gamut matrices.
    Linear, Reinhard and Hable can run per channel, on luminance or on the max channel; ACES and AgX have
    their own colour handling. Also: channel crosstalk (mix towards the channel average and back) and the
    sRGB transfer functions.

    The white point is given as headroom: stops above 1.0, so white = 2^headroom.

    Working space: linear BT.709 by default. Define TONECURVES_WORKING_BT2020 to 1 before including this
    file to work in linear BT.2020; ACES and AgX convert to and from their own primaries.

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

#pragma once

#ifndef TONECURVES_WORKING_BT2020
    #define TONECURVES_WORKING_BT2020 0
#endif

// Curve ids, same order as the menus.
#define CURVE_LINEAR   0
#define CURVE_REINHARD 1
#define CURVE_AGX      2
#define CURVE_HABLE    3
#define CURVE_ACES     4

// Colour handling of Linear, Reinhard and Hable.
#define COLOUR_PER_CHANNEL 0
#define COLOUR_LUMINANCE   1
#define COLOUR_MAX_CHANNEL 2

namespace ToneCurves
{

// --- Colour spaces -------------------------------------------------------------------------------

static const float3x3 BT709_TO_BT2020 = float3x3(
    0.6274040, 0.3292820, 0.0433136,
    0.0690970, 0.9195400, 0.0113612,
    0.0163916, 0.0880132, 0.8955950);

static const float3x3 BT2020_TO_BT709 = float3x3(
     1.6604910, -0.5876411, -0.0728499,
    -0.1245505,  1.1328999, -0.0083494,
    -0.0181508, -0.1005789,  1.1187297);

#if TONECURVES_WORKING_BT2020
static const float3 LUMA = float3(0.2627, 0.6780, 0.0593); // working space: linear BT.2020
#else
static const float3 LUMA = float3(0.2126, 0.7152, 0.0722); // working space: linear BT.709
#endif

float3 WorkingToBT709(float3 c)
{
#if TONECURVES_WORKING_BT2020
    return mul(BT2020_TO_BT709, c);
#else
    return c;
#endif
}

float3 BT709ToWorking(float3 c)
{
#if TONECURVES_WORKING_BT2020
    return mul(BT709_TO_BT2020, c);
#else
    return c;
#endif
}

float3 WorkingToBT2020(float3 c)
{
#if TONECURVES_WORKING_BT2020
    return c;
#else
    return mul(BT709_TO_BT2020, c);
#endif
}

float3 BT2020ToWorking(float3 c)
{
#if TONECURVES_WORKING_BT2020
    return c;
#else
    return mul(BT2020_TO_BT709, c);
#endif
}

// sRGB transfer functions (IEC 61966-2-1).
float3 SrgbToLinear(float3 v)
{
    return (v <= 0.04045) ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

float3 LinearToSrgb(float3 l)
{
    return (l <= 0.0031308) ? l * 12.92 : 1.055 * pow(l, rcp(2.4)) - 0.055;
}

// --- Curve helpers -------------------------------------------------------------------------------

// Positive root of a x^2 + b x + c = 0 with a < 0 <= c, without cancellation.
float3 PositiveRoot(float3 a, float3 b, float3 c)
{
    float3 s = sqrt(max(b * b - 4.0 * a * c, 0.0));
    float3 r_pos = (b + s) / (-2.0 * a);
    float3 r_neg = 2.0 * c / max(s - b, 1e-12);
    return (b >= 0.0) ? r_pos : r_neg;
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

// Top of the log range: AgX's own, or the headroom when it is higher.
float AgxMaxEv(float headroom)
{
    return max(headroom, AGX_MAX_EV);
}

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

float3 AgxFwd(float3 x, float headroom)
{
    float3 v = mul(AGX_INSET, WorkingToBT2020(x));
    v = saturate((log2(max(v, 1e-10)) - AGX_MIN_EV) / (AgxMaxEv(headroom) - AGX_MIN_EV));
    v = mul(AGX_OUTSET, AgxPoly(v));
    return BT2020ToWorking(pow(max(v, 0.0), 2.2));
}

float3 AgxInv(float3 y, float headroom)
{
    float3 v = mul(AGX_OUTSET_INV, pow(max(WorkingToBT2020(y), 0.0), rcp(2.2)));
    v = exp2(AgxPolyInv(v) * (AgxMaxEv(headroom) - AGX_MIN_EV) + AGX_MIN_EV);
    return BT2020ToWorking(mul(AGX_INSET_INV, v));
}

// Grey value each curve gives to the white point, used to map the white point to 1.
float CurveWhite(int id, float headroom)
{
    float w = exp2(headroom);
    if (id == CURVE_REINHARD) return ReinhardFwd(w).x;
    if (id == CURVE_HABLE)    return HableFwd(w).x;
    if (id == CURVE_ACES)     return AcesFit(w).x;
    if (id == CURVE_AGX)
    {
        float u = saturate((log2(w) - AGX_MIN_EV) / (AgxMaxEv(headroom) - AGX_MIN_EV));
        return pow(AgxPoly(u).x, 2.2);
    }
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

// Scene light -> display light in [0, 1].
float3 Forward(int id, float3 x, float headroom, int colour_mode)
{
    float white = CurveWhite(id, headroom);
    if (id == CURVE_ACES)    return AcesFwd(x) / white;
    if (id == CURVE_AGX)     return AgxFwd(x, headroom) / white;

    if (colour_mode == COLOUR_LUMINANCE)
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
    if (colour_mode == COLOUR_MAX_CHANNEL)
    {
        float mx = max(x.r, max(x.g, x.b));
        return (mx > 0.0) ? x * (ScalarFwd(id, mx, white).x / mx) : 0.0;
    }
    return ScalarFwd(id, x, white);
}

// Display light in [0, 1] -> scene light.
float3 Inverse(int id, float3 y, float headroom, int colour_mode)
{
    float white = CurveWhite(id, headroom);
    y = saturate(y);
    if (id == CURVE_ACES)    return AcesInv(y * white);
    if (id == CURVE_AGX)     return AgxInv(y * white, headroom);

    if (colour_mode == COLOUR_LUMINANCE)
    {
        float l = dot(y, LUMA);
        return (l > 0.0) ? y * (ScalarInv(id, l, white).x / l) : 0.0;
    }
    if (colour_mode == COLOUR_MAX_CHANNEL)
    {
        float mx = max(y.r, max(y.g, y.b));
        return (mx > 0.0) ? y * (ScalarInv(id, mx, white).x / mx) : 0.0;
    }
    return ScalarInv(id, y, white);
}

// Scene light a curve maps to display black. Not 0 for AgX (its log encoding starts at 2^AGX_MIN_EV)
// nor ACES (the fit crosses 0 at about 0.003): add it before Forward and subtract it after Inverse
// so that black stays at 0, otherwise an exposure would scale that floor and lift the blacks.
float3 Black(int id, float headroom)
{
    return (id == CURVE_AGX || id == CURVE_ACES) ? Inverse(id, 0.0, headroom, COLOUR_PER_CHANNEL) : 0.0;
}

// --- Channel crosstalk -------------------------------------------------------------------------

float3 CrosstalkMix(float3 c, float amount)
{
    return lerp(c, dot(c, 1.0 / 3.0), amount);
}

float3 CrosstalkUnmix(float3 c, float amount)
{
    return (c - amount * dot(c, 1.0 / 3.0)) / (1.0 - amount);
}

} // namespace ToneCurves
