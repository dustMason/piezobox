#pragma once
#include <stdint.h>
#ifndef PIEZO_USB_CHANNELS
#define PIEZO_USB_CHANNELS 7
#endif
#ifndef PIEZO_USB_MONO_COMPANION
#define PIEZO_USB_MONO_COMPANION 0
#endif
#define PIEZO_USB_STREAMS (1 + PIEZO_USB_MONO_COMPANION)
#define PIEZO_USB_RATE 32000
#define PIEZO_USB_MAX_FRAMES 33
#ifdef __cplusplus
extern "C" {
#endif
extern volatile uint8_t piezo_usb_active[PIEZO_USB_STREAMS];
extern volatile uint32_t piezo_usb_packets[PIEZO_USB_STREAMS];
void piezo_audio_stream_changed(unsigned stream, unsigned active);
unsigned piezo_audio_fill(unsigned stream, int16_t *destination);
#ifdef __cplusplus
}
#endif
