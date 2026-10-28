// PathAhead core: tap detector, gait-drift baseline, route memory.
// Header-only, float math, no dynamic allocation, no STL. Mirrors imu_steps.py / gait.py / route_memory.py.
// Compiles for ESP32 (Arduino) and for a PC (g++) so it can be checked against the Python versions.
#pragma once
#include <math.h>
#include <stdint.h>
#include "params.h"

namespace pa {

// ---------------------------------------------------------------- tap detector (task 4)
// Feed accel in m/s^2 at TAP_FS Hz. Returns the 1-based sample index of a tap once its peak is known, else -1.
class TapDetector {
 public:
  TapDetector() { reset(); }
  void reset() {
    havePrev_ = false; prev_ = 0; floor_ = 0.2f; lock_ = (int)(TAP_WARMUP_S * TAP_FS);
    win_ = 0; best_ = 0; bestI_ = 0; i_ = 0;
  }
  long update(float ax, float ay, float az) {
    float a = sqrtf(ax * ax + ay * ay + az * az);
    float j = havePrev_ ? fabsf(a - prev_) : 0.0f;
    prev_ = a; havePrev_ = true; i_++;
    long out = -1;
    if (win_ > 0) {
      if (j > best_) { best_ = j; bestI_ = i_; }
      win_--;
      if (win_ == 0) { out = bestI_; lock_ = (int)(TAP_LOCKOUT_S * TAP_FS); }
    } else if (lock_ > 0) {
      lock_--;
    } else {
      float thr = TAP_K * floor_;
      if (thr < TAP_J_MIN) thr = TAP_J_MIN;
      if (j > thr) { win_ = TAP_PEAK_WIN; best_ = j; bestI_ = i_; }
      else floor_ += TAP_ALPHA * (j - floor_);
    }
    return out;
  }
 private:
  bool havePrev_; float prev_, floor_, best_; int lock_, win_; long bestI_, i_;
};

// ---------------------------------------------------------------- gait drift (tasks 2-3)
struct GaitResult {
  bool calibrated;   // baseline learned
  bool alarmsValid;  // false while learning and on the sample that completes learning
  float zDrift;      // ln(window SD / baseline SD) / SE; valid when calibrated
  float zInst;       // (interval - mean) / SD
  bool drift;        // zDrift above threshold for GAIT_PERSIST windows in a row
  bool stumble;      // |zInst| above stumble threshold
};

class GaitDrift {
 public:
  GaitDrift() { reset(); }
  void reset() { nCal_ = 0; nRing_ = 0; head_ = 0; ready_ = false; run_ = 0; mu_ = 0; sd_ = 0; }
  float mean() const { return mu_; }
  float sd() const { return sd_; }
  float cv() const { return mu_ > 0 ? sd_ / mu_ : 0; }
  bool ready() const { return ready_; }

  // x = one stride interval in seconds (time between successive taps).
  GaitResult update(float x) {
    GaitResult r = {ready_, false, 0, 0, false, false};
    ring_[head_] = x; head_ = (head_ + 1) % GAIT_WINDOW; if (nRing_ < GAIT_WINDOW) nRing_++;
    if (!ready_) {
      cal_[nCal_++] = x;
      if (nCal_ == GAIT_NCAL) {
        float m = 0; for (int i = 0; i < GAIT_NCAL; i++) m += cal_[i]; m /= GAIT_NCAL;
        float s2 = 0; for (int i = 0; i < GAIT_NCAL; i++) { float d = cal_[i] - m; s2 += d * d; }
        float s = sqrtf(s2 / (GAIT_NCAL - 1));
        float fl = GAIT_SD_FLOOR_FRAC * m; if (s < fl) s = fl;
        mu_ = m; sd_ = s; ready_ = true; r.calibrated = true;
        r.zDrift = windowZ(); run_ = (r.zDrift > GAIT_THR_DRIFT_Z) ? 1 : 0;   // seed persistence with last window
        r.zInst = (x - mu_) / sd_;
      }
      return r;
    }
    r.calibrated = true; r.alarmsValid = true;
    r.zDrift = windowZ(); r.zInst = (x - mu_) / sd_;
    run_ = (r.zDrift > GAIT_THR_DRIFT_Z) ? run_ + 1 : 0;
    r.drift = run_ >= GAIT_PERSIST;
    r.stumble = fabsf(r.zInst) > GAIT_THR_STUMBLE_Z;
    return r;
  }

 private:
  float windowZ() const {
    float m = 0; for (int i = 0; i < GAIT_WINDOW; i++) m += ring_[i]; m /= GAIT_WINDOW;
    float s2 = 0; for (int i = 0; i < GAIT_WINDOW; i++) { float d = ring_[i] - m; s2 += d * d; }
    float sw = sqrtf(s2 / (GAIT_WINDOW - 1)); if (sw < 1e-6f) sw = 1e-6f;
    float se = sqrtf(1.0f / (2.0f * (GAIT_WINDOW - 1)) + 1.0f / (2.0f * (GAIT_NCAL - 1)));
    return logf(sw / sd_) / se;
  }
  float cal_[GAIT_NCAL]; float ring_[GAIT_WINDOW];
  int nCal_, nRing_, head_, run_; bool ready_; float mu_, sd_;
};

// ---------------------------------------------------------------- route memory (task 5)
enum EvType : uint8_t { EV_NONE = 0, EV_HAZARD, EV_CONFIRMED, EV_CHANGED, EV_NEW };
enum Reason : uint8_t { R_NONE = 0, R_NOT_FOUND, R_MOVED, R_DIFFERENT };

struct Event {
  EvType type; Reason reason;
  int n;              // route_hazard: steps_ahead; not_found: was_steps; moved: shift_steps
  float confidence;   // hazard / confirmed
  int expectedMm;     // hazard
  bool predicted;     // confirmed: was it warned about in advance
  float z;            // different_obstacle
};

struct Landmark {
  int n; float ms, m2s, md, m2d, hits, walks; int streak; bool missed, warned, seen;
  float sdStep() const { float v = n > 1 ? m2s / n : 0.0f; if (v < 0) v = 0; return sqrtf(v + ROUTE_SD_FLOOR * ROUTE_SD_FLOOR); }
  float sdDist() const { float v = n > 1 ? m2d / n : 0.0f; if (v < 0) v = 0; return sqrtf(v + ROUTE_D_SD_FLOOR * ROUTE_D_SD_FLOOR); }
  float confidence() const {
    float pSeen = (hits + 1.0f) / (walks + 2.0f);
    float cons = erff(1.5f / (sdStep() * 1.41421356f));
    return pSeen * cons * powf(ROUTE_MISS_FACTOR, (float)streak);
  }
  bool trusted() const { return n >= ROUTE_MIN_HITS; }
  void update(float s, float d) {
    n++;
    float ds = s - ms; ms += ds / n; m2s += ds * (s - ms);
    float dd = d - md; md += dd / n; m2d += dd * (d - md);
  }
  void init(float s, float d) {
    n = 1; ms = s; m2s = 0; md = d; m2d = 0; hits = 1; walks = 1; streak = 0; missed = false; warned = false; seen = true;
  }
};

class RouteMemory {
 public:
  explicit RouteMemory(bool reanchor = true) : count_(0), reanchor_(reanchor), step_(0), offset_(0) {}
  int count() const { return count_; }
  const Landmark& landmark(int i) const { return L_[i]; }
  // Persist / restore the learned table (the sketch stores these bytes in flash so learning survives a reboot).
  int exportTable(Landmark* dst) const { for (int i = 0; i < count_; i++) dst[i] = L_[i]; return count_; }
  void importTable(const Landmark* src, int n) { count_ = n > ROUTE_MAXL ? ROUTE_MAXL : (n < 0 ? 0 : n); for (int i = 0; i < count_; i++) L_[i] = src[i]; }

  void beginWalk() {
    step_ = 0; offset_ = 0;
    for (int i = 0; i < count_; i++) { L_[i].warned = false; L_[i].seen = false; L_[i].missed = false; }
  }

  // Call once per detected step. Writes up to cap events, returns how many.
  int onStep(Event* out, int cap) {
    step_++; float s = pos(); int k = 0;
    for (int i = 0; i < count_; i++) {
      Landmark& l = L_[i];
      if (l.seen) continue;
      if (l.trusted() && !l.warned && s >= l.ms - ROUTE_LEAD && s < l.ms && l.confidence() >= ROUTE_WARN_CONF) {
        l.warned = true;
        if (k < cap) { Event e = blank(EV_HAZARD); e.n = roundHalfEven(l.ms - s); e.confidence = l.confidence(); e.expectedMm = (int)l.md; out[k++] = e; }
      }
      float g = 3.0f * l.sdStep(); if (g < ROUTE_GATE_MIN) g = ROUTE_GATE_MIN;
      if (l.trusted() && s > l.ms + g && !l.missed && !l.seen) {
        l.missed = true; l.streak++; l.walks = ROUTE_DECAY * l.walks + 1; l.hits = ROUTE_DECAY * l.hits;
        if (l.streak <= 2 && k < cap) { Event e = blank(EV_CHANGED); e.reason = R_NOT_FOUND; e.n = roundHalfEven(l.ms); out[k++] = e; }
      }
    }
    return k;
  }

  // The forward ToF has just first seen a hazard at dMm.
  int onSighting(float dMm, Event* out, int cap) {
    float s = pos(); int best = -1; float bd = 1e9f;
    for (int i = 0; i < count_; i++) {
      float gap = fabsf(s - L_[i].ms), g = 3.0f * L_[i].sdStep(); if (g < ROUTE_GATE_MIN) g = ROUTE_GATE_MIN;
      if (gap <= g && gap < bd) { best = i; bd = gap; }
    }
    if (best >= 0) {
      Landmark& l = L_[best]; bool first = !l.seen;
      float zd = fabsf(dMm - l.md) / l.sdDist();
      if (first) { l.walks = ROUTE_DECAY * l.walks + 1; l.hits = ROUTE_DECAY * l.hits + 1; }
      bool wasWarned = l.warned; l.seen = true; l.streak = 0;
      if (reanchor_ && l.trusted()) offset_ += l.ms - s;
      l.update(s, dMm);
      if (l.trusted() && zd > ROUTE_D_Z) {
        if (cap < 1) return 0;
        Event e = blank(EV_CHANGED); e.reason = R_DIFFERENT; e.z = zd; out[0] = e; return 1;
      }
      if (l.trusted()) {
        if (cap < 1) return 0;
        Event e = blank(EV_CONFIRMED); e.predicted = wasWarned; e.confidence = l.confidence(); out[0] = e; return 1;
      }
      return 0;
    }
    for (int i = 0; i < count_; i++) {
      if (L_[i].trusted() && L_[i].missed && fabsf(s - L_[i].ms) <= ROUTE_MOVE_WIN) {
        int shift = roundHalfEven(s - L_[i].ms);
        add(s, dMm);
        if (cap < 1) return 0;
        Event e = blank(EV_CHANGED); e.reason = R_MOVED; e.n = shift; out[0] = e; return 1;
      }
    }
    add(s, dMm);
    if (cap < 1) return 0;
    out[0] = blank(EV_NEW); return 1;
  }

  void endWalk() {
    for (int i = 0; i < count_; i++) if (!L_[i].trusted() && !L_[i].seen) L_[i].walks += 1;
    int w = 0;
    for (int i = 0; i < count_; i++) {
      const Landmark& l = L_[i];
      bool dropTentative = !l.trusted() && (l.walks - l.hits >= 2);
      bool dropTrusted = l.trusted() && (l.hits < 0.5f || l.streak >= 4);
      if (!dropTentative && !dropTrusted) L_[w++] = l;
    }
    count_ = w;
  }

 private:
  float pos() const { return (float)step_ + offset_; }
  static Event blank(EvType t) { Event e; e.type = t; e.reason = R_NONE; e.n = 0; e.confidence = 0; e.expectedMm = 0; e.predicted = false; e.z = 0; return e; }
  static int roundHalfEven(float x) { return (int)nearbyintf(x); }   // same as Python round()
  void add(float s, float d) {
    if (count_ >= ROUTE_MAXL) {                                      // evict weakest (first minimum, order kept)
      int wi = 0; float wc = L_[0].confidence();
      for (int i = 1; i < count_; i++) { float c = L_[i].confidence(); if (c < wc) { wc = c; wi = i; } }
      for (int i = wi; i < count_ - 1; i++) L_[i] = L_[i + 1];
      count_--;
    }
    L_[count_].init(s, d); count_++;
  }
  Landmark L_[ROUTE_MAXL]; int count_; bool reanchor_; int step_; float offset_;
};

}  // namespace pa
