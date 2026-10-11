// RD_GammaRCAS - Combined Power Gamma Correction + RCAS Sharpening
// For Steam Deck OLED (gamma 2.0 display)
//
// RCAS algorithm based on AMD FidelityFX RCAS (Lilium's implementation)
// Gamma correction: Pure power gamma conversion (not piecewise sRGB)
//
// Copyright (c) 2026 Andarael
// License: GPL-3.0 (see LICENSES/GPL-3.0.txt), as a derivative of Lilium's RCAS
// (https://github.com/EndlesslyFlowering/ReShade_HDR_shaders).
//
// RCAS is part of the FidelityFX SDK:
// Copyright (C) 2024 Advanced Micro Devices, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#include "ReShade.fxh"

//============================================================================
// UI PARAMETERS
//============================================================================

uniform bool ENABLE_GAMMA_CORRECTION <
    ui_category = "Gamma Correction";
    ui_label = "Enable Gamma Correction";
    ui_tooltip = "Toggle power gamma correction on/off";
> = true;

uniform float SOURCE_GAMMA <
    ui_category = "Gamma Correction";
    ui_label = "Source Gamma";
    ui_tooltip = "The display's native gamma.\nSteam Deck OLED = 2.0";
    ui_type = "drag";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.01;
> = 2.0;

uniform float TARGET_GAMMA <
    ui_category = "Gamma Correction";
    ui_label = "Target Gamma";
    ui_tooltip = "The gamma you want to correct to.\nStandard = 2.2, Cinema = 2.4";
    ui_type = "drag";
    ui_min = 1.0;
    ui_max = 3.0;
    ui_step = 0.01;
> = 2.2;

uniform bool ENABLE_RCAS <
    ui_category = "RCAS Sharpening";
    ui_label = "Enable RCAS";
    ui_tooltip = "Toggle Robust Contrast Adaptive Sharpening on/off";
> = true;

uniform float SHARPNESS <
    ui_category = "RCAS Sharpening";
    ui_label = "Sharpness Amount";
    ui_tooltip = "Sharpening intensity.\n0.0 = subtle, 1.0 = maximum";
    ui_type = "drag";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.5;

uniform float CONTRAST <
    ui_category = "RCAS Sharpening";
    ui_label = "Contrast Adaptation";
    ui_tooltip = "How much to adapt to high contrast areas.\nHigher = more sharpening in high contrast";
    ui_type = "drag";
    ui_min = 0.0;
    ui_max = 1.0;
    ui_step = 0.01;
> = 0.0;

uniform bool ENABLE_NOISE_REMOVAL <
    ui_category = "RCAS Sharpening";
    ui_label = "Noise Removal";
    ui_tooltip = "Reduce sharpening of noise and film grain";
> = true;

//============================================================================
// HELPER MACROS
//============================================================================

#define MIN3(a, b, c) min(min(a, b), c)
#define MAX3(a, b, c) max(max(a, b), c)
#define MIN4(a, b, c, d) min(min(a, b), min(c, d))
#define MAX4(a, b, c, d) max(max(a, b), max(c, d))
#define MAXRGB(c) max(max(c.r, c.g), c.b)

static const float2 PIXEL_SIZE = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
static const int BUFFER_WIDTH_INT = int(BUFFER_WIDTH);
static const int BUFFER_HEIGHT_INT = int(BUFFER_HEIGHT);
static const int2 BUFFER_SIZE_MINUS_1 = int2(BUFFER_WIDTH_INT - 1, BUFFER_HEIGHT_INT - 1);

// BT.709 luminance coefficients
static const float3 LUMA_COEF = float3(0.2126, 0.7152, 0.0722);

//============================================================================
// INTERMEDIATE TEXTURE (for two-pass approach)
//============================================================================

texture2D TexGammaCorrected { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA8; };
sampler2D SamplerGammaCorrected { Texture = TexGammaCorrected; };

//============================================================================
// GAMMA CORRECTION PASS
//============================================================================

float4 PS_GammaCorrection(float4 pos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float4 color = tex2D(ReShade::BackBuffer, texcoord);

    if (ENABLE_GAMMA_CORRECTION && abs(SOURCE_GAMMA - TARGET_GAMMA) > 0.001)
    {
        // Power gamma conversion: pow(color, target/source)
        // Display shows: output^SOURCE_GAMMA
        // We want perceived: original^TARGET_GAMMA
        // So we encode: pow(original, TARGET_GAMMA/SOURCE_GAMMA)
        // Result on display: (original^(TARGET/SOURCE))^SOURCE = original^TARGET
        float gamma_ratio = TARGET_GAMMA / SOURCE_GAMMA;
        color.rgb = pow(max(color.rgb, 0.0), gamma_ratio);
    }

    return color;
}

//============================================================================
// RCAS SHARPENING PASS
//============================================================================

float3 RCas(int2 pos)
{
    // 5-tap cross pattern sampling:
    //    b
    //  d e f
    //    h

    float3 e = tex2Dfetch(SamplerGammaCorrected, pos).rgb;

    // Clamp neighbor positions to valid range
    int4 bd_pos = pos.xyxy + int4(0, -1, -1, 0);
    bd_pos = clamp(bd_pos, int4(0, 0, 0, 0), int4(BUFFER_SIZE_MINUS_1, BUFFER_SIZE_MINUS_1));

    int4 fh_pos = pos.xyxy + int4(1, 0, 0, 1);
    fh_pos = clamp(fh_pos, int4(0, 0, 0, 0), int4(BUFFER_SIZE_MINUS_1, BUFFER_SIZE_MINUS_1));

    float3 b = tex2Dfetch(SamplerGammaCorrected, bd_pos.xy).rgb;
    float3 d = tex2Dfetch(SamplerGammaCorrected, bd_pos.zw).rgb;
    float3 f = tex2Dfetch(SamplerGammaCorrected, fh_pos.xy).rgb;
    float3 h = tex2Dfetch(SamplerGammaCorrected, fh_pos.zw).rgb;

    // Calculate lobe weight based on local contrast
    float3 rgb_min4 = MIN4(b, d, f, h);
    float3 rgb_max4 = MAX4(b, d, f, h);

    // Limit max to prevent division issues
    float3 rgb_max4_limited = min(rgb_max4, 0.99);

    // Peak constants
    static const float2 peak_c = float2(1.0, -4.0);

    // Calculate adaptive lobe weight per channel
    float3 rgb_min_hit = rgb_min4 * rcp(4.0 * rgb_max4_limited);
    float3 rgb_max_hit = (peak_c.x - rgb_max4_limited) * rcp(4.0 * rgb_min4 + peak_c.y);

    float3 rgb_lobe = max(-rgb_min_hit, rgb_max_hit);
    float lobe_local = MAXRGB(rgb_lobe);

    // Limit sharpening to avoid unnatural results
    // FSR_RCAS_LIMIT = 0.25 - (1/16) = 0.1875
    float sharpness_factor = exp2(-(1.0 - SHARPNESS));
    float lobe = max(-0.1875, min(lobe_local, 0.0)) * sharpness_factor;

    // Apply noise removal if enabled
    if (ENABLE_NOISE_REMOVAL)
    {
        // Calculate approximate luma * 2 for noise detection
        float b_luma_2x = b.b * 0.5 + (b.r * 0.5 + b.g);
        float d_luma_2x = d.b * 0.5 + (d.r * 0.5 + d.g);
        float e_luma_2x = e.b * 0.5 + (e.r * 0.5 + e.g);
        float f_luma_2x = f.b * 0.5 + (f.r * 0.5 + f.g);
        float h_luma_2x = h.b * 0.5 + (h.r * 0.5 + h.g);

        // Highpass noise detection
        float nz = 0.25 * (b_luma_2x + d_luma_2x + f_luma_2x + h_luma_2x) - e_luma_2x;

        float luma_2x_max = MAX3(MAX3(b_luma_2x, d_luma_2x, e_luma_2x), f_luma_2x, h_luma_2x);
        float luma_2x_min = MIN3(MIN3(b_luma_2x, d_luma_2x, e_luma_2x), f_luma_2x, h_luma_2x);

        nz = saturate(abs(nz) * rcp(luma_2x_max - luma_2x_min + 0.0001));
        nz = -0.5 * nz + 1.0;

        lobe *= nz;
    }

    // Apply sharpening
    float rcp_weight = rcp(4.0 * lobe + 1.0);
    float3 result = max(((b + d + f + h) * lobe + e) * rcp_weight, 0.0);

    return result;
}

float4 PS_RCAS(float4 pos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ENABLE_RCAS)
    {
        return tex2D(SamplerGammaCorrected, texcoord);
    }

    float3 sharpened = RCas(int2(pos.xy));
    return float4(sharpened, 1.0);
}

//============================================================================
// TECHNIQUE
//============================================================================

technique RD_GammaRCAS <
    ui_label = "RD Gamma + RCAS";
    ui_tooltip = "Combined Power Gamma Correction and RCAS Sharpening\n"
                 "Designed for Steam Deck OLED (gamma 2.0 display)\n\n"
                 "Gamma: Corrects from source power gamma to target\n"
                 "RCAS: AMD FidelityFX Robust Contrast Adaptive Sharpening";
>
{
    pass GammaCorrection
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GammaCorrection;
        RenderTarget = TexGammaCorrected;
    }
    pass RCAS
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_RCAS;
    }
}
