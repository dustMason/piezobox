// Included by the isolated Teensy USB core. No stock audio library is linked.
#include "piezo_usb_audio.h"
volatile uint8_t piezo_usb_active[PIEZO_USB_STREAMS];
volatile uint32_t piezo_usb_packets[PIEZO_USB_STREAMS];
static uint8_t piezo_next_bank[PIEZO_USB_STREAMS];
static int16_t piezo_primary_buffers[2][PIEZO_USB_MAX_FRAMES * PIEZO_USB_CHANNELS] __attribute__((aligned(4)));
#if PIEZO_USB_MONO_COMPANION
static int16_t piezo_mono_buffers[2][PIEZO_USB_MAX_FRAMES] __attribute__((aligned(4)));
#endif
static int piezo_stream_for_endpoint(unsigned ep) {
    return ep >= 5 && ep < 5 + PIEZO_USB_STREAMS ? (int)(ep - 5) : -1;
}
static int piezo_stream_for_interface(unsigned interface) {
    return interface == 3 ? 0 : (PIEZO_USB_MONO_COMPANION && interface == 5 ? 1 : -1);
}
static void piezo_prime(unsigned stream) {
    unsigned bank = piezo_next_bank[stream];
    int16_t *buffer = piezo_primary_buffers[bank];
#if PIEZO_USB_MONO_COMPANION
    if (stream) buffer = piezo_mono_buffers[bank];
#endif
    unsigned bytes = piezo_audio_fill(stream, buffer);
    unsigned max_bytes = PIEZO_USB_MAX_FRAMES * (stream ? 1 : PIEZO_USB_CHANNELS) * 2;
    if (bytes > max_bytes) bytes = 0;
    bdt_t *b = &table[index(stream + 5, TX, bank)];
    b->addr = buffer;
    b->desc = (bytes << 16) | BDT_OWN;
}
static void piezo_set_stream(unsigned stream, unsigned active) {
    volatile uint8_t *endpoint = &USB0_ENDPT0 + (stream + 5) * 4;
    *endpoint = 0;
    table[index(stream + 5, TX, EVEN)].desc = 0;
    table[index(stream + 5, TX, ODD)].desc = 0;
    piezo_usb_active[stream] = active;
    piezo_audio_stream_changed(stream, active);
    *endpoint = ENDPOINT_TRANSMIT_ISOCHRONOUS;
    if (active) piezo_prime(stream);
}
static void piezo_reset_streams(unsigned reset_banks) {
    for (unsigned i = 0; i < PIEZO_USB_STREAMS; ++i) {
        piezo_usb_active[i] = 0;
        if (reset_banks) piezo_next_bank[i] = 0;
        piezo_audio_stream_changed(i, 0);
        table[index(i + 5, TX, EVEN)].desc = 0;
        table[index(i + 5, TX, ODD)].desc = 0;
    }
}
