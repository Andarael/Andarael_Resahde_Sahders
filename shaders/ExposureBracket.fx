/*
    ExposureBracket: runs effects on a well-exposed image, then puts back the original frame
    plus only what those effects changed.

    Use: ExposureBracket_Begin -> one or more effects (RTGI, MXAO, ...) -> ExposureBracket_End.

    Why: some effects (GI, AO, ...) expect a display-like image. When they run on a dark scene,
    or with REST on a mid-frame linear HDR buffer taken before the game's own exposure, they find
    almost no light and do nothing. The bracket meters the scene, exposes it towards middle grey
    and encodes it (Reinhard + display gamma). The end pass decodes with the same curve and
    divides by the same exposure. Untouched pixels come back bit-exact, so highlights are neither
    clipped nor quantised by the round trip.

    The encoding is a generic curve, not the one a given effect decodes with. Effects that
    linearise/expand their input internally will see a slightly different radiance; tune
    "Display gamma" / "HDR white point" if an effect's strength looks off.

    Deliberately simple for D3D12 mid-frame use (REST): no sRGB read/write, no blending, no mips.

    MIT License - Copyright (c) 2026 Andarael
*/

#include "ReShade.fxh"

#ifndef EXPOSURE_BRACKET_AUTO
    #define EXPOSURE_BRACKET_AUTO 1
#endif

uniform float ExposureEV <
    ui_type = "drag"; ui_min = -4.0; ui_max = 8.0; ui_step = 0.05;
    ui_label = "Exposure compensation (EV)";
    ui_tooltip = "Auto exposure: offset from the metered exposure.\nManual exposure: the exposure itself (0 EV = x1).";
> = 0.0;

uniform float DisplayGamma <
    ui_type = "drag"; ui_min = 1.8; ui_max = 2.6; ui_step = 0.01;
    ui_label = "Display gamma";
    ui_tooltip = "Gamma of the encoded image the effects receive.";
> = 2.2;

uniform float WhitePoint <
    ui_type = "drag"; ui_min = 4.0; ui_max = 100.0; ui_step = 0.5;
    ui_label = "HDR white point";
    ui_tooltip = "Exposed radiance that encodes to pure white. Brighter values are compressed, never clipped.";
> = 25.0;

#if EXPOSURE_BRACKET_AUTO
uniform float MiddleGrey <
    ui_type = "drag"; ui_min = 0.02; ui_max = 0.5; ui_step = 0.005;
    ui_label = "Auto exposure: target middle grey";
> = 0.18;

uniform float2 ExposureRange <
    ui_type = "drag"; ui_min = -6.0; ui_max = 10.0; ui_step = 0.1;
    ui_label = "Auto exposure: min / max (EV)";
    ui_tooltip = "Limits for the metered exposure, in stops (0 = x1).";
> = float2(-2.0, 6.0);

uniform float AdaptSpeed <
    ui_type = "drag"; ui_min = 0.1; ui_max = 10.0; ui_step = 0.1;
    ui_label = "Auto exposure: adaptation speed";
> = 1.5;

uniform float FrameTime < source = "frametime"; >;
#endif

// --- Encoding: Reinhard (white point W maps to 1) followed by a display gamma -------------------

float3 Encode(float3 x)
{
    float k = 1.0 + rcp(WhitePoint);
    float3 t = saturate(k * x * rcp(x + 1.0));
    return pow(t, rcp(DisplayGamma));
}

float3 Decode(float3 y)
{
    float k = 1.0 + rcp(WhitePoint);
    float3 t = pow(saturate(y), DisplayGamma);
    return t * rcp(max(k - t, 1e-6));
}

// --- Textures ----------------------------------------------------------------------------------

texture2D EB_OrigTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D sOrig { Texture = EB_OrigTex; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

texture2D EB_EncTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D sEnc { Texture = EB_EncTex; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

sampler2D sBack { Texture = ReShade::BackBufferTex; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

#if EXPOSURE_BRACKET_AUTO
// Adapted log2 luminance of the scene. Two 1x1 textures: this frame / previous frame.
texture2D EB_ExpCur  { Width = 1; Height = 1; Format = R32F; };
texture2D EB_ExpPrev { Width = 1; Height = 1; Format = R32F; };
sampler2D sExpCur  { Texture = EB_ExpCur;  MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
sampler2D sExpPrev { Texture = EB_ExpPrev; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
#endif

float GetExposure()
{
#if EXPOSURE_BRACKET_AUTO
    float log_lum = tex2Dfetch(sExpCur, int2(0, 0)).r;
    float ev = clamp(log2(MiddleGrey) - log_lum, ExposureRange.x, ExposureRange.y);
    return exp2(ev + ExposureEV);
#else
    return exp2(ExposureEV);
#endif
}

// --- Begin -------------------------------------------------------------------------------------

#if EXPOSURE_BRACKET_AUTO
float PS_Meter(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    // 32 x 18 grid over the frame, centre-weighted.
    float sum = 0.0, wsum = 0.0;
    [loop] for (int y = 0; y < 18; y++)
    [loop] for (int x = 0; x < 32; x++)
    {
        float2 tuv = (float2(x, y) + 0.5) / float2(32.0, 18.0);
        float3 c = max(0.0, tex2Dlod(sBack, float4(tuv, 0, 0)).rgb);
        float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
        float2 d = tuv - 0.5;
        float w = 1.0 - 0.6 * saturate(dot(d, d) * 4.0);
        sum += log2(max(lum, 1e-5)) * w;
        wsum += w;
    }
    float cur = sum / wsum;

    float prev = tex2Dfetch(sExpPrev, int2(0, 0)).r;
    if (prev == 0.0 || !(abs(prev) < 1e6))  // first frame / garbage
        return cur;
    float k = 1.0 - exp(-max(FrameTime, 0.0) * 0.001 * AdaptSpeed);
    return lerp(prev, cur, saturate(k));
}

float PS_CopyExp(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dfetch(sExpCur, int2(0, 0)).r;
}
#endif

float4 PS_StoreOrig(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dfetch(sBack, int2(pos.xy));
}

float4 PS_Encode(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 c = tex2Dfetch(sOrig, int2(pos.xy));
    return float4(Encode(max(0.0, c.rgb) * GetExposure()), c.a);
}

// Copy of the encoded frame as it actually landed in the buffer (after its quantisation).
float4 PS_StoreEnc(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dfetch(sBack, int2(pos.xy));
}

// --- End ---------------------------------------------------------------------------------------

float4 PS_Decode(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float4 orig   = tex2Dfetch(sOrig, int2(pos.xy));
    float3 before = tex2Dfetch(sEnc,  int2(pos.xy)).rgb;
    float3 after  = tex2Dfetch(sBack, int2(pos.xy)).rgb;

    float3 delta = (Decode(after) - Decode(before)) / GetExposure();
    // Exactly the original wherever the effects changed nothing.
    delta = (all(after == before)) ? 0.0 : delta;
    return float4(max(0.0, orig.rgb + delta), orig.a);
}

technique ExposureBracket_Begin < ui_tooltip = "Place ABOVE the effects to bracket (e.g. Launchpad, RTGI, MXAO)."; >
{
#if EXPOSURE_BRACKET_AUTO
    pass Meter     { VertexShader = PostProcessVS; PixelShader = PS_Meter;     RenderTarget = EB_ExpCur; }
    pass CopyExp   { VertexShader = PostProcessVS; PixelShader = PS_CopyExp;   RenderTarget = EB_ExpPrev; }
#endif
    pass StoreOrig { VertexShader = PostProcessVS; PixelShader = PS_StoreOrig; RenderTarget = EB_OrigTex; }
    pass Encode    { VertexShader = PostProcessVS; PixelShader = PS_Encode; }
    pass StoreEnc  { VertexShader = PostProcessVS; PixelShader = PS_StoreEnc;  RenderTarget = EB_EncTex; }
}

technique ExposureBracket_End < ui_tooltip = "Place BELOW the bracketed effects. Restores the original frame plus what they added."; >
{
    pass Decode    { VertexShader = PostProcessVS; PixelShader = PS_Decode; }
}
