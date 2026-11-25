// Pixel conversion and PNG encoding for ghostty-host frames.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Converts premultiplied BGRA to premultiplied RGBA. With p3_to_srgb, the
// input is treated as Display P3 (sRGB transfer curve) and converted to sRGB
// with the standard D65 matrix; otherwise channels are only reordered.
void image_bgra_to_rgba(const uint8_t *bgra, size_t stride, uint32_t width, uint32_t height,
                        bool p3_to_srgb, uint8_t *rgba_out);

// Encodes tightly packed premultiplied RGBA as a PNG tagged sRGB, dropping
// the alpha channel when every pixel is opaque. Returns a malloc'd buffer.
uint8_t *image_png(const uint8_t *rgba, uint32_t width, uint32_t height, int zlib_level,
                   size_t *len_out);
