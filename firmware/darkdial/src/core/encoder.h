// Decoder for the knob's quadrature encoder, fed with samples of both lines.
//
// The knob has a detent wherever both lines are equal: both low (both
// contacts closed) or both high (both open). The contacts are noisy far
// beyond ordinary bounce: while the knob moves, a closed contact loses
// contact for milliseconds at a time, sometimes for tens of them, and so does
// the common one. A line that reads low is therefore closed for certain; a
// line that reads high may be open or just not conducting. Counting edges or
// quadrature transitions counts that noise.
//
// So the decoder trusts low readings and makes high ones prove themselves:
//
//  - Both closed is taken after a few milliseconds of both lines low. The
//    direction is the line that closed first.
//  - Both open is taken once both lines stayed high for 25 ms. The direction
//    is the line that was still closed last.
//  - At speed the knob does not rest that long. Then a both-open phase of
//    12 ms counts in passing, once the other line has closed and both are
//    closed again: two steps at once.
//
// The thresholds were tuned against recordings of the real knob, which the
// host tests replay (firmware/host/fixtures/encoder_raw.txt).
#pragma once
#include <stdint.h>

namespace dd {

class EncoderDecoder {
 public:
  /// The lines must be sampled at this period.
  static constexpr uint32_t kSamplePeriodUs = 500;

  /// One sample, state = A << 1 | B. Returns the detents reached with it:
  /// 0, ±1 or ±2.
  int sample(uint8_t state);

 private:
  static constexpr int kClosedSamples = 6;  // 3 ms of both low
  static constexpr int kOpenSamples = 50;   // 25 ms of both high
  static constexpr int kPassSamples = 24;   // 12 ms of both high in passing
  static constexpr int kGapSamples = 4;     // 2 ms of something else do not end a high phase
  static constexpr int kVotes = 8;

  // The last or the first kVotes readings with exactly one line low.
  struct Votes {
    uint8_t readings[kVotes] = {};
    int count = 0;
    void clear() { count = 0; }
    void addFirst(uint8_t reading);
    void addLast(uint8_t reading);
    /// 1: mostly A low, 2: mostly B low, 0: undecided.
    int majority() const;
  };

  int rest_ = -1;       // last detent: 0 (both closed), 3 (both open), -1 unknown
  Votes last_;          // last single-low readings
  Votes since_;         // first single-low readings since both-open was taken or passed
  int closed_ = 0;      // both-low readings since then
  int open_ = 0;        // length of the current both-high phase
  int gap_ = 0;
  int before_ = 0;      // which line was low before that phase
  bool taken_ = false;  // that phase was already taken as a detent
  int passed_ = 0;      // line that was low before a both-high phase passed through
};

}  // namespace dd
