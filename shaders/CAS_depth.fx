/*
    CAS_depth: AMD FidelityFX Contrast Adaptive Sharpening (sharpen only) that fades with depth,
    so the foreground is sharpened and the background is left alone.

    Rewritten from Lilium's CAS (lilium__cas_hdr.fx, https://github.com/EndlesslyFlowering/ReShade_HDR_shaders):
    - RGB mode sharpens in linear light: SDR is decoded with a power gamma, scRGB and HDR10 are
      converted to linear BT.2020 normalised to 10000 nits.
    - Luminance mode sharpens the luminance only and scales the pixel by the result, so colours
      do not shift.
    The colour space is taken from ReShade (BUFFER_COLOR_SPACE). Force it with CAS_DEPTH_COLOUR_SPACE
    (1 = SDR, 2 = scRGB, 3 = HDR10). CAS_DEPTH_SDR_GAMMA sets the SDR decoding gamma.

    Depth: the sharpening weight is multiplied by 1 - DepthControl * d^2, d = linear depth ^ DepthLinearity.
    DepthControl = 0 skips the depth read.

    Copyright (c) 2024-2026 Andarael
    License: GPL-3.0 (see LICENSES/GPL-3.0.txt), as a derivative of Lilium's shaders.

    The CAS algorithm is part of the FidelityFX SDK:
    Copyright (C) 2023 Advanced Micro Devices, Inc.

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

#ifndef CAS_DEPTH_COLOUR_SPACE
    #if (BUFFER_COLOR_SPACE == 2)
        #define CAS_DEPTH_COLOUR_SPACE 2
    #elif (BUFFER_COLOR_SPACE == 3)
        #define CAS_DEPTH_COLOUR_SPACE 3
    #else
        #define CAS_DEPTH_COLOUR_SPACE 1
    #endif
#endif

#ifndef CAS_DEPTH_SDR_GAMMA
    #define CAS_DEPTH_SDR_GAMMA 2.2
#endif

uniform bool LuminanceMode <
    ui_label = "Luminance mode";
    ui_tooltip = "Sharpen the luminance instead of each RGB channel. Avoids colour shifts on edges.";
> = true;

uniform float SharpenAmount <
    ui_type = "drag"; ui_min = 0.0; ui_max = 0.2; ui_step = 0.001;
    ui_label = "Sharpness amount";
> = 0.1;

uniform float DepthControl <
    ui_type = "drag"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Depth control";
    ui_tooltip = "How much sharpening fades with distance. 0 = same sharpening everywhere (depth is not read).";
> = 0.7;

uniform float DepthLinearity <
    ui_type = "drag"; ui_min = 0.1; ui_max = 3.0; ui_step = 0.01;
    ui_label = "Depth linearity";
    ui_tooltip = "Exponent applied to the depth. Higher values keep the near and mid range sharp and push the fade into the distance.";
> = 2.0;

uniform bool DisplayDepthFactor <
    ui_label = "Display depth factor";
    ui_tooltip = "Shows the sharpening multiplier: white = full sharpening, black = none.";
> = false;

#define MIN3(a, b, c) min(min(a, b), c)
#define MAX3(a, b, c) max(max(a, b), c)

static const int2 MAX_POS = int2(BUFFER_WIDTH - 1, BUFFER_HEIGHT - 1);

// --- Colour space: everything is processed in a [0, 1] working range -----------------------------

static const float SCRGB_TO_NORM = 80.0 / 10000.0; // scRGB 1.0 = 80 nits, PQ 1.0 = 10000 nits

static const float3x3 BT709_TO_BT2020 = float3x3(
    0.6274040, 0.3292820, 0.0433136,
    0.0690970, 0.9195400, 0.0113612,
    0.0163916, 0.0880132, 0.8955950);

static const float3x3 BT2020_TO_BT709 = float3x3(
     1.6604910, -0.5876411, -0.0728499,
    -0.1245505,  1.1328999, -0.0083494,
    -0.0181508, -0.1005789,  1.1187297);

static const float3 BT709_Y  = float3(0.2126, 0.7152, 0.0722);
static const float3 BT2020_Y = float3(0.2627, 0.6780, 0.0593);

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

// RGB mode: back buffer -> linear working space and back.
float3 RgbToWorking(float3 c)
{
#if (CAS_DEPTH_COLOUR_SPACE == 2)
    return mul(BT709_TO_BT2020, c * SCRGB_TO_NORM);
#elif (CAS_DEPTH_COLOUR_SPACE == 3)
    return PqToLinear(c);
#else
    return pow(saturate(c), CAS_DEPTH_SDR_GAMMA);
#endif
}

float3 RgbFromWorking(float3 c)
{
#if (CAS_DEPTH_COLOUR_SPACE == 2)
    return mul(BT2020_TO_BT709, c) / SCRGB_TO_NORM;
#elif (CAS_DEPTH_COLOUR_SPACE == 3)
    return LinearToPq(c);
#else
    return pow(saturate(c), rcp(CAS_DEPTH_SDR_GAMMA));
#endif
}

// Luminance mode: like Lilium, SDR works on the encoded signal, HDR on linear light.
float3 LumModeDecode(float3 c)
{
#if (CAS_DEPTH_COLOUR_SPACE == 3)
    return PqToLinear(c);
#else
    return c;
#endif
}

float LumModeLuminance(float3 c)
{
#if (CAS_DEPTH_COLOUR_SPACE == 2)
    return dot(c, BT709_Y) * SCRGB_TO_NORM;
#elif (CAS_DEPTH_COLOUR_SPACE == 3)
    return dot(c, BT2020_Y);
#else
    return dot(c, BT709_Y);
#endif
}

float3 LumModeEncode(float3 c)
{
#if (CAS_DEPTH_COLOUR_SPACE == 3)
    return LinearToPq(c);
#else
    return c;
#endif
}

// --- CAS --------------------------------------------------------------------------------------

float3 Fetch(int2 pos, int2 offset)
{
    return tex2Dfetch(ReShade::BackBuffer, clamp(pos + offset, 0, MAX_POS)).rgb;
}

// Soft min/max over the cross plus the corners, then the CAS amplification.
//  a b c
//  d e f
//  g h i
// The sums are 2x bigger (factored out the extra multiply), hence the 2 - max.
#define CAS_AMPLIFY(T, a, b, c, d, e, f, g, h, i)               \
    T mn = MIN3(MIN3(d, e, f), b, h);                           \
    T mx = MAX3(MAX3(d, e, f), b, h);                           \
    mn += MIN3(MIN3(mn, a, c), g, i);                           \
    mx += MAX3(MAX3(mx, a, c), g, i);                           \
    T amplify = sqrt(saturate(min(mn, 2.0 - mx) * rcp(mx)));

float GetDepthFactor(float2 texcoord)
{
    if (DepthControl <= 0.0)
        return 1.0;

    float d = pow(ReShade::GetLinearizedDepth(texcoord), DepthLinearity);
    return saturate(1.0 - DepthControl * d * d);
}

float4 PS_CasDepth(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float depthFactor = GetDepthFactor(texcoord);

    if (DisplayDepthFactor)
        return float4(depthFactor.xxx, 1.0);

    int2 pos = int2(vpos.xy);

    float4 eFull = tex2Dfetch(ReShade::BackBuffer, pos);

    float3 a = Fetch(pos, int2(-1, -1));
    float3 b = Fetch(pos, int2( 0, -1));
    float3 c = Fetch(pos, int2( 1, -1));
    float3 d = Fetch(pos, int2(-1,  0));
    float3 e = eFull.rgb;
    float3 f = Fetch(pos, int2( 1,  0));
    float3 g = Fetch(pos, int2(-1,  1));
    float3 h = Fetch(pos, int2( 0,  1));
    float3 i = Fetch(pos, int2( 1,  1));

    float peak = -SharpenAmount * depthFactor;

    float3 output;

    [branch]
    if (LuminanceMode)
    {
        e = LumModeDecode(e);

        float aL = LumModeLuminance(LumModeDecode(a));
        float bL = LumModeLuminance(LumModeDecode(b));
        float cL = LumModeLuminance(LumModeDecode(c));
        float dL = LumModeLuminance(LumModeDecode(d));
        float eL = LumModeLuminance(e);
        float fL = LumModeLuminance(LumModeDecode(f));
        float gL = LumModeLuminance(LumModeDecode(g));
        float hL = LumModeLuminance(LumModeDecode(h));
        float iL = LumModeLuminance(LumModeDecode(i));

        CAS_AMPLIFY(float, aL, bL, cL, dL, eL, fL, gL, hL, iL)

        // Filter shape:
        //  0 w 0
        //  w 1 w
        //  0 w 0
        float w = amplify * peak;
        float outL = ((bL + dL + fL + hL) * w + eL) * rcp(4.0 * w + 1.0);

        output = LumModeEncode(max(outL / max(eL, 1e-7), 0.0) * e);
    }
    else
    {
        a = RgbToWorking(a); b = RgbToWorking(b); c = RgbToWorking(c);
        d = RgbToWorking(d); e = RgbToWorking(e); f = RgbToWorking(f);
        g = RgbToWorking(g); h = RgbToWorking(h); i = RgbToWorking(i);

        CAS_AMPLIFY(float3, a, b, c, d, e, f, g, h, i)

        float3 w = amplify * peak;
        output = RgbFromWorking(max(((b + d + f + h) * w + e) * rcp(4.0 * w + 1.0), 0.0));
    }

    return float4(output, eFull.a);
}

technique ContrastAdaptiveSharpen <
    ui_label = "CAS + Depth AMD FidelityFX";
    ui_tooltip = "AMD FidelityFX Contrast Adaptive Sharpening, rewritten from Lilium's version.\n"
                 "Works in SDR, scRGB and HDR10. Sharpening fades with depth (Depth control).\n"
                 "Areas that are already sharp are sharpened less, flat areas more.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CasDepth;
    }
}
