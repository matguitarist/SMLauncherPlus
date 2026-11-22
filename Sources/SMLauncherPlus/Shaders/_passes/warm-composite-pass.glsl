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
    vec2 texel = vec2(1.0 / snesSize(InputSize).x, 0.0);
    vec3 left = texture(Texture, vTexCoord - texel).rgb;
    vec3 mid = texture(Texture, vTexCoord).rgb;
    vec3 right = texture(Texture, vTexCoord + texel).rgb;
    vec3 softened = left * 0.18 + mid * 0.64 + right * 0.18;
    vec3 warm = softened * vec3(1.06, 1.01, 0.92);
    FragColor = vec4(clamp(warm, 0.0, 1.0), texture(Texture, vTexCoord).a);
}
#endif
