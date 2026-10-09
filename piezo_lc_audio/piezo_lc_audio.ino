/* Teensy LC class-compliant USB Audio capture, 32 kHz, ADC pins A1..A7.
 * Build with tools/build_usb_audio.py; the USB core is patched in an isolated copy.
 * CDC diagnostics and the Teensy 134-baud bootloader request remain available.
 */
#include <Arduino.h>
#include <IntervalTimer.h>
#include <DMAChannel.h>
#include <string.h>
#include "piezo_usb_audio.h"
#if !defined(__MKL26Z64__)
#error Teensy LC only
#endif
#ifndef PIEZO_PROTOTYPE
#define PIEZO_PROTOTYPE 0
#endif
extern "C" void _reboot_Teensyduino_(void);

constexpr unsigned CHANNELS = 7, RING_FRAMES = 128;
// Pins 15..21 = A1..A7, all in ADC mux bank B. Complete jack mapping is provisional.
constexpr uint8_t adcChannels[CHANNELS] = {14,8,9,13,12,6,7};
DMAChannel resultDMA, selectDMA;
IntervalTimer timer;
uint32_t nextChannels[CHANNELS];
volatile uint16_t rawScan[CHANNELS];
volatile int16_t audioRing[RING_FRAMES][CHANNELS];
volatile uint32_t writtenFrames = 0;
volatile bool ready = false;
volatile bool testPattern = false;
bool pending = false, meanReady = false, confirmed = !PIEZO_PROTOTYPE;
int32_t mean[CHANNELS];
volatile uint32_t adcFaults = 0, lateTicks = 0, maxTickGap = 0, maxTickTime = 0;
uint32_t priorTick = 0;
volatile uint32_t readFrames[PIEZO_USB_STREAMS];
volatile uint32_t sentFrames[PIEZO_USB_STREAMS], underflows[PIEZO_USB_STREAMS], overflows[PIEZO_USB_STREAMS];
volatile uint32_t startupPackets[PIEZO_USB_STREAMS];
volatile uint32_t startupDiscarded[PIEZO_USB_STREAMS];
volatile uint8_t primed[PIEZO_USB_STREAMS];
char command[64]; unsigned commandLength = 0;
bool commandOverflow = false;

void beginScan() {
    selectDMA.CFG->DSR_BCR = DMA_DSR_BCR_DONE;
    selectDMA.CFG->SAR = nextChannels;
    selectDMA.CFG->DAR = &ADC0_SC1A;
    selectDMA.CFG->DSR_BCR = CHANNELS * 4;
    selectDMA.CFG->DCR = DMA_DCR_CS | DMA_DCR_SINC;
    resultDMA.CFG->DSR_BCR = DMA_DSR_BCR_DONE;
    resultDMA.CFG->SAR = &ADC0_RA;
    resultDMA.CFG->DAR = rawScan;
    resultDMA.CFG->DSR_BCR = CHANNELS * 2;
    resultDMA.CFG->DCR = DMA_DCR_CS | DMA_DCR_ERQ | DMA_DCR_D_REQ |
        DMA_DCR_SSIZE(2) | DMA_DCR_DSIZE(2) | DMA_DCR_DINC |
        DMA_DCR_LINKCC(2) | DMA_DCR_LCH1(selectDMA.channel);
    pending = true; ADC0_SC1A = adcChannels[0];
}

void sampleTick() {
    uint32_t began = micros(), gap = began - priorTick;
    if (priorTick) { if (gap > maxTickGap) maxTickGap = gap; if (gap > 47) ++lateTicks; }
    priorTick = began;
    if (pending) {
        if (resultDMA.error() || selectDMA.error() || !resultDMA.complete() || !selectDMA.complete()) {
            ++adcFaults;
            ADC0_SC1A = 31; resultDMA.disable(); selectDMA.disable();
            pending = false; return;
        }
        unsigned slot = writtenFrames & (RING_FRAMES - 1);
        for (unsigned ch = 0; ch < CHANNELS; ++ch) {
            // DC removal: 1-pole ~20 Hz high-pass, Q16 state; no FPU needed.
            // 12-bit ADC counts map to 16-bit signed PCM with 8 PCM units/count.
            int32_t x = int32_t(rawScan[ch]) << 16;
            if (!meanReady) mean[ch] = x;
            mean[ch] += (x - mean[ch]) >> 8;
            int32_t pcm = (x - mean[ch]) >> 13;
            audioRing[slot][ch] = int16_t(pcm > 32767 ? 32767 : pcm < -32768 ? -32768 : pcm);
        }
        meanReady = true;
        __asm__ volatile("" ::: "memory");
        ++writtenFrames;
    }
    beginScan();
    uint32_t duration = micros() - began;
    if (duration > maxTickTime) maxTickTime = duration;
}

// Called only in USB interrupt context. ADC publication uses an independent,
// monotonic counter; each audio endpoint has its own reader into the same ring.
extern "C" void piezo_audio_stream_changed(unsigned stream, unsigned active) {
    primed[stream] = 0;
    if (active) {
        readFrames[stream] = writtenFrames;
        sentFrames[stream] = underflows[stream] = overflows[stream] = startupPackets[stream] = 0;
        startupDiscarded[stream] = 0;
        piezo_usb_packets[stream] = 0;
    }
}
extern "C" unsigned piezo_audio_fill(unsigned stream, int16_t *destination) {
    const unsigned channels = stream ? 1 : PIEZO_USB_CHANNELS;
    uint32_t head = writtenFrames, tail = readFrames[stream];
    uint32_t available = head - tail;
    if (!ready || (!primed[stream] && available < 64)) {
        memset(destination, 0, 32 * channels * sizeof(int16_t));
        ++startupPackets[stream]; return 32 * channels * sizeof(int16_t);
    }
    if (!primed[stream]) {
        // SET_INTERFACE can precede the host's first IN transaction by several
        // milliseconds. Start from recent data; count that separately from loss
        // during a running stream.
        startupDiscarded[stream] = available - 64;
        tail = head - 64; available = 64;
        primed[stream] = 1;
    }
    if (available > 100) {
        overflows[stream] += available - 64;
        tail = head - 64; available = 64;
    }
    // Asynchronous USB source: adapt packet frame count to actual ADC production,
    // keeping about one millisecond in reserve instead of silently dropping clock drift.
    unsigned count = available > 80 ? 33 : available < 48 ? 31 : 32;
    if (available < count) { underflows[stream] += count - available; count = available; }
    for (unsigned frame = 0; frame < count; ++frame) {
        const volatile int16_t *source = audioRing[(tail + frame) & (RING_FRAMES - 1)];
        if (testPattern) {
            uint32_t sequence = tail + frame;
            for (unsigned ch = 0; ch < channels; ++ch)
                *destination++ = ch == 0 ? (sequence & 255) : ch == 1 ? ((sequence >> 8) & 255) : ((sequence * 13 + ch * 17) & 255);
        } else if (channels == 7) {
            for (unsigned ch = 0; ch < 7; ++ch) *destination++ = source[ch];
        } else {
            int32_t mix = 0;
            for (unsigned ch = 0; ch < 7; ++ch) mix += source[ch];
            *destination++ = int16_t(mix / 7);
        }
    }
    readFrames[stream] = tail + count;
    sentFrames[stream] += count;
    return count * channels * sizeof(int16_t);
}

void printStatus() {
    Serial.print("{\"protocol\":\"PZUA1\",\"rate\":32000,\"channels\":"); Serial.print(PIEZO_USB_CHANNELS);
    Serial.print(",\"streams\":"); Serial.print(PIEZO_USB_STREAMS);
    Serial.print(",\"prototype\":"); Serial.print(PIEZO_PROTOTYPE);
    Serial.print(",\"confirmed\":"); Serial.print(confirmed ? 1 : 0);
    Serial.print(",\"test_pattern\":"); Serial.print(testPattern ? 1 : 0);
    Serial.print(",\"adc_frames\":"); Serial.print(writtenFrames);
    Serial.print(",\"adc_faults\":"); Serial.print(adcFaults);
    Serial.print(",\"late_ticks\":"); Serial.print(lateTicks);
    Serial.print(",\"max_tick_us\":"); Serial.print(maxTickTime);
    Serial.print(",\"max_tick_gap_us\":"); Serial.print(maxTickGap);
    Serial.print(",\"raw\":[");
    for (unsigned ch = 0; ch < CHANNELS; ++ch) { if (ch) Serial.print(','); Serial.print(rawScan[ch]); }
    Serial.print("],\"audio\":[");
    for (unsigned i = 0; i < PIEZO_USB_STREAMS; ++i) {
        if (i) Serial.print(',');
        Serial.print("{\"active\":"); Serial.print(piezo_usb_active[i]);
        Serial.print(",\"packets\":"); Serial.print(piezo_usb_packets[i]);
        Serial.print(",\"frames\":"); Serial.print(sentFrames[i]);
        Serial.print(",\"underflows\":"); Serial.print(underflows[i]);
        Serial.print(",\"overflows\":"); Serial.print(overflows[i]);
        Serial.print(",\"startup_packets\":"); Serial.print(startupPackets[i]);
        Serial.print(",\"startup_discarded\":"); Serial.print(startupDiscarded[i]); Serial.print('}');
    }
    Serial.println("]}");
}
void setup() {
    analogReadResolution(12); analogReadAveraging(1); analogReference(DEFAULT);
    analogRead(A0); // Finish the core's ADC calibration before using its registers.
    ADC0_SC1A = 31;
    ADC0_CFG1 = ADC_CFG1_ADICLK(2) | ADC_CFG1_MODE(1); // 16 MHz OSCERCLK, 12-bit, short sample.
    ADC0_CFG2 = ADC_CFG2_ADHSC | ADC_CFG2_MUXSEL;
    ADC0_SC2 = ADC_SC2_REFSEL(1) | ADC_SC2_DMAEN;
    ADC0_SC3 = 0;
    for (unsigned i = 0; i < CHANNELS; ++i) nextChannels[i] = i + 1 < CHANNELS ? adcChannels[i + 1] : 31;
    resultDMA.triggerAtHardwareEvent(DMAMUX_SOURCE_ADC0);
    timer.priority(32);
    ready = timer.begin(sampleTick, 31.25f);
}
void loop() {
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\r') continue;
        if (c == '\n') {
            command[commandLength] = 0;
            if (!commandOverflow) {
                if (!strcmp(command, "INFO")) Serial.println("PZUA1 Teensy-LC USB Audio; ADC7 32000 PCM16; STATUS CONFIRM REBOOT TEST_ON TEST_OFF");
                else if (!strcmp(command, "STATUS")) printStatus();
                else if (!strcmp(command, "CONFIRM")) { confirmed = true; Serial.println("OK"); }
                else if (!strcmp(command, "TEST_ON")) { testPattern = true; Serial.println("OK"); }
                else if (!strcmp(command, "TEST_OFF")) { testPattern = false; Serial.println("OK"); }
                else if (!strcmp(command, "REBOOT")) _reboot_Teensyduino_();
                else if (commandLength && strcmp(command, "STOP")) Serial.println("ERR expected INFO STATUS CONFIRM REBOOT");
            }
            commandLength = 0; commandOverflow = false;
        } else if (commandLength < sizeof(command) - 1) command[commandLength++] = c;
        else commandOverflow = true;
    }
    if (PIEZO_PROTOTYPE && !confirmed && millis() > 90000) _reboot_Teensyduino_();
}
