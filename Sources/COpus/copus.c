// Non-variadic entry points for Swift (see COpus.h).
#include "COpus/COpus.h"

int copus_set_bitrate(OpusEncoder *enc, opus_int32 bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
}

int copus_set_complexity(OpusEncoder *enc, opus_int32 complexity) {
    return opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
}
