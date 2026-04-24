#pragma once
#include "mascot_common.h"

// Hermes — Purple hooded figure
#define HRM_BODY    RGB565(122, 88, 176)
#define HRM_DARK    RGB565(97, 66, 148)
#define HRM_HOOD    RGB565(101, 71, 158)
#define HRM_EYE     0xFFFF
#define HRM_ALERT   RGB565(255, 61, 0)
#define HRM_KB_BASE RGB565(31, 21, 48)
#define HRM_KB_KEY  RGB565(61, 46, 87)
#define HRM_KB_HI   RGB565(217, 217, 242)

static void drawHermesBody(float dy) {
  // Main body (rounded rect)
  gfx->fillRect(sx(3), sy(9, dy), sw(9), sh(6), HRM_BODY);
  gfx->fillRect(sx(4), sy(8, dy), sw(7), sh(1), HRM_BODY);
  // Pointed hood (triangle)
  gfx->fillTriangle(
    sx(7.5f), sy(4.5f, dy),   // apex
    sx(3), sy(9, dy),      // base left
    sx(12), sy(9, dy),     // base right
    HRM_HOOD
  );
}

void hermesSleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), HRM_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), HRM_DARK);
  drawHermesBody(fl);
  float blinkPhase = fmodf(t, 4.0f);
  float eyeH = (blinkPhase > 3.5f && blinkPhase < 3.7f) ? 0.15f : 0.5f;
  gfx->fillRect(sx(5.1f), sy(10.5f, fl), sw(1.8f), sh(eyeH), HRM_EYE);
  gfx->fillRect(sx(8.7f), sy(10.5f, fl), sw(1.8f), sh(eyeH), HRM_EYE);
  drawZParticles(t);
}

void hermesWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), HRM_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), HRM_DARK);
  drawKeyboard(t, HRM_KB_BASE, HRM_KB_KEY, HRM_KB_HI);
  drawHermesBody(bounce);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.0f;
  gfx->fillRect(sx(5.1f), sy(10.5f, bounce), sw(1.8f), sh(eyeH), HRM_EYE);
  gfx->fillRect(sx(8.7f), sy(10.5f, bounce), sw(1.8f), sh(eyeH), HRM_EYE);
}

void hermesAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), HRM_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), HRM_DARK);
  drawHermesBody(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  gfx->fillRect(sx(5.1f), sy(10.5f, jumpY), sw(1.8f), sh(eScale), HRM_EYE);
  gfx->fillRect(sx(8.7f), sy(10.5f, jumpY), sw(1.8f), sh(eScale), HRM_EYE);
  drawBang(bangOp, bangSc, jumpY, jumpY, HRM_ALERT);
}
