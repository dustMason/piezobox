/*
  Piezo LC capture v2: Teensy LC / USB Serial / 48 MHz.
  CAP rate frames pins...                 legacy finite PZLC1, <=16 kHz
  STREAM rate frames settled|fast pins...  packed PZLC2; frames=0 until STOP
  INFO / STOP. Rate is per input; the single ADC samples channels in order.
  Transport/timing checks do not establish analog settling or protection.
  See docs/protocol-v2.md.
*/
#include <Arduino.h>
#include <IntervalTimer.h>
#include <DMAChannel.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#if !defined(__MKL26Z64__)
#error "Select Teensy LC."
#endif

constexpr uint8_t MAX_CHANNELS = 13;
constexpr uint16_t SAMPLE_STORAGE = 1024;
constexpr uint8_t MAX_RING_FRAMES = 128, PACKET_FRAMES = 16;
// LC ADC channel IDs, A0..A12. Bit 0x40 denotes ADC mux A.
constexpr uint8_t PIN_CHANNELS[MAX_CHANNELS] = {5,14,8,9,13,12,6,7,15,11,0,68,23};
enum Profile : uint8_t { LEGACY, SETTLED, FAST };
IntervalTimer sampleTimer;
DMAChannel adcDMA, selectDMA;
uint32_t nextChannels[MAX_CHANNELS];
bool useDMA = false;
volatile bool dmaInFlight = false;
uint8_t dmaSlot = 0;
volatile uint16_t samples[SAMPLE_STORAGE];
volatile uint64_t sequences[MAX_RING_FRAMES];
volatile uint8_t writeIndex = 0, readIndex = 0;
uint8_t ringMask = MAX_RING_FRAMES - 1;
uint8_t pins[MAX_CHANNELS], adcChannels[MAX_CHANNELS], channelCount = 0;
uint32_t adcConfigs[MAX_CHANNELS], defaultCfg1, defaultCfg2;
bool mixedMux = false, discardFirst = true, protocol2 = false;
Profile profile = LEGACY;
uint32_t sampleRate = 0, callbackBudgetUs = 0, lateThresholdUs = 0;
uint64_t requestedFrames = 0;
volatile bool capturing = false, finished = false;
bool sessionActive = false, timerStopped = true;
volatile uint64_t attempted = 0, dropped = 0, slowCallbacks = 0, lateIntervals = 0;
volatile uint64_t elapsedAtTick = 0, captureElapsedUs = 0;
volatile uint32_t previousTickUs = 0, maxCallbackUs = 0, maxIntervalUs = 0, stopReason = 0;
bool havePreviousCallback = false;
uint8_t consecutiveSlow = 0;
uint32_t lastPacketMs = 0, lastStatsMs = 0;
char command[160];
uint8_t commandLength = 0;
bool commandOverflow = false;

void put16(uint8_t *p, uint16_t n) { p[0] = n; p[1] = n >> 8; }
void put32(uint8_t *p, uint32_t n) {
  p[0] = n; p[1] = n >> 8; p[2] = n >> 16; p[3] = n >> 24;
}
void put64(uint8_t *p, uint64_t n) { put32(p, n); put32(p + 4, n >> 32); }
void print64(uint64_t value) {
  char text[21]; char *p = text + sizeof(text); *--p = '\0';
  do { *--p = '0' + value % 10; value /= 10; } while (value);
  Serial.print(p);
}

// Bounded direct conversion: no analogRead/yield/interrupt masking in the loop.
__attribute__((always_inline)) inline uint16_t convertChannel(uint8_t channel) {
  ADC0_SC1A = channel;
  uint32_t timeout = 4096;
  while (!(ADC0_SC1A & ADC_SC1_COCO)) {
    if (!--timeout) { stopReason = 4; return 0; }
  }
  return ADC0_RA;
}

// The LC links every ADC-result transfer to one channel-select write, including
// the last transfer. The final select is 31 (ADC disabled), not another sample.
void startDMAScan(uint8_t slot) {
  selectDMA.CFG->DSR_BCR = DMA_DSR_BCR_DONE;
  selectDMA.CFG->SAR = nextChannels;
  selectDMA.CFG->DAR = &ADC0_SC1A;
  selectDMA.CFG->DSR_BCR = uint32_t(channelCount) * 4;
  selectDMA.CFG->DCR = DMA_DCR_CS | DMA_DCR_SINC;
  adcDMA.CFG->DSR_BCR = DMA_DSR_BCR_DONE;
  adcDMA.CFG->SAR = &ADC0_RA;
  adcDMA.CFG->DAR = samples + uint16_t(slot) * channelCount;
  adcDMA.CFG->DSR_BCR = uint32_t(channelCount) * 2;
  adcDMA.CFG->DCR = DMA_DCR_CS | DMA_DCR_ERQ | DMA_DCR_D_REQ |
      DMA_DCR_SSIZE(2) | DMA_DCR_DSIZE(2) | DMA_DCR_DINC |
      DMA_DCR_LINKCC(2) | DMA_DCR_LCH1(selectDMA.channel);
  dmaSlot = slot; dmaInFlight = true;
  ADC0_SC1A = adcChannels[0];
}

bool finishDMAScan() {
  if (!dmaInFlight) return true;
  if (adcDMA.error() || selectDMA.error()) stopReason = 4;
  else if (!adcDMA.complete() || !selectDMA.complete()) return false;
  if (stopReason) ++dropped;
  else {
    __asm__ volatile("" ::: "memory");
    writeIndex = (dmaSlot + 1) & ringMask;
  }
  dmaInFlight = false;
  return true;
}

void sampleTick() {
  if (!capturing) return;
  const uint32_t began = micros();
  const uint32_t interval = began - previousTickUs;
  elapsedAtTick += interval; // unsigned difference survives micros() wrap
  previousTickUs = began;
  if (havePreviousCallback) {
    if (interval > maxIntervalUs) maxIntervalUs = interval;
    if (interval > lateThresholdUs) ++lateIntervals;
  }
  havePreviousCallback = true;
  if (useDMA) {
    // Publish only complete scans. A scan still busy at the next frame is an
    // acquisition overrun; stop rather than emit mislabeled or stale samples.
    if (!finishDMAScan()) {
      ++slowCallbacks; ++dropped; dmaInFlight = false; stopReason = 4;
    }
    if (stopReason || (requestedFrames && attempted >= requestedFrames)) {
      capturing = false; captureElapsedUs = elapsedAtTick;
      finished = true; return;
    }
  }
  const uint64_t sequence = attempted++;
  const uint8_t slot = writeIndex, next = (slot + 1) & ringMask;
  if (next == readIndex) ++dropped;
  else {
    sequences[slot] = sequence;
    if (useDMA) startDMAScan(slot);
    else {
      volatile uint16_t *destination = samples + uint16_t(slot) * channelCount;
      for (uint8_t ch = 0; ch < channelCount; ++ch) {
        if (mixedMux) ADC0_CFG2 = adcConfigs[ch];
        if (discardFirst) convertChannel(adcChannels[ch]);
        destination[ch] = convertChannel(adcChannels[ch]);
      }
      __asm__ volatile("" ::: "memory");
      writeIndex = next;
    }
  }
  const uint32_t duration = micros() - began;
  if (duration > maxCallbackUs) maxCallbackUs = duration;
  if (duration >= callbackBudgetUs) { ++slowCallbacks; ++consecutiveSlow; }
  else consecutiveSlow = 0;
  if (consecutiveSlow >= 8) stopReason = 3;
  if ((!useDMA && requestedFrames && attempted >= requestedFrames) || stopReason) {
    capturing = false;
    captureElapsedUs = elapsedAtTick + duration;
    finished = true;
  }
}

void requestStop(uint32_t reason = 1) {
  noInterrupts(); capturing = false;
  const uint32_t began = micros();
  while (dmaInFlight && !finishDMAScan()) {
    if (uint32_t(micros() - began) > 100) {
      ++dropped; dmaInFlight = false; reason = 4; break;
    }
  }
  if (stopReason == 4) reason = 4;
  interrupts();
  captureElapsedUs = elapsedAtTick + uint32_t(micros() - previousTickUs);
  stopReason = reason;
  finished = true;
}

void sendSamples() {
  const uint8_t available = (writeIndex - readIndex) & ringMask;
  if (!available) return;
  if (available < PACKET_FRAMES && !finished && uint32_t(millis() - lastPacketMs) < 2) return;
  uint8_t packet[8 + PACKET_FRAMES * (4 + 2 * MAX_CHANNELS)];
  uint16_t count = 0, pendingSample = 0;
  bool havePendingSample = false;
  size_t pos = protocol2 ? 16 : 8;
  uint64_t firstSequence = 0;
  while (count < PACKET_FRAMES && readIndex != writeIndex) {
    const uint8_t slot = readIndex;
    const uint64_t sequence = sequences[slot];
    if (!count) firstSequence = sequence;
    if (protocol2 && sequence != firstSequence + count) break;
    if (!protocol2) { put32(packet + pos, uint32_t(sequence)); pos += 4; }
    const volatile uint16_t *source = samples + uint16_t(slot) * channelCount;
    for (uint8_t ch = 0; ch < channelCount; ++ch) {
      const uint16_t value = source[ch];
      if (!protocol2) { put16(packet + pos, value); pos += 2; }
      else if (!havePendingSample) { pendingSample = value; havePendingSample = true; }
      else {
        packet[pos++] = pendingSample;
        packet[pos++] = (pendingSample >> 8) | ((value & 15) << 4);
        packet[pos++] = value >> 4;
        havePendingSample = false;
      }
    }
    __asm__ volatile("" ::: "memory");
    readIndex = (slot + 1) & ringMask;
    ++count;
  }
  if (!count) return;
  if (havePendingSample) { packet[pos++] = pendingSample; packet[pos++] = pendingSample >> 8; }
  memcpy(packet, protocol2 ? "PZD2" : "PZD1", 4);
  put16(packet + 4, count);
  packet[6] = channelCount; packet[7] = protocol2 ? 12 : 1;
  if (protocol2) put64(packet + 8, firstSequence);
  const size_t sent = Serial.write(packet, pos);
  lastPacketMs = millis();
  if (sent != pos) requestStop(5);
}

void sendStats(bool finalPacket) {
  uint64_t a, d, s, l, elapsed;
  uint32_t maxTime, maxGap, reason, priorTick;
  bool running;
  noInterrupts();
  a = attempted; d = dropped; s = slowCallbacks; l = lateIntervals;
  maxTime = maxCallbackUs; maxGap = maxIntervalUs; reason = stopReason;
  running = capturing; priorTick = previousTickUs;
  elapsed = running ? elapsedAtTick : captureElapsedUs;
  interrupts();
  if (running) elapsed += uint32_t(micros() - priorTick);
  if (protocol2) {
    uint8_t packet[56];
    memcpy(packet, finalPacket ? "PZE2" : "PZS2", 4);
    put64(packet + 4, a); put64(packet + 12, d); put64(packet + 20, s);
    put64(packet + 28, l); put64(packet + 36, elapsed);
    put32(packet + 44, maxTime); put32(packet + 48, maxGap); put32(packet + 52, reason);
    if (Serial.write(packet, sizeof(packet)) != sizeof(packet)) requestStop(5);
  } else {
    uint8_t packet[36]; memcpy(packet, "PZE1", 4);
    const uint32_t stats[8] = {uint32_t(a), uint32_t(d), uint32_t(s), uint32_t(l),
                              maxTime, maxGap, uint32_t(elapsed), reason};
    for (uint8_t i = 0; i < 8; ++i) put32(packet + 4 + 4 * i, stats[i]);
    Serial.write(packet, sizeof(packet));
  }
  lastStatsMs = millis();
  if (finalPacket) { sessionActive = false; finished = false; }
}

bool parseNumber(const char *text, uint64_t &value) {
  if (!text || !*text) return false;
  for (const char *p = text; *p; ++p) if (*p < '0' || *p > '9') return false;
  errno = 0;
  char *end = nullptr; value = strtoull(text, &end, 10);
  return !errno && end && !*end;
}

void configureADC() {
  adcDMA.disable(); selectDMA.disable();
  dmaInFlight = false;
  ADC0_SC1A = 31; // disable/abort any prior conversion
  ADC0_SC2 = ADC_SC2_REFSEL(1); // LC VDDA (3.3 V), software trigger, no DMA
  ADC0_SC3 = 0; // no averaging or continuous-conversion mode
  ADC0_CFG1 = defaultCfg1;
  uint32_t cfg2 = defaultCfg2;
  if (profile != LEGACY) {
    // 16 MHz OSCERCLK, within the <=13-bit 18 MHz limit with ADHSC set.
    ADC0_CFG1 = ADC_CFG1_ADICLK(2) | ADC_CFG1_MODE(1) |
                (profile == SETTLED ? ADC_CFG1_ADLSMP : 0);
    cfg2 = ADC_CFG2_ADHSC | ADC_CFG2_ADLSTS(0);
  }
  discardFirst = channelCount > 1 && profile != FAST;
  mixedMux = false;
  const bool firstMuxA = (PIN_CHANNELS[pins[0] - 14] & 64) != 0;
  for (uint8_t i = 0; i < channelCount; ++i) {
    const uint8_t selected = PIN_CHANNELS[pins[i] - 14];
    adcChannels[i] = selected & 31;
    adcConfigs[i] = (cfg2 & ~ADC_CFG2_MUXSEL) | ((selected & 64) ? 0 : ADC_CFG2_MUXSEL);
    if (((selected & 64) != 0) != firstMuxA) mixedMux = true;
    ADC0_CFG2 = adcConfigs[i];
    convertChannel(adcChannels[i]);
  }
  ADC0_CFG2 = adcConfigs[0];
  useDMA = profile == FAST && !mixedMux;
  if (useDMA) {
    for (uint8_t i = 0; i < channelCount; ++i)
      nextChannels[i] = i + 1 < channelCount ? adcChannels[i + 1] : 31;
    adcDMA.triggerAtHardwareEvent(DMAMUX_SOURCE_ADC0);
    ADC0_SC1A = 31;
    ADC0_SC2 |= ADC_SC2_DMAEN;
  }
}

void handleCommand() {
  if (sessionActive) { if (!strcmp(command, "STOP")) requestStop(); return; }
  if (!strcmp(command, "INFO")) {
    Serial.println("PZLC1 Teensy-LC USB-serial ADC12; FW=2; CAP rate frames pins; STREAM rate frames settled|fast pins; STOP");
    return;
  }
  if (!strcmp(command, "STOP")) return;
  char *token = strtok(command, " ,\t");
  if (!token || (strcmp(token, "CAP") && strcmp(token, "STREAM"))) {
    Serial.println("ERR expected CAP or STREAM"); return;
  }
  protocol2 = !strcmp(token, "STREAM");
  uint64_t rate, frames;
  if (!parseNumber(strtok(nullptr, " ,\t"), rate) || rate < 250 || rate > (protocol2 ? 96000UL : 16000UL) ||
      !parseNumber(strtok(nullptr, " ,\t"), frames) ||
      (!protocol2 && (!frames || frames > rate * 600ULL))) {
    Serial.println("ERR invalid rate/frame count"); return;
  }
  profile = LEGACY;
  if (protocol2) {
    token = strtok(nullptr, " ,\t");
    if (token && !strcmp(token, "settled")) profile = SETTLED;
    else if (token && !strcmp(token, "fast")) profile = FAST;
    else { Serial.println("ERR profile must be settled or fast"); return; }
  }
  uint8_t count = 0;
  while ((token = strtok(nullptr, " ,\t"))) {
    uint64_t pin;
    if (count >= MAX_CHANNELS || !parseNumber(token, pin) || pin < 14 || pin > 26) {
      Serial.println("ERR use distinct LC analog pins 14..26"); return;
    }
    for (uint8_t i = 0; i < count; ++i) if (pins[i] == pin) { Serial.println("ERR duplicate pin"); return; }
    pins[count++] = pin;
  }
  if (!count) { Serial.println("ERR no pins"); return; }
  channelCount = count; sampleRate = rate; requestedFrames = frames;
  uint8_t capacity = MAX_RING_FRAMES;
  while (uint16_t(capacity) * channelCount > SAMPLE_STORAGE) capacity >>= 1;
  ringMask = capacity - 1;
  callbackBudgetUs = (1000000UL + sampleRate - 1) / sampleRate;
  lateThresholdUs = (1500000UL + sampleRate - 1) / sampleRate;
  writeIndex = readIndex = 0;
  attempted = dropped = slowCallbacks = lateIntervals = 0;
  elapsedAtTick = captureElapsedUs = 0;
  maxCallbackUs = maxIntervalUs = stopReason = 0;
  havePreviousCallback = false; consecutiveSlow = 0; finished = false;
  configureADC();
  if (stopReason) { Serial.println("ERR ADC did not complete a conversion"); return; }
  Serial.print(protocol2 ? "PZLC2 " : "PZLC1 ");
  Serial.print(sampleRate); Serial.print(' '); Serial.print(channelCount); Serial.print(' ');
  print64(requestedFrames);
  if (protocol2) Serial.print(profile == SETTLED ? " settled" : " fast");
  for (uint8_t i = 0; i < channelCount; ++i) { Serial.print(' '); Serial.print(pins[i]); }
  Serial.println(); Serial.flush();
  sessionActive = true; timerStopped = false;
  lastPacketMs = lastStatsMs = millis();
  previousTickUs = micros();
  capturing = true;
  sampleTimer.priority(32);
  if (!sampleTimer.begin(sampleTick, 1000000.0f / sampleRate)) {
    capturing = false; finished = true; stopReason = 2;
  }
}

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);
  analogReadAveraging(1);
  analogReference(DEFAULT);
  analogRead(A0); // finish the core's calibration before direct ADC access
  defaultCfg1 = ADC0_CFG1; defaultCfg2 = ADC0_CFG2;
}

void loop() {
  while (Serial.available()) {
    const char c = Serial.read();
    if (c == '\r') continue;
    if (c == '\n') {
      command[commandLength] = '\0';
      if (!commandOverflow && commandLength) handleCommand();
      else if (commandOverflow && !sessionActive) Serial.println("ERR command too long");
      commandLength = 0; commandOverflow = false;
    } else if (commandLength < sizeof(command) - 1) command[commandLength++] = c;
    else commandOverflow = true;
  }
  if (!sessionActive) return;
  if (finished && !timerStopped) {
    sampleTimer.end(); timerStopped = true;
    if (dmaInFlight) { ++dropped; dmaInFlight = false; }
    adcDMA.disable(); selectDMA.disable();
    ADC0_SC2 &= ~ADC_SC2_DMAEN; ADC0_SC1A = 31;
  }
  sendSamples();
  if (finished && readIndex == writeIndex) sendStats(true);
  else if (protocol2 && uint32_t(millis() - lastStatsMs) >= 1000) sendStats(false);
}
