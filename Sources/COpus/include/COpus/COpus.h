// libopus for the Swift probe kit (plan §5.8, S5). The headers are
// those of the libopus the Go archive already carries (deps/opus,
// 1.5.2, BSD licence; see deps/opus/build/*/share). The symbols come
// from the Go archive's merged libopus.a on iOS (the Probe app links
// libprobe.xcframework) and from Homebrew's libopus on macOS
// (Package.swift links it there).
#ifndef LASA_PROBE_COPUS_H
#define LASA_PROBE_COPUS_H
#include "opus/opus.h"

// opus_encoder_ctl is variadic, which Swift cannot call; the two settings
// the probe uses, as plain functions.
int copus_set_bitrate(OpusEncoder *enc, opus_int32 bitrate);
int copus_set_complexity(OpusEncoder *enc, opus_int32 complexity);
#endif
