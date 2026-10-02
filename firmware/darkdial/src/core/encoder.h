// Decoder for the knob's quadrature encoder, fed with samples of both lines.
//
// The contacts of this encoder are noisy far beyond ordinary bounce: while
// the knob moves, a closed contact drops out for milliseconds at a time, and
// so does the common one, which looks like a whole quadrature cycle. Counting
// edges or quadrature transitions therefore counts noise. What is reliable is
// where the knob rests: it has a detent wherever both lines are equal (both
// low or both high), and there the lines are quiet.
//
// So a step is reported when the lines have settled in the other rest state,
// and its direction is taken from the line that settled last: the state seen
// most just before the rest (A low/B high or A high/B low).
#pragma once
#include <stdint.h>

namespace dd {

class EncoderDecoder {
 public:
  /// The lines must be sampled at this period.
  static constexpr uint32_t kSamplePeriodUs = 500;

  /// One sample, state = A << 1 | B. Returns +1 or -1 when a detent was
  /// reached, otherwise 0.
  int sample(uint8_t state);

 private:
  // A rest state counts once it was seen for 25 ms; dropouts of up to 2 ms do
  // not restart that. The direction is judged over the 80 ms before.
  static constexpr int kRestSamples = 50;
  static constexpr int kGapSamples = 4;
  static constexpr int kDirectionSamples = 160;
  static constexpr int kHistory = kRestSamples + kDirectionSamples;

  uint8_t history_[kHistory] = {};
  int head_ = 0;
  int stored_ = 0;
  int rest_ = -1;       // last confirmed rest state: 0 or 3
  int candidate_ = -1;  // rest state being confirmed
  int held_ = 0;
  int gap_ = 0;
  bool confirmed_ = false;
};

}  // namespace dd
