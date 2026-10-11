# Andarael_Resahde_Sahders

## Description

This repo contains shaders for [Reshade](https://reshade.me/) that I have created or modified.

## Installation

Place the shaders and textures files in your `reshade-shaders/Shaders` and `reshade-shaders/Textures` folders respectively.

## Shaders

### [CAS with Depth](shaders/CAS_depth.fx)

AMD FidelityFX Contrast Adaptive Sharpening that fades with distance: the foreground is sharpened, the background is left alone.
Rewritten from [Lilium's CAS](https://github.com/EndlesslyFlowering/ReShade_HDR_shaders), so it works in SDR, scRGB and HDR10 and sharpens in linear light (RGB mode) or on luminance only (luminance mode, no colour shifts).

`Depth control` sets how much the sharpening fades (0 = no fade, depth is not read), `Depth linearity` pushes the fade further away. `Display depth factor` shows the multiplier.
The colour space comes from ReShade; force it with `CAS_DEPTH_COLOUR_SPACE` (1 = SDR, 2 = scRGB, 3 = HDR10).

License: GPL-3.0.

### [Exposure Bracket](shaders/ExposureBracket.fx)

Runs effects such as RTGI or MXAO on a well-exposed image, then restores the original frame plus only what those effects added.
Useful when an effect does nothing in dark scenes, or when it runs (with [REST](https://github.com/4lex4nder/ReshadeEffectShaderToggler)) on a linear HDR buffer taken before the game's own exposure.

Order in ReShade: `ExposureBracket_Begin` -> effects -> `ExposureBracket_End`.
With REST, put the three in the same group. Exposure is metered automatically (`EXPOSURE_BRACKET_AUTO=1`) or set manually.
Pixels the effects did not touch come back bit-exact.

License: MIT (see the file header).

### [RD Gamma + RCAS](shaders/RD_GammaRCAS.fx)

Power gamma correction followed by RCAS sharpening, in one technique.
Made for displays with a pure power gamma of 2.0 (Steam Deck OLED): the image is re-encoded so it looks like gamma 2.2 (`Target Gamma`, 2.4 for cinema), then sharpened.

RCAS is AMD FidelityFX Robust Contrast Adaptive Sharpening, based on Lilium's implementation. Sharpness and noise removal are adjustable (the Contrast Adaptation slider has no effect), and both stages can be toggled.

License: GPL-3.0.

## Modified third-party shaders

### [EyeAdaption](shaders/EyeAdaption.fx)

brussell's EyeAdaption with Darken Highlights / Midtones / Shadows set to 0 by default, so it only adapts exposure. License: CC BY 4.0.

### [Light DoF, far only](shaders/LightDofFarOnly.fx)

luluco250's Light Depth of Field with only the far blur technique (auto focus and near blur commented out). License: CC BY-SA 4.0.

### [Filmic Adaptation](shaders/Filmic_Adaptation_custom.fx)

prod80's PD80 03 Filmic Adaptation, technique renamed to `FilmicTonemap`. License: MIT.

## Licenses

Each shader states its license in its header. GPL-3.0 text: [LICENSES/GPL-3.0.txt](LICENSES/GPL-3.0.txt).
