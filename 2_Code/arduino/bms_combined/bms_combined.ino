// bms_combined.ino - 4S BMS: monitor, passive balancing or active balancing, chosen over serial.
//
// Hardware (hardware/arduino/HARDWARE_SPEC.md):
//   Arduino Mega 2560, ADS1115 (I2C 0x48), 4 x DS18B20 on pin 2
//   Passive: 4 relays on pins 22-25 (active-LOW), 47 ohm bleed resistor per cell
//   Active : 4 SPDT relays on pins 26-29 (active-LOW), 3 x 470 uF flying capacitors + 4.7 ohm
//
// Serial commands at 115200 baud (send with newline; upper or lower case):
//   p / passive   start passive balancing
//   a / active    start active balancing
//   o / off       monitor only, all balancing outputs off
//   s / stop      emergency stop (latched like a fault)
//   r / reset     clear a latched fault or stop once readings are back in range
//   h / ?         print help and current state
//
// One CSV row per second. Lines starting with '#' are messages, not data.
// Columns:
//   timestamp_ms,elapsed_sec,v1,v2,v3,v4,vpack,spread_mV,t1,t2,t3,t4,shuttles,phase,status,mode,b1,b2,b3,b4,sc_on,fault
//   phase  : IDLE (nothing to do / off), RUN (balancing), REST (outputs off, letting voltages settle)
//   status : OK, WARN, FAULT
//   mode   : OFF, PASSIVE, ACTIVE
//   b1..b4 : 1 when that cell's bleed relay was on during the second before the row
//   sc_on  : 1 when the active relays were shuttling during that second
//   fault  : NONE, OV, UV, OT, TSENSOR, STOP
// A failed or missing temperature reading is logged as -127.
//
// Indicators (all optional extras use otherwise unused pins):
//   D13 LED   : solid = FAULT/STOP latched, blinking = alert (WARN), off = OK
//   D9  LED   : alert light, on for any alert or fault (connect LED + 330 ohm to GND)
//   D8 buzzer : continuous = FAULT/STOP, short chirp every 5 s = low-voltage alert
//   D3 button : manual stop, push-button to GND (internal pull-up; unconnected = inactive)
// Alerts (status WARN, a "# ALERT ..." line is printed when they start and clear):
//   LOWV  a cell below 3.30 V (any mode; balancing is blocked)
//   TEMP  a sensor above 45 C (balancing pauses)
//   JUMP  a rested reading moved more than 30 mV in one step (loose sense wire?)
//   PAIR  active mode refused: neighbouring cells more than 300 mV apart
//
// Every row describes the second that just ended: the outputs shown were applied while it was measured.

#include <Wire.h>
#include <Adafruit_ADS1X15.h>
#include <OneWire.h>
#include <DallasTemperature.h>

// ============================================================================ pins
const uint8_t ONEWIRE_PIN = 2;
const uint8_t BUZZER_PIN  = 8;
const uint8_t LED_FAULT   = 13;
const uint8_t ALERT_LED   = 9;    // external alert light (optional)
const uint8_t STOP_BTN    = 3;    // manual stop button to GND (optional)
const uint8_t BLEED_RELAYS[4]  = {22, 23, 24, 25};
const uint8_t ACTIVE_RELAYS[4] = {26, 27, 28, 29};
const uint8_t RELAY_ON  = LOW;    // relay boards are active-LOW
const uint8_t RELAY_OFF = HIGH;

// ============================================================================ measurement
const float   DIV   = 4.0;        // divider (33k + 11k) / 11k = 4.0; fine-tune per channel with gain[]/offs[]
// per-channel calibration against a multimeter (hardware/calibration/, 17 Nov 2026):
// errors before calibration -36 / +33 / -48 / +45 mV, after +-1 mV
float gain[4] = {1.0094, 0.9915, 1.0126, 0.9884};
float offs[4] = {0.001, -0.002, 0.000, 0.001};   // V
const uint8_t N_AVG = 4;          // ADC samples averaged per reading

// ============================================================================ protection
const float V_FAULT_HIGH = 4.35;
const float V_FAULT_LOW  = 2.80;
const float T_WARN       = 45.0;  // balancing pauses above this
const float T_FAULT      = 55.0;
const float V_BAL_MIN    = 3.30;  // no balancing when any cell is below this
const float V_LOW_ALERT  = 3.30;  // low-voltage alert threshold (all modes)
const uint8_t T_FAIL_LIMIT = 2;   // consecutive failed temperature reads before a fault

// ============================================================================ balancing
const float DV_ON_MV       = 15.0;   // start when the difference is above this
const float DV_OFF_MV      = 10.0;   // stop when it is at or below this
const float DV_PAIR_MAX_MV = 300.0;  // active: refuse to shuttle a pair this far apart
const float JUMP_WARN_MV   = 30.0;   // rested reading moved this much in one step -> WARN (loose wire?)

const uint8_t PASSIVE_RUN_S  = 10;   // spec: 10 s bleed, 5 s rest
const uint8_t PASSIVE_REST_S = 5;
const uint8_t ACTIVE_RUN_S   = 30;
const uint8_t ACTIVE_REST_S  = 5;
const uint8_t SETTLE_S       = 3;    // outputs off this long before a reading counts as rested
const uint16_t RELAY_PHASE_MS = 500; // active relay position time (one shuttle = 2 positions)
const uint32_t LOG_PERIOD_MS  = 1000;

// ============================================================================ state
enum Mode  : uint8_t { M_OFF, M_PASSIVE, M_ACTIVE };
enum Phase : uint8_t { P_IDLE, P_RUN, P_REST };
const char* const MODE_STR[]  = {"OFF", "PASSIVE", "ACTIVE"};
const char* const PHASE_STR[] = {"IDLE", "RUN", "REST"};

Adafruit_ADS1115 ads;
OneWire ow(ONEWIRE_PIN);
DallasTemperature ds(&ow);
DeviceAddress tAddr[4];
uint8_t tCount = 0;
uint8_t tFailCount = 0;

Mode  mode  = M_OFF;
Phase phase = P_IDLE;
uint8_t phaseSec = 0;
uint8_t quietSec = 0;

bool sel[4]     = {false, false, false, false};  // passive: cells chosen at the last rested decision
bool bleedOut[4] = {false, false, false, false}; // passive: relays actually on
bool scSel      = false;                         // active: chosen at the last rested decision
bool scRunning  = false;                         // active: relays actually shuttling
bool relayB     = false;                         // active relay position (false = NC, true = NO)
uint32_t lastFlip = 0;
uint32_t shuttles = 0;

bool faultLatched = false;
const char* faultCode = "NONE";
bool conditionsOk = true;

bool  havePrev = false;
float vPrev[4];

uint32_t startMs = 0;
uint32_t nextTick = 0;

// alert bits
const uint8_t A_LOWV = 1, A_TEMP = 2, A_JUMP = 4, A_PAIR = 8;
uint8_t  alerts = 0, prevAlerts = 0;
bool     blinkState = false;
uint32_t buzzerOffAt = 0;
uint8_t  chirpTimer = 0;
uint32_t stopLowSince = 0;

char cmdBuf[24];
uint8_t cmdLen = 0;

// ============================================================================ outputs
void applyBleed() {
  for (uint8_t i = 0; i < 4; i++)
    digitalWrite(BLEED_RELAYS[i], (bleedOut[i] && !faultLatched) ? RELAY_ON : RELAY_OFF);
}

// De-energised (NC): capacitors across cells 1-3. Energised (NO): across cells 2-4.
// SPDT relays have no open position, so "off" leaves the capacitors parked across cells 1-3.
void setActiveRelays(bool energised) {
  for (uint8_t i = 0; i < 4; i++)
    digitalWrite(ACTIVE_RELAYS[i], energised ? RELAY_ON : RELAY_OFF);
}

void scStart() {
  relayB = false;
  setActiveRelays(false);
  lastFlip = millis();
  scRunning = true;
}

void scStop() {
  scRunning = false;
  relayB = false;
  setActiveRelays(false);
}

void outputsOff() {
  for (uint8_t i = 0; i < 4; i++) bleedOut[i] = false;
  applyBleed();
  scStop();
}

void clearSelection() {
  for (uint8_t i = 0; i < 4; i++) sel[i] = false;
  scSel = false;
}

// Called as often as possible from loop(): flips the active relays every RELAY_PHASE_MS.
void serviceRelays() {
  if (!scRunning) return;
  uint32_t now = millis();
  if (now - lastFlip >= RELAY_PHASE_MS) {
    lastFlip = now;
    relayB = !relayB;
    setActiveRelays(relayB);
    if (!relayB) shuttles++;     // a full shuttle = NC -> NO -> NC
  }
}

// ============================================================================ measurement
void readCells(float v[4]) {
  float acc[4] = {0, 0, 0, 0};
  for (uint8_t n = 0; n < N_AVG; n++) {
    acc[0] +=  ads.computeVolts(ads.readADC_SingleEnded(0));
    acc[1] += -ads.computeVolts(ads.readADC_Differential_0_1());
    acc[2] += -ads.computeVolts(ads.readADC_Differential_1_3());
    acc[3] +=  ads.computeVolts(ads.readADC_Differential_2_3());
    serviceRelays();             // keep relay timing while the ADC is busy
  }
  for (uint8_t i = 0; i < 4; i++) v[i] = gain[i] * (acc[i] / N_AVG * DIV) + offs[i];
}

// Non-blocking: reads the conversion started on the previous tick, then starts the next one.
bool readTemps(float t[4]) {
  bool fail = false;
  for (uint8_t i = 0; i < 4; i++) {
    t[i] = -127.0;
    if (i < tCount) {
      float x = ds.getTempC(tAddr[i]);
      if (x == DEVICE_DISCONNECTED_C || x == 85.0) fail = true;
      else t[i] = x;
    }
    serviceRelays();
  }
  ds.requestTemperatures();
  return fail;
}

// ============================================================================ faults and modes
void tripFault(const char* code) {
  faultLatched = true;
  faultCode = code;
  outputsOff();
  clearSelection();
  mode = M_OFF;
  phase = P_IDLE;
  phaseSec = 0;
  digitalWrite(LED_FAULT, HIGH);
  digitalWrite(ALERT_LED, HIGH);
  digitalWrite(BUZZER_PIN, HIGH);
  buzzerOffAt = 0;
  Serial.print(F("# FAULT "));
  Serial.print(code);
  Serial.println(F(": all balancing off. Fix the cause then send r"));
}

void setMode(Mode m) {
  if (faultLatched) {
    Serial.print(F("# refused: fault latched ("));
    Serial.print(faultCode);
    Serial.println(F("). Send r first"));
    return;
  }
  outputsOff();
  clearSelection();
  mode = m;
  phase = (m == M_OFF) ? P_IDLE : P_REST;   // always start with a rest so the first decision is clean
  phaseSec = 0;
  Serial.print(F("# mode -> "));
  Serial.println(MODE_STR[m]);
}

void printHelp() {
  Serial.println(F("# commands: p=passive  a=active  o=off  s=stop  r=reset  h=help  (stop button on D3)"));
  Serial.print(F("# mode "));       Serial.print(MODE_STR[mode]);
  Serial.print(F("  phase "));      Serial.print(PHASE_STR[phase]);
  Serial.print(F("  fault "));      Serial.print(faultLatched ? faultCode : "NONE");
  Serial.print(F("  temp sensors ")); Serial.println(tCount);
}

void handleCommand(char* c) {
  for (char* p = c; *p; p++) *p = tolower(*p);
  if (!strcmp(c, "p") || !strcmp(c, "passive")) setMode(M_PASSIVE);
  else if (!strcmp(c, "a") || !strcmp(c, "active")) setMode(M_ACTIVE);
  else if (!strcmp(c, "o") || !strcmp(c, "off") || !strcmp(c, "m") || !strcmp(c, "monitor")) setMode(M_OFF);
  else if (!strcmp(c, "s") || !strcmp(c, "stop")) tripFault("STOP");
  else if (!strcmp(c, "r") || !strcmp(c, "reset")) {
    if (!faultLatched) Serial.println(F("# nothing to reset"));
    else if (!conditionsOk) Serial.println(F("# reset refused: readings still out of range"));
    else {
      faultLatched = false;
      faultCode = "NONE";
      digitalWrite(BUZZER_PIN, LOW);
      digitalWrite(LED_FAULT, LOW);
      digitalWrite(ALERT_LED, LOW);
      Serial.println(F("# fault cleared, mode OFF. Send p or a to start"));
    }
  }
  else if (!strcmp(c, "h") || !strcmp(c, "?") || !strcmp(c, "help")) printHelp();
  else if (c[0]) { Serial.print(F("# unknown command: ")); Serial.println(c); }
}

void handleSerial() {
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') {
      cmdBuf[cmdLen] = 0;
      if (cmdLen) handleCommand(cmdBuf);
      cmdLen = 0;
    } else if (cmdLen < sizeof(cmdBuf) - 1) {
      cmdBuf[cmdLen++] = ch;
    }
  }
}

// ============================================================================ control
// Uses a rested reading. Returns true when there is balancing work to do.
bool decide(const float v[4], float vmin, float spread, float tmax, bool &warn) {
  if (tmax > T_WARN || vmin < V_BAL_MIN) { warn = true; clearSelection(); return false; }

  if (mode == M_PASSIVE) {
    bool any = false;
    for (uint8_t i = 0; i < 4; i++) {
      float d = (v[i] - vmin) * 1000.0;
      if (d > DV_ON_MV) sel[i] = true;
      else if (d <= DV_OFF_MV) sel[i] = false;
      any |= sel[i];
    }
    return any;
  }

  for (uint8_t k = 0; k < 3; k++) {
    if (fabs(v[k] - v[k + 1]) * 1000.0 > DV_PAIR_MAX_MV) { warn = true; alerts |= A_PAIR; scSel = false; return false; }
  }
  if (spread > DV_ON_MV) scSel = true;
  else if (spread <= DV_OFF_MV) scSel = false;
  return scSel;
}

void startRun() {
  phase = P_RUN;
  phaseSec = 0;
  if (mode == M_PASSIVE) {
    for (uint8_t i = 0; i < 4; i++) bleedOut[i] = sel[i];
    applyBleed();
  } else {
    scStart();
  }
}

bool control(const float v[4], float vmin, float spread, float tmax, bool rested) {
  bool warn = false;
  if (mode == M_OFF) { phase = P_IDLE; return false; }

  uint8_t runLen  = (mode == M_PASSIVE) ? PASSIVE_RUN_S  : ACTIVE_RUN_S;
  uint8_t restLen = (mode == M_PASSIVE) ? PASSIVE_REST_S : ACTIVE_REST_S;

  switch (phase) {
    case P_RUN:
      if (tmax > T_WARN || vmin < V_BAL_MIN) {          // stop early, do not wait for the cycle
        warn = true;
        outputsOff();
        phase = P_REST; phaseSec = 0;
      } else if (++phaseSec >= runLen) {
        outputsOff();
        phase = P_REST; phaseSec = 0;
      }
      break;
    case P_REST:
      if (++phaseSec >= restLen) {
        phaseSec = 0;
        if (rested && decide(v, vmin, spread, tmax, warn)) startRun();
        else phase = P_IDLE;
      }
      break;
    case P_IDLE:
      if (rested && decide(v, vmin, spread, tmax, warn)) startRun();
      break;
  }
  return warn;
}

// ============================================================================ indicators
void updateIndicators(bool warn) {
  if (faultLatched) {                       // solid lights, continuous buzzer
    digitalWrite(LED_FAULT, HIGH);
    digitalWrite(ALERT_LED, HIGH);
    digitalWrite(BUZZER_PIN, HIGH);
    return;
  }
  blinkState = warn ? !blinkState : false;  // fault LED blinks on alerts
  digitalWrite(LED_FAULT, blinkState ? HIGH : LOW);
  digitalWrite(ALERT_LED, warn ? HIGH : LOW);
  if (alerts & A_LOWV) {                    // low-voltage alert: 100 ms chirp every 5 s
    if (chirpTimer == 0) {
      digitalWrite(BUZZER_PIN, HIGH);
      buzzerOffAt = millis() + 100;
    }
    chirpTimer = (chirpTimer + 1) % 5;
  } else {
    chirpTimer = 0;
    if (!buzzerOffAt) digitalWrite(BUZZER_PIN, LOW);
  }
}

void reportAlerts() {
  if (alerts == prevAlerts) return;
  if (alerts == 0) {
    Serial.println(F("# ALERT cleared"));
  } else {
    Serial.print(F("# ALERT:"));
    if (alerts & A_LOWV) Serial.print(F(" LOWV(cell<3.30V)"));
    if (alerts & A_TEMP) Serial.print(F(" TEMP(>45C)"));
    if (alerts & A_JUMP) Serial.print(F(" JUMP(>30mV, check wiring)"));
    if (alerts & A_PAIR) Serial.print(F(" PAIR(>300mV, active refused)"));
    Serial.println();
  }
  prevAlerts = alerts;
}

// ============================================================================ one row per second
void tick() {
  // what was applied during the second that just ended
  Mode  modeLog  = mode;
  Phase phaseLog = phase;
  bool  bLog[4];
  bool  anyOut = scRunning;
  for (uint8_t i = 0; i < 4; i++) { bLog[i] = bleedOut[i]; anyOut |= bleedOut[i]; }
  bool scLog = scRunning;
  if (anyOut) quietSec = 0; else if (quietSec < 255) quietSec++;
  bool rested = quietSec >= SETTLE_S;

  float v[4];
  readCells(v);
  float pack = 0, vmin = 99.0, vmax = -99.0;
  for (uint8_t i = 0; i < 4; i++) {
    pack += v[i];
    if (v[i] < vmin) vmin = v[i];
    if (v[i] > vmax) vmax = v[i];
  }
  float spread = (vmax - vmin) * 1000.0;

  float t[4];
  bool tFail = readTemps(t);
  tFailCount = tFail ? (tFailCount < 255 ? tFailCount + 1 : 255) : 0;
  float tmax = -100.0;
  for (uint8_t i = 0; i < 4; i++) if (t[i] > tmax) tmax = t[i];

  alerts = 0;
  if (rested) {
    if (havePrev)
      for (uint8_t i = 0; i < 4; i++)
        if (fabs(v[i] - vPrev[i]) * 1000.0 > JUMP_WARN_MV) alerts |= A_JUMP;
    for (uint8_t i = 0; i < 4; i++) vPrev[i] = v[i];
    havePrev = true;
  }
  if (tmax > T_WARN)     alerts |= A_TEMP;
  if (vmin < V_LOW_ALERT) alerts |= A_LOWV;
  bool warn = (alerts != 0);

  const char* f = NULL;
  if (vmax > V_FAULT_HIGH)              f = "OV";
  else if (vmin < V_FAULT_LOW)          f = "UV";
  else if (tmax > T_FAULT)              f = "OT";
  else if (tFailCount >= T_FAIL_LIMIT)  f = "TSENSOR";
  conditionsOk = (f == NULL);
  if (f && !faultLatched) tripFault(f);

  if (!faultLatched) warn |= control(v, vmin, spread, tmax, rested);

  if (warn && !alerts) alerts |= A_PAIR;   // control() only warns without a flag for a refused pair
  updateIndicators(warn);
  reportAlerts();
  const char* status = faultLatched ? "FAULT" : (warn ? "WARN" : "OK");

  uint32_t now = millis();
  Serial.print(now);
  Serial.print(','); Serial.print((now - startMs) / 1000);
  for (uint8_t i = 0; i < 4; i++) { Serial.print(','); Serial.print(v[i], 4); }
  Serial.print(','); Serial.print(pack, 4);
  Serial.print(','); Serial.print(spread, 2);
  for (uint8_t i = 0; i < 4; i++) { Serial.print(','); Serial.print(t[i], 2); }
  Serial.print(','); Serial.print(shuttles);
  Serial.print(','); Serial.print(PHASE_STR[phaseLog]);
  Serial.print(','); Serial.print(status);
  Serial.print(','); Serial.print(MODE_STR[modeLog]);
  for (uint8_t i = 0; i < 4; i++) { Serial.print(','); Serial.print(bLog[i] ? 1 : 0); }
  Serial.print(','); Serial.print(scLog ? 1 : 0);
  Serial.print(','); Serial.println(faultLatched ? faultCode : "NONE");
}

// ============================================================================ setup / loop
void setup() {
  Serial.begin(115200);

  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(LED_FAULT, OUTPUT);
  pinMode(ALERT_LED, OUTPUT);
  pinMode(STOP_BTN, INPUT_PULLUP);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(LED_FAULT, LOW);
  digitalWrite(ALERT_LED, LOW);
  for (uint8_t i = 0; i < 4; i++) {
    digitalWrite(BLEED_RELAYS[i], RELAY_OFF);  pinMode(BLEED_RELAYS[i], OUTPUT);
    digitalWrite(ACTIVE_RELAYS[i], RELAY_OFF); pinMode(ACTIVE_RELAYS[i], OUTPUT);
  }

  if (!ads.begin()) {
    Serial.println(F("# ERROR: ADS1115 not found"));
    while (1) { digitalWrite(LED_FAULT, !digitalRead(LED_FAULT)); delay(200); }
  }
  ads.setGain(GAIN_TWO);   // +/- 2.048 V, matches the earlier logs

  ds.begin();
  tCount = ds.getDeviceCount();
  if (tCount > 4) tCount = 4;
  for (uint8_t i = 0; i < tCount; i++) ds.getAddress(tAddr[i], i);
  ds.setResolution(12);
  ds.setWaitForConversion(false);   // non-blocking: result is collected on the next tick
  ds.requestTemperatures();
  if (tCount < 4) {
    Serial.print(F("# WARNING: temperature sensors found: "));
    Serial.println(tCount);
  }

  Serial.println(F("# BMS combined firmware. Starts in OFF (monitor only)."));
  printHelp();
  Serial.println(F("timestamp_ms,elapsed_sec,v1,v2,v3,v4,vpack,spread_mV,t1,t2,t3,t4,shuttles,phase,status,mode,b1,b2,b3,b4,sc_on,fault"));

  startMs = millis();
  nextTick = startMs + LOG_PERIOD_MS;
}

void loop() {
  handleSerial();
  serviceRelays();

  // manual stop button (active LOW, 50 ms debounce)
  if (digitalRead(STOP_BTN) == LOW) {
    if (stopLowSince == 0) stopLowSince = millis() | 1;
    else if (millis() - stopLowSince >= 50 && !(faultLatched && !strcmp(faultCode, "STOP"))) {
      if (faultLatched) { faultCode = "STOP"; Serial.println(F("# STOP button pressed")); }
      else tripFault("STOP");
    }
  } else {
    stopLowSince = 0;
  }

  // end of a low-voltage chirp
  if (buzzerOffAt && (int32_t)(millis() - buzzerOffAt) >= 0) {
    if (!faultLatched) digitalWrite(BUZZER_PIN, LOW);
    buzzerOffAt = 0;
  }
  uint32_t now = millis();
  if ((int32_t)(now - nextTick) >= 0) {
    nextTick += LOG_PERIOD_MS;
    if ((int32_t)(now - nextTick) >= 0) nextTick = now + LOG_PERIOD_MS;  // fell behind: resync
    tick();
  }
}
