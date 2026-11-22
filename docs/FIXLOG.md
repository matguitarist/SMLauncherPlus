# Fix log

## 2026-11-22 LCD Grid filter shows no grid in game

Symptom: picking LCD Grid in Settings › Display changed nothing visible, though config.ini held
`Shader = assets/shaders/lcd-grid.glslp`. CRT Soft's scanlines were missing too, and Sharp and Warm
Composite were about a third as strong as meant.
Cause: two things. LCD Grid's formula multiplied by `smoothstep(0.84, 0.96, cell)` where it meant
`1 - smoothstep(…)`, so it only dimmed the whole picture. And all four passes (from snesrecomp's
shared catalog) measured the input in texels: with the enhanced renderer the game hands a filter the
picture already upscaled (InputSize 768×672 at scale 3, wider in widescreen), so a "pixel" cell was
one screen pixel and the grid, scanlines and neighbor samples fell inside one SNES pixel.
Fix: each pass works in SNES pixels (`snesSize(InputSize)`, InputSize divided by its scale over 224
lines), and LCD Grid draws a one-screen-pixel line per cell with `fwidth`. `ShaderPassTests` renders
each pass through real OpenGL (Tests/Support/render_pass.c) at scale 1 and 3, 4:3 and widescreen.
Rule: a filter for an upscaled picture measures source pixels (InputSize over its scale), never
texels, and every filter is checked by rendering it, not by reading it.
