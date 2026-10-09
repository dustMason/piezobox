/*
  Piezo LC waveform capture, protocol PZLC1.
  Board: Teensy LC, USB Type: Serial, CPU: 48 MHz.
  This streams ADC samples over USB SERIAL; it is not a USB Audio device.
  No capture starts until the computer sends CAP <rate> <frames> <pins...>.
  Analog pins only: 14..26 = A0..A12 on Teensy LC.
  Uploading replaces the existing sketch. This does not fix input protection,
  clipping, bias, impedance, or anti-alias filtering in the physical circuit.
*/

#include <Arduino.h>
#include <IntervalTimer.h>
#include <stdlib.h>
#include <string.h>

#if !defined(__MKL26Z64__)
#error "Select Teensy LC. This initial firmware is intentionally LC-only."
#endif

constexpr uint8_t MAX_CHANNELS = 13;
constexpr uint8_t RING_SIZE = 64;  // one slot stays empty
constexpr uint8_t PACKET_FRAMES = 16;
constexpr uint8_t RING_MASK = RING_SIZE - 1;

IntervalTimer sampleTimer;
volatile uint16_t sampleRing[RING_SIZE][MAX_CHANNELS];
volatile uint32_t sequenceRing[RING_SIZE];
volatile uint8_t writeIndex = 0, readIndex = 0;
uint8_t pins[MAX_CHANNELS];
uint8_t channelCount = 0;
uint32_t sampleRate = 0, requestedFrames = 0;
uint32_t callbackBudgetUs = 0, lateThresholdUs = 0, startUs = 0;
volatile bool capturing = false, finished = false;
bool sessionActive = false, timerStopped = true;
volatile uint32_t attempted = 0, dropped = 0, slowCallbacks = 0;
volatile uint32_t lateIntervals = 0, maxCallbackUs = 0, maxIntervalUs = 0;
volatile uint32_t lastCallbackUs = 0, captureElapsedUs = 0, stopReason = 0;
uint8_t consecutiveSlow = 0;
bool havePreviousCallback = false;  // ISR owns this during capture
char command[160];
uint8_t commandLength = 0;
bool commandOverflow = false;

void put16(uint8_t *p, uint16_t n) {
  p[0] = n; p[1] = n >> 8;
}
void put32(uint8_t *p, uint32_t n) {
  p[0] = n; p[1] = n >> 8; p[2] = n >> 16; p[3] = n >> 24;
}

void sampleTick() {
  if (!capturing) return;
  const uint32_t began = micros();
  if (havePreviousCallback) {
    const uint32_t gap = began - lastCallbackUs;
    if (gap > maxIntervalUs) maxIntervalUs = gap;
    if (gap > lateThresholdUs) ++lateIntervals;
  }
  havePreviousCallback = true;
  lastCallbackUs = began;

  const uint32_t sequence = attempted++;
  const uint8_t slot = writeIndex;
  const uint8_t next = (slot + 1) & RING_MASK;
  if (next == readIndex) {
    ++dropped;
  } else {
    for (uint8_t ch = 0; ch < channelCount; ++ch) {
      // Discard a conversion after switching channels. This reduces, but does
      // not eliminate, settling errors from high source impedance.
      if (channelCount > 1) analogRead(pins[ch]);
      sampleRing[slot][ch] = analogRead(pins[ch]);
    }
    sequenceRing[slot] = sequence;
    // Publish only after all data has been written. Single producer/consumer:
    // main loop never frees a slot until it has copied the entire frame.
    __asm__ volatile("" ::: "memory");
    writeIndex = next;
  }

  const uint32_t duration = micros() - began;
  if (duration > maxCallbackUs) maxCallbackUs = duration;
  if (duration >= callbackBudgetUs) {
    ++slowCallbacks;
    ++consecutiveSlow;
  } else consecutiveSlow = 0;
  // An impossible channel/rate combination must not monopolize the CPU until
  // the full requested capture completes. Stop early and report the overload.
  if (consecutiveSlow >= 8) stopReason = 3;
  if (attempted >= requestedFrames || stopReason == 3) {
    capturing = false;
    captureElapsedUs = micros() - startUs;
    finished = true;
  }
}

void requestStop() {
  noInterrupts();
  capturing = false;
  stopReason = 1;
  captureElapsedUs = micros() - startUs;
  finished = true;
  interrupts();
}

void sendSamples() {
  uint8_t packet[8 + PACKET_FRAMES * (4 + 2 * MAX_CHANNELS)];
  uint16_t count = 0;
  size_t pos = 8;
  while (count < PACKET_FRAMES && readIndex != writeIndex) {
    const uint8_t slot = readIndex;
    put32(packet + pos, sequenceRing[slot]); pos += 4;
    for (uint8_t ch = 0; ch < channelCount; ++ch) {
      put16(packet + pos, sampleRing[slot][ch]); pos += 2;
    }
    __asm__ volatile("" ::: "memory");
    readIndex = (slot + 1) & RING_MASK;
    ++count;
  }
  if (!count) return;
  memcpy(packet, "PZD1", 4);
  put16(packet + 4, count);
  packet[6] = channelCount;
  packet[7] = 1;
  // All USB writes run outside the sampling interrupt.
  Serial.write(packet, pos);
}

void sendEnd() {
  uint8_t packet[36];
  memcpy(packet, "PZE1", 4);
  const uint32_t stats[8] = {
    attempted, dropped, slowCallbacks, lateIntervals,
    maxCallbackUs, maxIntervalUs, captureElapsedUs, stopReason
  };
  for (uint8_t i = 0; i < 8; ++i) put32(packet + 4 + 4 * i, stats[i]);
  Serial.write(packet, sizeof(packet));
  sessionActive = false;
  finished = false;
}

bool parseNumber(const char *s, uint32_t &value) {
  if (!s || !*s) return false;
  for (const char *p = s; *p; ++p) if (*p < '0' || *p > '9') return false;
  char *end = nullptr;
  value = strtoul(s, &end, 10);
  return end && !*end;
}

void handleCommand() {
  if (sessionActive) {
    if (!strcmp(command, "STOP")) requestStop();
    return;  // never insert ASCII responses into a binary capture
  }
  if (!strcmp(command, "INFO")) {
    Serial.println("PZLC1 Teensy-LC USB-serial ADC12; CAP rate frames pins; STOP");
    return;
  }
  char *token = strtok(command, " ,\t");
  if (!token || strcmp(token, "CAP")) {
    Serial.println("ERR expected CAP rate frames pins"); return;
  }
  uint32_t rate, frames;
  if (!parseNumber(strtok(nullptr, " ,\t"), rate) || rate < 250 || rate > 16000 ||
      !parseNumber(strtok(nullptr, " ,\t"), frames) || !frames || frames > rate * 600UL) {
    Serial.println("ERR rate 250..16000; duration at most 600 seconds"); return;
  }
  uint8_t n = 0;
  while ((token = strtok(nullptr, " ,\t"))) {
    uint32_t pin;
    if (n >= MAX_CHANNELS || !parseNumber(token, pin) || pin < 14 || pin > 26) {
      Serial.println("ERR use distinct LC analog pin numbers 14..26"); return;
    }
    for (uint8_t i = 0; i < n; ++i) {
      if (pins[i] == pin) { Serial.println("ERR duplicate pin"); return; }
    }
    pins[n++] = pin;
  }
  if (!n) { Serial.println("ERR no pins"); return; }

  channelCount = n;
  sampleRate = rate;
  requestedFrames = frames;
  callbackBudgetUs = (1000000UL + rate - 1) / rate;
  lateThresholdUs = (1500000UL + rate - 1) / rate;
  writeIndex = readIndex = 0;
  attempted = dropped = slowCallbacks = lateIntervals = 0;
  maxCallbackUs = maxIntervalUs = captureElapsedUs = stopReason = 0;
  havePreviousCallback = false;
  consecutiveSlow = 0;
  finished = false;

  analogReadResolution(12);
  analogReadAveraging(1);
  analogReference(DEFAULT);
  for (uint8_t i = 0; i < channelCount; ++i) analogRead(pins[i]);
  Serial.print("PZLC1 "); Serial.print(rate); Serial.print(' ');
  Serial.print(channelCount); Serial.print(' '); Serial.print(frames);
  for (uint8_t i = 0; i < channelCount; ++i) {
    Serial.print(' '); Serial.print(pins[i]);
  }
  Serial.println();
  Serial.flush();

  sessionActive = true;
  timerStopped = false;
  startUs = micros();
  capturing = true;
  if (!sampleTimer.begin(sampleTick, 1000000.0f / rate)) {
    capturing = false;
    finished = true;
    stopReason = 2;
  }
}

void setup() {
  Serial.begin(115200);  // USB baud setting does not determine transfer speed
}

void loop() {
  while (Serial.available()) {
    const char c = Serial.read();
    if (c == '\r') continue;
    if (c == '\n') {
      command[commandLength] = '\0';
      if (!commandOverflow) handleCommand();
      else if (!sessionActive) Serial.println("ERR command too long");
      commandLength = 0;
      commandOverflow = false;
    } else if (commandLength < sizeof(command) - 1) {
      command[commandLength++] = c;
    } else commandOverflow = true;
  }
  if (!sessionActive) return;
  if (finished && !timerStopped) {
    sampleTimer.end();
    timerStopped = true;
  }
  sendSamples();
  if (finished && readIndex == writeIndex) sendEnd();
}
