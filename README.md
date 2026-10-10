# Andarael_Resahde_Sahders

## Description

This repo contains shaders for [Reshade](https://reshade.me/) that I have created or modified.

## Installation

Place the shaders and textures files in your `reshade-shaders/Shaders` and `reshade-shaders/Textures` folders respectively.

## Shaders

### [CAS with Depth](shaders/CAS_depth.fx)

This is a modified version of the Contrast Adaptive Sharpening shader that reduces the effect with the distance.
This is useful when you want to sharpen the image but don't want to sharpen the background.


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

RCAS is AMD FidelityFX Robust Contrast Adaptive Sharpening, based on Lilium's implementation. Sharpness, contrast adaptation and noise removal are adjustable, and both stages can be toggled.
