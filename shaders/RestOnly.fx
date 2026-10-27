/*
    RestOnly: keeps the effects meant for REST groups off the final image.

    With ReshadeEffectShaderToggler (REST), effects run at a point of the game's frame (before the fog,
    under the UI...) when the group's shader is drawn. On screens where it is not drawn (loading
    screens, some menus), the effects are not dropped: REST, or ReShade itself, renders them on the
    final image at the end of the frame, in technique order, with whatever is left in the depth buffer
    from the last 3D frame. RTGI, MXAO or DOF then draw over the loading screen.

    Use: put RestOnly_Begin before and RestOnly_End after the REST-group effects in the technique
    order, and keep both out of every REST group. When the effects ran in their groups, Begin and End
    only copy the final image and put it back. When they fell back to the final image, Begin saved it
    before them and End puts it back after them, so nothing they drew stays. Effects meant to draw on
    top of everything go after RestOnly_End.

    MIT License - Copyright (c) 2026 Andarael
*/

#include "ReShade.fxh"

texture2D RestOnly_SavedTex { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16; };
sampler2D sRestOnlySaved { Texture = RestOnly_SavedTex; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
sampler2D sRestOnlyBack { Texture = ReShade::BackBufferTex; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

float4 SavePS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dfetch(sRestOnlyBack, int2(pos.xy));
}

float4 RestorePS(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return tex2Dfetch(sRestOnlySaved, int2(pos.xy));
}

technique RestOnly_Begin < ui_tooltip = "Place BEFORE the effects that must only run inside REST groups. Keep it out of every REST group."; >
{
    pass Save { VertexShader = PostProcessVS; PixelShader = SavePS; RenderTarget = RestOnly_SavedTex; }
}

technique RestOnly_End < ui_tooltip = "Place AFTER the effects that must only run inside REST groups. Keep it out of every REST group."; >
{
    pass Restore { VertexShader = PostProcessVS; PixelShader = RestorePS; }
}
