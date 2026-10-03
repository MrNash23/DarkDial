// Turning the finished picture by any angle, for a device that does not
// stand upright. LVGL draws upright; the turn happens on the way to the
// display, one row at a time (nearest pixel). Portable: the snapshot tool on
// the host uses the same code.
#pragma once
#include <math.h>
#include <stdint.h>

namespace dd {

class FrameRotation {
 public:
  /// `degrees` clockwise; the picture is `size` × `size` pixels.
  void set(int degrees, int size) {
    size_ = size;
    const float radians = static_cast<float>(degrees) * 3.14159265f / 180.0f;
    cos_ = static_cast<int32_t>(lroundf(cosf(radians) * 65536.0f));
    sin_ = static_cast<int32_t>(lroundf(sinf(radians) * 65536.0f));
  }

  /// Fills out[0 … x1-x0) with screen row `y`, columns x0 … x1-1, from the
  /// upright picture `src` (row-major, size × size). Outside is black.
  void row(const uint16_t *src, int y, int x0, int x1, uint16_t *out) const {
    const int32_t half = size_ << 15;  // centre, 16.16
    // The screen shows the upright picture turned clockwise, so each screen
    // pixel looks up the picture turned back.
    const int32_t dx = (x0 << 16) + 0x8000 - half;
    const int32_t dy = (y << 16) + 0x8000 - half;
    int32_t sx = static_cast<int32_t>((static_cast<int64_t>(dx) * cos_ + static_cast<int64_t>(dy) * sin_) >> 16) + half;
    int32_t sy = static_cast<int32_t>((-static_cast<int64_t>(dx) * sin_ + static_cast<int64_t>(dy) * cos_) >> 16) + half;
    const int32_t limit = size_ << 16;
    for (int x = x0; x < x1; x++) {
      *out++ = (sx >= 0 && sy >= 0 && sx < limit && sy < limit) ? src[(sy >> 16) * size_ + (sx >> 16)] : 0;
      sx += cos_;
      sy -= sin_;
    }
  }

  /// Screen area that changes when the upright area [x0,x1)×[y0,y1) does.
  void bounds(int x0, int y0, int x1, int y1, int &ox0, int &oy0, int &ox1, int &oy1) const {
    const float c = cos_ / 65536.0f, s = sin_ / 65536.0f, h = size_ / 2.0f;
    float minX = 1e9f, minY = 1e9f, maxX = -1e9f, maxY = -1e9f;
    const float xs[2] = {static_cast<float>(x0), static_cast<float>(x1)};
    const float ys[2] = {static_cast<float>(y0), static_cast<float>(y1)};
    for (float px : xs) {
      for (float py : ys) {
        const float rx = h + (px - h) * c - (py - h) * s;
        const float ry = h + (px - h) * s + (py - h) * c;
        minX = fminf(minX, rx);
        maxX = fmaxf(maxX, rx);
        minY = fminf(minY, ry);
        maxY = fmaxf(maxY, ry);
      }
    }
    ox0 = clampTo(static_cast<int>(floorf(minX)) - 1);
    oy0 = clampTo(static_cast<int>(floorf(minY)) - 1);
    ox1 = clampTo(static_cast<int>(ceilf(maxX)) + 1);
    oy1 = clampTo(static_cast<int>(ceilf(maxY)) + 1);
  }

 private:
  int clampTo(int v) const { return v < 0 ? 0 : (v > size_ ? size_ : v); }
  int size_ = 0;
  int32_t cos_ = 65536;
  int32_t sin_ = 0;
};

}  // namespace dd
