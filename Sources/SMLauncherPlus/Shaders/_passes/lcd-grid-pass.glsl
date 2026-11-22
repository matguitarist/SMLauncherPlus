// Original Mega Man X Recomp shader preset. Public domain / CC0-1.0.

#ifdef VERTEX
in vec2 VertexCoord;
in vec2 TexCoord;
out vec2 vTexCoord;

void main() {
    vTexCoord = TexCoord;
    gl_Position = vec4(VertexCoord * 2.0 - 1.0, 0.0, 1.0);
}
#endif

#ifdef FRAGMENT
uniform sampler2D Texture;
uniform vec2 InputSize;
in vec2 vTexCoord;
out vec4 FragColor;

// SNES pixels in the picture. With the enhanced renderer the game hands the filter the picture already
// upscaled (768×672 at scale 3, wider in widescreen), so one SNES pixel is several texels.
vec2 snesSize(vec2 inputSize) {
    return inputSize / max(1.0, floor(inputSize.y / 224.0 + 0.5));
}

void main() {
    vec4 c = texture(Texture, vTexCoord);
    vec2 p = vTexCoord * snesSize(InputSize);
    // Screen pixels per SNES pixel, and where this one sits in its cell, in screen pixels.
    vec2 cell = 1.0 / max(fwidth(p), vec2(1e-6));
    vec2 inCell = fract(p) * cell;
    // A one-pixel line on each cell's top and left edge, faded out when cells are under 3 pixels.
    float line = (inCell.x < 1.0 || inCell.y < 1.0) ? 1.0 : 0.0;
    float show = clamp(min(cell.x, cell.y) - 2.0, 0.0, 1.0);
    vec3 color = c.rgb * mix(1.04, 0.72, line * show);
    FragColor = vec4(clamp(color, 0.0, 1.0), c.a);
}
#endif
