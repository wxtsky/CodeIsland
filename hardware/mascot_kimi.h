#pragma once
#include "mascot_common.h"

// Kimi — Blue rounded cube with antenna
#define KIM_BODY    RGB565(74, 144, 255)
#define KIM_DARK    RGB565(51, 107, 230)
#define KIM_LIGHT   RGB565(107, 174, 255)
#define KIM_EYE     0xFFFF
#define KIM_ALERT   RGB565(255, 61, 0)
#define KIM_KB_BASE RGB565(46, 61, 87)
#define KIM_KB_KEY  RGB565(97, 128, 163)
#define KIM_KB_HI   0xFFFF

static void drawKimiBody(float dy) {
  // Rounded cube
  gfx->fillRect(sx(3), sy(8, dy), sw(9), sh(7), KIM_BODY);
  gfx->fillRect(sx(4), sy(7, dy), sw(7), sh(1), KIM_LIGHT);
  gfx->fillRect(sx(4), sy(14, dy), sw(7), sh(1), KIM_DARK);
  // Antenna
  gfx->fillRect(sx(7), sy(5, dy), sw(1), sh(2.5f), KIM_DARK);
  gfx->fillRect(sx(6), sy(4, dy), sw(3), sh(1.5f), KIM_LIGHT);
}

void kimiSleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5), sy(13.5f), sw(1), sh(2), KIM_DARK);
  gfx->fillRect(sx(9), sy(13.5f), sw(1), sh(2), KIM_DARK);
  drawKimiBody(fl);
  float blinkPhase = fmodf(t, 4.0f);
  float eyeH = (blinkPhase > 3.5f && blinkPhase < 3.7f) ? 0.15f : 0.5f;
  gfx->fillRect(sx(5.0f), sy(8.5f, fl), sw(1.3f), sh(eyeH), KIM_EYE);
  gfx->fillRect(sx(8.7f), sy(8.5f, fl), sw(1.3f), sh(eyeH), KIM_EYE);
  drawZParticles(t);
}

void kimiWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5), sy(13.5f), sw(1), sh(2), KIM_DARK);
  gfx->fillRect(sx(9), sy(13.5f), sw(1), sh(2), KIM_DARK);
  drawKeyboard(t, KIM_KB_BASE, KIM_KB_KEY, KIM_KB_HI);
  drawKimiBody(bounce);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.8f;
  gfx->fillRect(sx(5.0f), sy(8.5f + (1.8f - eyeH)/2.0f, bounce), sw(1.3f), sh(eyeH), KIM_EYE);
  gfx->fillRect(sx(8.7f), sy(8.5f + (1.8f - eyeH)/2.0f, bounce), sw(1.3f), sh(eyeH), KIM_EYE);
}

void kimiAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  float pulse = 1.0f + sinf(pct * 20) * 0.15f;
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5), sy(13.5f), sw(1), sh(2), KIM_DARK);
  gfx->fillRect(sx(9), sy(13.5f), sw(1), sh(2), KIM_DARK);
  drawKimiBody(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  float eyeH2 = 1.8f * eScale;
  gfx->fillRect(sx(5.0f), sy(8.5f + (1.8f - eyeH2)/2.0f, jumpY), sw(1.3f), sh(eyeH2), KIM_EYE);
  gfx->fillRect(sx(8.7f), sy(8.5f + (1.8f - eyeH2)/2.0f, jumpY), sw(1.3f), sh(eyeH2), KIM_EYE);
  drawBang(bangOp, bangSc, jumpY, jumpY, KIM_ALERT);
}
