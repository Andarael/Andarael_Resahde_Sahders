/*
    MultiResNames.fxh: one set of render-size textures per render resolution

    ReShade 6.4+ compiles an effect again (a "permutation") for every render target size it is asked
    to render into, for example when ReshadeEffectShaderToggler runs a group before the game's
    upscaler (DLSS Quality renders at 1707x960 for a 2560x1440 output). Textures are shared between
    permutations by name, so the 1707x960 permutation ends up reading and writing the 2560x1440
    textures of the default one, and anything addressed in pixels lands in the wrong place.

    Declaring a texture through MULTIRES_NAME appends the permutation size to its name
    (NormalsTexV4 -> NormalsTexV4_1707x960), so every render size gets its own set and several
    upscaler modes work side by side. At the native size the textures are simply renamed.

    Usage, before the texture is declared and before any header that declares it:
        #include "MultiResNames.fxh"
        #define MyTex MULTIRES_NAME(MyTex)
    Rename only textures whose size follows BUFFER_WIDTH/BUFFER_HEIGHT; fixed-size ones can stay
    shared. Every effect that shares a texture by name has to rename it the same way.

    MIT License, Andarael
*/

#pragma once

#define MULTIRES_PASTE(name, w, h)  name##_##w##x##h
#define MULTIRES_EXPAND(name, w, h) MULTIRES_PASTE(name, w, h)
#define MULTIRES_NAME(name)         MULTIRES_EXPAND(name, BUFFER_WIDTH, BUFFER_HEIGHT)

// iMMERSE deferred buffers (MartysMods/mmx_deferred.fxh): written by Launchpad, read by RTGI and MXAO.
// The 1x1 IPC predication buffer stays shared.
#define GeoNormalsTexV4  MULTIRES_NAME(GeoNormalsTexV4)
#define NormalsTexV4     MULTIRES_NAME(NormalsTexV4)
#define MotionVectorsTex MULTIRES_NAME(MotionVectorsTex)
#define AlbedoTex        MULTIRES_NAME(AlbedoTex)
