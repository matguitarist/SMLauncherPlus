// Renders one filter pass the way snesrecomp's glsl_shader.c does, offscreen, and prints the red
// channel of the row and the column just past the middle of the output (the middle itself can sit on a grid line). Built and run by ShaderPassTests.
//   render_pass <pass.glsl> <input w> <input h> <output w> <output h> <pattern> [row]
// pattern: "flat" (all gray) or "checker" (alternating SNES pixels, each drawn input h / 224 texels wide).
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *readFile(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *s = malloc(n + 1);
  fread(s, 1, n, f);
  s[n] = 0;
  fclose(f);
  return s;
}

static GLuint compile(GLenum kind, const char *define, const char *body) {
  const char *parts[] = {"#version 330\n", define, body};
  GLuint s = glCreateShader(kind);
  glShaderSource(s, 3, parts, NULL);
  glCompileShader(s);
  GLint ok;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) { char log[2048]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "compile: %s\n", log); exit(2); }
  return s;
}

int main(int argc, char **argv) {
  if (argc < 7) return 1;
  int iw = atoi(argv[2]), ih = atoi(argv[3]), ow = atoi(argv[4]), oh = atoi(argv[5]);
  int checker = strcmp(argv[6], "checker") == 0;
  int row = argc > 7 ? atoi(argv[7]) : oh / 2 + 1;
  CGLPixelFormatAttribute attrs[] = {kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core, kCGLPFAAllowOfflineRenderers, 0};
  CGLPixelFormatObj pf; GLint count;
  if (CGLChoosePixelFormat(attrs, &pf, &count) || !pf) return 3;
  CGLContextObj ctx;
  if (CGLCreateContext(pf, NULL, &ctx)) return 3;
  CGLSetCurrentContext(ctx);

  char *body = readFile(argv[1]);
  if (!body) return 4;
  GLuint prog = glCreateProgram();
  glAttachShader(prog, compile(GL_VERTEX_SHADER, "#define VERTEX\n", body));
  glAttachShader(prog, compile(GL_FRAGMENT_SHADER, "#define FRAGMENT\n", body));
  glBindAttribLocation(prog, 0, "VertexCoord");
  glBindAttribLocation(prog, 1, "TexCoord");
  glLinkProgram(prog);
  GLint ok; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
  if (!ok) return 5;

  // The input picture, nearest-sampled like the game's.
  unsigned char *pixels = malloc((size_t)iw * ih * 4);
  int scale = ih / 224 > 0 ? ih / 224 : 1;
  for (int y = 0; y < ih; y++) for (int x = 0; x < iw; x++) {
    unsigned char v = 128;
    if (checker) v = ((x / scale + y / scale) % 2) ? 200 : 60;
    unsigned char *p = pixels + ((size_t)y * iw + x) * 4;
    p[0] = p[1] = p[2] = v; p[3] = 255;
  }
  GLuint tex; glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, iw, ih, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  GLuint out, fbo; glGenTextures(1, &out);
  glBindTexture(GL_TEXTURE_2D, out);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, ow, oh, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, out, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return 6;
  glViewport(0, 0, ow, oh);

  // A full-screen quad: VertexCoord and TexCoord from 0 to 1, and MVPMatrix mapping 0..1 to clip space.
  float quad[] = {0,0, 0,0,  1,0, 1,0,  0,1, 0,1,  1,1, 1,1};
  GLuint vao, vbo; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
  glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, (void *)0); glEnableVertexAttribArray(0);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, (void *)8); glEnableVertexAttribArray(1);

  glUseProgram(prog);
  glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
  glUniform1i(glGetUniformLocation(prog, "Texture"), 0);
  float size[2] = {(float)iw, (float)ih}, osize[2] = {(float)ow, (float)oh};
  glUniform2fv(glGetUniformLocation(prog, "InputSize"), 1, size);
  glUniform2fv(glGetUniformLocation(prog, "TextureSize"), 1, size);
  glUniform2fv(glGetUniformLocation(prog, "OutputSize"), 1, osize);
  float mvp[16] = {2,0,0,0, 0,2,0,0, 0,0,1,0, -1,-1,0,1};
  glUniformMatrix4fv(glGetUniformLocation(prog, "MVPMatrix"), 1, GL_FALSE, mvp);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glFinish();

  unsigned char *result = malloc((size_t)ow * oh * 4);
  glReadPixels(0, 0, ow, oh, GL_RGBA, GL_UNSIGNED_BYTE, result);
  printf("row");
  for (int x = 0; x < ow; x++) printf(" %d", result[((size_t)row * ow + x) * 4]);
  printf("\ncolumn");
  for (int y = 0; y < oh; y++) printf(" %d", result[((size_t)y * ow + ow / 2 + 1) * 4]);
  printf("\n");
  return 0;
}
