#include <Wire.h>
#include <Adafruit_ADS1X15.h>
#include <OneWire.h>
#include <DallasTemperature.h>

// ============================================================================
// PINS CONFIGURATION
// ============================================================================
const uint8_t ONEWIRE_PIN = 2;   // DS18B20 1-Wire signal bus
const uint8_t BUZZER_PIN  = 8;   // Fault alarm buzzer
const uint8_t LED_FAULT   = 13;  // Built-in LED

// 4 Active Switched-Capacitor Relays (Pins 26, 27, 28, 29)
const uint8_t ACTIVE_RELAYS[4] = {26, 27, 28, 29};

// Active-LOW relay logic: LOW = Relay ON, HIGH = Relay OFF
const uint8_t RELAY_ON  = LOW;
const uint8_t RELAY_OFF = HIGH;

// ============================================================================
// SETTINGS & TIMING
// ============================================================================
const float DIV          = 4.0;    // 1/4 voltage divider multiplier
const float V_FAULT_LOW  = 3.00;   // Under-voltage critical fault
const float V_FAULT_HIGH = 4.35;   // Over-voltage critical fault
const float T_WARN       = 45.0;   // Temperature warning (°C)
const float T_FAULT      = 60.0;   // Critical over-temperature (°C)

// Active Balancing Shuttling Timing:
const uint16_t T_PHASE_MS     = 500;  // 500 ms per phase (Phase 1 / Phase 2)
const uint16_t T_DEAD_TIME_MS = 20;   // 20 ms break-before-make dead time
const uint8_t  REST_EVERY_SEC = 30;   // Every 30 seconds, rest for 3s to read clean OCV
const uint8_t  REST_TIME_SEC  = 3;

// Calibration offsets
float gain[4] = {1.0, 1.0, 1.0, 1.0};
float offs[4] = {0.0, 0.0, 0.0, 0.0};

// Hardware Objects
Adafruit_ADS1115 ads;
OneWire ow(ONEWIRE_PIN);
DallasTemperature ds(&ow);

// Tracking Variables
uint32_t totalShuttles = 0;
uint16_t runTimer = 0;
bool isResting = false;
uint8_t restTimer = 0;
uint8_t sensorCount = 0;

// ============================================================================
// ACTIVE RELAY DRIVER
// ============================================================================
void setRelayPhase(uint8_t phase) {
  if (phase == 0) {
    // DEAD TIME: All relays OFF
    for (int i = 0; i < 4; i++) digitalWrite(ACTIVE_RELAYS[i], RELAY_OFF);
  } else if (phase == 1) {
    // PHASE 1: Relays de-energized (NC: Caps across Cells 1, 2, 3)
    for (int i = 0; i < 4; i++) digitalWrite(ACTIVE_RELAYS[i], RELAY_OFF);
  } else if (phase == 2) {
    // PHASE 2: Relays energized (NO: Caps across Cells 2, 3, 4)
    for (int i = 0; i < 4; i++) digitalWrite(ACTIVE_RELAYS[i], RELAY_ON);
  }
}

// ============================================================================
// SETUP
// ============================================================================
void setup() {
  Serial.begin(115200);

  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(LED_FAULT, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(LED_FAULT, LOW);

  // Initialize active relays to OFF
  for (int i = 0; i < 4; i++) {
    digitalWrite(ACTIVE_RELAYS[i], RELAY_OFF);
    pinMode(ACTIVE_RELAYS[i], OUTPUT);
  }

  ds.begin();
  sensorCount = ds.getDeviceCount();

  if (!ads.begin()) {
    Serial.println(F("# ERROR: ADS1115 not found!"));
    while (1) {
      digitalWrite(LED_FAULT, !digitalRead(LED_FAULT));
      delay(200);
    }
  }
  ads.setGain(GAIN_TWO); // +/- 2.048 V range

  // Print CSV Header
  Serial.println(F("timestamp_ms,elapsed_sec,v1,v2,v3,v4,vpack,spread_mV,t1,t2,t3,t4,shuttles,phase,status"));
}

// ============================================================================
// MAIN LOOP
// ============================================================================
void loop() {
  static unsigned long lastSec = 0;
  static unsigned long startTime = 0;
  if (startTime == 0) startTime = millis();

  // 1. Shuttling Execution
  const char* currentPhaseStr = "RUN";
  if (!isResting) {
    // Phase 1 (500 ms)
    setRelayPhase(1);
    delay(T_PHASE_MS);
    // Dead Time (20 ms)
    setRelayPhase(0);
    delay(T_DEAD_TIME_MS);
    // Phase 2 (500 ms)
    setRelayPhase(2);
    delay(T_PHASE_MS);
    // Dead Time (20 ms)
    setRelayPhase(0);
    delay(T_DEAD_TIME_MS);

    totalShuttles++;
    runTimer++;
    if (runTimer >= REST_EVERY_SEC) {
      isResting = true;
      runTimer = 0;
      restTimer = 0;
    }
  } else {
    // In Rest: relays stay OFF
    setRelayPhase(0);
    currentPhaseStr = "REST";
    delay(1000);
    restTimer++;
    if (restTimer >= REST_TIME_SEC) {
      isResting = false;
      restTimer = 0;
    }
  }

  // 2. Read Voltages
  float raw[4];
  raw[0] =  ads.computeVolts(ads.readADC_SingleEnded(0))      * DIV;
  raw[1] = -ads.computeVolts(ads.readADC_Differential_0_1())  * DIV;
  raw[2] = -ads.computeVolts(ads.readADC_Differential_1_3())  * DIV;
  raw[3] =  ads.computeVolts(ads.readADC_Differential_2_3())  * DIV;

  float v[4], pack = 0, vmin = 99.0, vmax = -99.0;
  for (int i = 0; i < 4; i++) {
    v[i] = gain[i] * raw[i] + offs[i];
    pack += v[i];
    if (v[i] < vmin) vmin = v[i];
    if (v[i] > vmax) vmax = v[i];
  }
  float spread_mV = (vmax - vmin) * 1000.0;

  // 3. Read Temperatures
  ds.requestTemperatures();
  float t[4] = {25.0, 25.0, 25.0, 25.0};
  float tmax = -100.0;
  bool tErr = false;

  for (int i = 0; i < 4; i++) {
    if (i < sensorCount) {
      float temp = ds.getTempCByIndex(i);
      if (temp < -100.0 || temp == 85.0) tErr = true;
      else {
        t[i] = temp;
        if (t[i] > tmax) tmax = t[i];
      }
    } else {
      t[i] = -127.0;
    }
  }

  // 4. Safety Checks
  const char* status = "OK";
  if (vmax > V_FAULT_HIGH || vmin < V_FAULT_LOW || tmax > T_FAULT || tErr) {
    status = "FAULT";
    setRelayPhase(0);
    digitalWrite(LED_FAULT, HIGH);
    digitalWrite(BUZZER_PIN, HIGH);
  } else {
    digitalWrite(LED_FAULT, LOW);
    digitalWrite(BUZZER_PIN, LOW);
  }

  // 5. Output CSV Row to Serial
  unsigned long now = millis();
  unsigned long elapsedSec = (now - startTime) / 1000;

  Serial.print(now);
  Serial.print(','); Serial.print(elapsedSec);
  for (int i = 0; i < 4; i++) { Serial.print(','); Serial.print(v[i], 4); }
  Serial.print(','); Serial.print(pack, 4);
  Serial.print(','); Serial.print(spread_mV, 2);
  for (int i = 0; i < 4; i++) { Serial.print(','); Serial.print(t[i], 2); }
  Serial.print(','); Serial.print(totalShuttles);
  Serial.print(','); Serial.print(currentPhaseStr);
  Serial.print(','); Serial.println(status);
}
