#pragma once
#include "mascot_common.h"

// Trae — Green rounded rectangle with screen
#define TRAE_BODY   RGB565(34, 197, 94)
#define TRAE_DARK   RGB565(16, 143, 81)
#define TRAE_SCREEN RGB565(36, 56, 36)
#define TRAE_EYE    RGB565(34, 197, 94)
#define TRAE_ALERT  RGB565(255, 61, 0)
#define TRAE_KB_BASE RGB565(26, 36, 26)
#define TRAE_KB_KEY  RGB565(51, 77, 51)
#define TRAE_KB_HI   RGB565(34, 197, 94)

static void drawTraeBody(float dy) {
  gfx->fillRect(sx(3), sy(7, dy), sw(9), sh(7), TRAE_BODY);
  gfx->fillRect(sx(2), sy(8, dy), sw(1), sh(5), TRAE_BODY);
  gfx->fillRect(sx(12), sy(8, dy), sw(1), sh(5), TRAE_BODY);
  // Inner screen
  gfx->fillRect(sx(4), sy(8, dy), sw(7), sh(5), TRAE_SCREEN);
}

void traeSleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), TRAE_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), TRAE_DARK);
  drawTraeBody(fl);
  float blinkPhase = fmodf(t, 4.0f);
  float eyeH = (blinkPhase > 3.5f && blinkPhase < 3.7f) ? 0.15f : 0.5f;
  gfx->fillRect(sx(5.5f), sy(10, fl), sw(1), sh(eyeH), TRAE_EYE);
  gfx->fillRect(sx(8.5f), sy(10, fl), sw(1), sh(eyeH), TRAE_EYE);
  drawZParticles(t);
}

void traeWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), TRAE_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), TRAE_DARK);
  drawKeyboard(t, TRAE_KB_BASE, TRAE_KB_KEY, TRAE_KB_HI);
  drawTraeBody(bounce);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.0f;
  gfx->fillRect(sx(5.5f), sy(10, bounce), sw(1), sh(eyeH), TRAE_EYE);
  gfx->fillRect(sx(8.5f), sy(10, bounce), sw(1), sh(eyeH), TRAE_EYE);
}

void traeAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), TRAE_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), TRAE_DARK);
  drawTraeBody(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  gfx->fillRect(sx(5.5f), sy(10, jumpY), sw(1), sh(eScale), TRAE_EYE);
  gfx->fillRect(sx(8.5f), sy(10, jumpY), sw(1), sh(eScale), TRAE_EYE);
  drawBang(bangOp, bangSc, jumpY, jumpY, TRAE_ALERT);
}
