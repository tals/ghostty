#include "image.h"

#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

// Display P3 and sRGB share the D65 white point and the sRGB transfer curve,
// so the conversion is: decode, 3x3 matrix in linear light, encode.
// Linear P3 -> linear sRGB (inverse of the standard sRGB -> P3 matrix).
static const float P3_TO_SRGB[3][3] = {
    {1.2249401f, -0.2249404f, 0.0000000f},
    {-0.0420569f, 1.0420571f, 0.0000000f},
    {-0.0196376f, -0.0786361f, 1.0982735f},
};

#define ENC_STEPS 16384
static float decode_lut[256];
static uint8_t encode_lut[ENC_STEPS + 1];
static pthread_once_t luts_once = PTHREAD_ONCE_INIT;

static void build_luts(void) {
  for (int i = 0; i < 256; i++) {
    double v = i / 255.0;
    decode_lut[i] = (float)(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4));
  }
  for (int i = 0; i <= ENC_STEPS; i++) {
    double v = (double)i / ENC_STEPS;
    double e = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055;
    encode_lut[i] = (uint8_t)lround(fmin(fmax(e, 0), 1) * 255);
  }
}

static inline uint8_t encode(float v) {
  if (v <= 0) return 0;
  if (v >= 1) return 255;
  return encode_lut[(int)(v * ENC_STEPS + 0.5f)];
}

static inline uint8_t unpremul(uint8_t c, uint8_t a) { return (uint8_t)((c * 255 + a / 2) / a); }
static inline uint8_t premul(uint8_t c, uint8_t a) { return (uint8_t)((c * a + 127) / 255); }

static inline uint32_t convert_pixel(uint32_t bgra) {
  uint8_t b = bgra & 0xFF, g = (bgra >> 8) & 0xFF, r = (bgra >> 16) & 0xFF, a = bgra >> 24;
  if (a == 0) return 0;
  // Ghostty writes premultiplied alpha; convert the color, keep the alpha.
  if (a != 255) r = unpremul(r, a), g = unpremul(g, a), b = unpremul(b, a);
  float lr = decode_lut[r], lg = decode_lut[g], lb = decode_lut[b];
  uint8_t sr = encode(P3_TO_SRGB[0][0] * lr + P3_TO_SRGB[0][1] * lg + P3_TO_SRGB[0][2] * lb);
  uint8_t sg = encode(P3_TO_SRGB[1][0] * lr + P3_TO_SRGB[1][1] * lg + P3_TO_SRGB[1][2] * lb);
  uint8_t sb = encode(P3_TO_SRGB[2][0] * lr + P3_TO_SRGB[2][1] * lg + P3_TO_SRGB[2][2] * lb);
  if (a != 255) sr = premul(sr, a), sg = premul(sg, a), sb = premul(sb, a);
  return (uint32_t)sr | (uint32_t)sg << 8 | (uint32_t)sb << 16 | (uint32_t)a << 24;
}

static inline uint32_t swizzle_pixel(uint32_t bgra) {
  // BGRA -> RGBA: swap bytes 0 and 2.
  return (bgra & 0xFF00FF00u) | (bgra & 0xFFu) << 16 | (bgra >> 16 & 0xFFu);
}

void image_bgra_to_rgba(const uint8_t *bgra, size_t stride, uint32_t width, uint32_t height,
                        bool p3_to_srgb, uint8_t *rgba_out) {
  pthread_once(&luts_once, build_luts);
  // Terminal frames are mostly runs of one color, so remember the last one.
  uint32_t last_in = 0, last_out = 0;
  bool have_last = false;
  for (uint32_t y = 0; y < height; y++) {
    const uint32_t *src = (const uint32_t *)(bgra + y * stride);
    uint32_t *dst = (uint32_t *)(rgba_out + (size_t)y * width * 4);
    for (uint32_t x = 0; x < width; x++) {
      uint32_t px = src[x];
      if (!have_last || px != last_in) {
        last_in = px;
        last_out = p3_to_srgb ? convert_pixel(px) : swizzle_pixel(px);
        have_last = true;
      }
      dst[x] = last_out;
    }
  }
}

static void put32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

static uint8_t *chunk(uint8_t *out, const char *type, const uint8_t *data, uint32_t len) {
  put32(out, len);
  memcpy(out + 4, type, 4);
  if (len) memcpy(out + 8, data, len);
  uLong crc = crc32(0, out + 4, 4 + len);
  put32(out + 8 + len, (uint32_t)crc);
  return out + 12 + len;
}

uint8_t *image_png(const uint8_t *rgba, uint32_t width, uint32_t height, int zlib_level,
                   size_t *len_out) {
  bool opaque = true;
  size_t pixels = (size_t)width * height;
  for (size_t i = 0; i < pixels && opaque; i++) opaque = rgba[i * 4 + 3] == 255;
  int channels = opaque ? 3 : 4;
  size_t row = (size_t)width * channels + 1;
  uint8_t *raw = malloc(row * height);
  for (uint32_t y = 0; y < height; y++) {
    uint8_t *dst = raw + y * row;
    const uint8_t *src = rgba + (size_t)y * width * 4;
    dst[0] = 0;
    if (opaque) {
      for (uint32_t x = 0; x < width; x++) memcpy(dst + 1 + x * 3, src + x * 4, 3);
    } else {
      for (uint32_t x = 0; x < width; x++) {
        const uint8_t *px = src + x * 4;
        uint8_t a = px[3], *o = dst + 1 + x * 4;
        // PNG wants straight alpha.
        o[0] = a ? unpremul(px[0], a) : 0;
        o[1] = a ? unpremul(px[1], a) : 0;
        o[2] = a ? unpremul(px[2], a) : 0;
        o[3] = a;
      }
    }
  }
  // Filter "up" on every row but the first: terminal rows repeat a lot.
  for (uint32_t y = height; y-- > 1;) {
    uint8_t *cur = raw + y * row, *prev = raw + (y - 1) * row;
    cur[0] = 2;
    for (size_t i = 1; i < row; i++) cur[i] = (uint8_t)(cur[i] - prev[i]);
  }
  // deflate rather than compress2: libghostty's zlib, which the Linux host
  // uses, carries only what Ghostty itself calls.
  z_stream zs = {0};
  deflateInit(&zs, zlib_level);
  uLong zcap = deflateBound(&zs, (uLong)(row * height));
  uint8_t *z = malloc(zcap);
  zs.next_in = raw;
  zs.avail_in = (uInt)(row * height);
  zs.next_out = z;
  zs.avail_out = (uInt)zcap;
  deflate(&zs, Z_FINISH);
  uLong zlen = zs.total_out;
  deflateEnd(&zs);
  free(raw);

  uint8_t *png = malloc(8 + 25 + 13 + 12 + zlen + 12);
  uint8_t *p = png;
  static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
  memcpy(p, sig, 8);
  p += 8;
  uint8_t ihdr[13];
  put32(ihdr, width);
  put32(ihdr + 4, height);
  ihdr[8] = 8;
  ihdr[9] = opaque ? 2 : 6;
  ihdr[10] = ihdr[11] = ihdr[12] = 0;
  p = chunk(p, "IHDR", ihdr, 13);
  uint8_t intent = 0;  // perceptual
  p = chunk(p, "sRGB", &intent, 1);
  p = chunk(p, "IDAT", z, (uint32_t)zlen);
  p = chunk(p, "IEND", NULL, 0);
  free(z);
  *len_out = (size_t)(p - png);
  return png;
}
