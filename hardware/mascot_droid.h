#pragma once
#include "mascot_common.h"

// Droid (Factory) — Industrial robot with antenna
#define DRD_BODY    RGB565(213, 106, 38)
#define DRD_DARK    RGB565(166, 82, 30)
#define DRD_METAL   RGB565(102, 101, 94)
#define DRD_EYE     RGB565(227, 153, 42)
#define DRD_ALERT   RGB565(255, 61, 0)
#define DRD_KB_BASE RGB565(39, 33, 31)
#define DRD_KB_KEY  RGB565(82, 74, 68)
#define DRD_KB_HI   RGB565(213, 106, 38)

static void drawDroidBody(float dy) {
  // Antenna
  gfx->fillRect(sx(7), sy(5, dy), sw(1), sh(2), DRD_METAL);
  gfx->fillRect(sx(6), sy(4, dy), sw(3), sh(1), DRD_METAL);
  // Head
  gfx->fillRect(sx(4), sy(7, dy), sw(7), sh(3), DRD_BODY);
  // Main body (6 units tall)
  gfx->fillRect(sx(3), sy(9, dy), sw(9), sh(6), DRD_BODY);
  // Chest plate
  gfx->fillRect(sx(5), sy(10, dy), sw(5), sh(3), DRD_DARK);
  // Rivets
  gfx->fillRect(sx(5.5f), sy(10.5f, dy), sw(0.8f), sh(0.8f), DRD_METAL);
  gfx->fillRect(sx(8.7f), sy(10.5f, dy), sw(0.8f), sh(0.8f), DRD_METAL);
  // Side arms (metal)
  gfx->fillRect(sx(1.5f), sy(10, dy), sw(1.5f), sh(4), DRD_METAL);
  gfx->fillRect(sx(12), sy(10, dy), sw(1.5f), sh(4), DRD_METAL);
}

void droidSleep(float t) {
  float phase = fmodf(t, 5.0f) / 5.0f;
  float breathe = sinf(phase * 2.0f * PI) * 0.4f;
  drawShadow(8.0f);
  gfx->fillRect(sx(4.5f), sy(15), sw(2), sh(1.5f), DRD_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(2), sh(1.5f), DRD_DARK);
  drawDroidBody(breathe);
  // Eye flicker (powering down)
  float flickerPhase = fmodf(t, 3.0f);
  if (flickerPhase < 2.5f) {
    gfx->fillRect(sx(4.8f), sy(8.0f, breathe), sw(1.5f), sh(0.5f), DRD_EYE);
    gfx->fillRect(sx(8.7f), sy(8.0f, breathe), sw(1.5f), sh(0.5f), DRD_EYE);
  }
  drawZParticles(t);
}

void droidWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.5f) * 0.8f;
  drawShadow(9.0f - fabsf(bounce) * 0.3f, bounce);
  gfx->fillRect(sx(4.5f), sy(15), sw(2), sh(1.5f), DRD_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(2), sh(1.5f), DRD_DARK);
  drawKeyboard(t, DRD_KB_BASE, DRD_KB_KEY, DRD_KB_HI);
  drawDroidBody(bounce);
  // Eyes with blink
  float blinkPhase = fmodf(t, 2.0f);
  float eyeH = (blinkPhase > 1.7f && blinkPhase < 1.85f) ? 0.1f : 1.2f;
  gfx->fillRect(sx(4.8f), sy(8.0f + (1.2f - eyeH)/2.0f, bounce), sw(1.5f), sh(eyeH), DRD_EYE);
  gfx->fillRect(sx(8.7f), sy(8.0f + (1.2f - eyeH)/2.0f, bounce), sw(1.5f), sh(eyeH), DRD_EYE);
}

void droidAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(8.0f, jumpY);
  gfx->fillRect(sx(4.5f), sy(15), sw(2), sh(1.5f), DRD_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(2), sh(1.5f), DRD_DARK);
  drawDroidBody(jumpY);
  // Eye flash
  bool flash = sinf(pct * 20) > 0;
  uint16_t eyeCol = (pct > 0.03f && pct < 0.55f && flash) ? DRD_ALERT : DRD_EYE;
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  float eyeH = eScale * 1.2f;
  gfx->fillRect(sx(4.8f), sy(8.0f + (1.2f - eyeH)/2.0f, jumpY), sw(1.5f), sh(eyeH), eyeCol);
  gfx->fillRect(sx(8.7f), sy(8.0f + (1.2f - eyeH)/2.0f, jumpY), sw(1.5f), sh(eyeH), eyeCol);
  drawBang(bangOp, bangSc, jumpY, jumpY, DRD_ALERT);
}
