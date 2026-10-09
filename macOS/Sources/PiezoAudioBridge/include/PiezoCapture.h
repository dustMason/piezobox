#pragma once
#include <stdint.h>
typedef struct PZCapture PZCapture;
PZCapture* pz_capture_open(uint32_t device, uint32_t channels, int32_t* error);
void pz_capture_close(PZCapture* capture);
unsigned pz_capture_read(PZCapture* capture, float* interleaved, unsigned maxFrames);
uint64_t pz_capture_total(PZCapture* capture);
uint64_t pz_capture_dropped(PZCapture* capture);
uint64_t pz_capture_discontinuities(PZCapture* capture);
unsigned pz_capture_buffer_frames(PZCapture* capture);
