#pragma once
#include "mascot_common.h"

// Qoder — Green chat bubble with Q face
#define QOD_BODY    RGB565(42, 219, 92)
#define QOD_DARK    RGB565(30, 166, 71)
#define QOD_FACE    0x0000
#define QOD_ALERT   RGB565(255, 61, 0)
#define QOD_KB_BASE RGB565(26, 46, 31)
#define QOD_KB_KEY  RGB565(51, 97, 61)
#define QOD_KB_HI   RGB565(42, 219, 92)

static void drawQoderBubble(float dy) {
  // Chat bubble shape (pixel rows)
  gfx->fillRect(sx(4), sy(14, dy), sw(7), sh(1), QOD_BODY);
  gfx->fillRect(sx(2), sy(13, dy), sw(11), sh(1), QOD_BODY);
  gfx->fillRect(sx(1), sy(8, dy), sw(13), sh(5), QOD_BODY);
  gfx->fillRect(sx(2), sy(7, dy), sw(11), sh(1), QOD_BODY);
  gfx->fillRect(sx(3), sy(6, dy), sw(9), sh(1), QOD_BODY);
  gfx->fillRect(sx(4), sy(5, dy), sw(7), sh(1), QOD_BODY);
}

void qoderSleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5), sy(15), sw(1), sh(1.5f), QOD_DARK);
  gfx->fillRect(sx(9), sy(15), sw(1), sh(1.5f), QOD_DARK);
  drawQoderBubble(fl);
  // Half-shut eyes (no smile)
  gfx->fillRect(sx(4), sy(9.0f, fl), sw(1.2f), sh(0.3f), QOD_FACE);
  gfx->fillRect(sx(9.8f), sy(9.0f, fl), sw(1.2f), sh(0.3f), QOD_FACE);
  drawZParticles(t);
}

void qoderWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5), sy(15), sw(1), sh(1.5f), QOD_DARK);
  gfx->fillRect(sx(9), sy(15), sw(1), sh(1.5f), QOD_DARK);
  drawKeyboard(t, QOD_KB_BASE, QOD_KB_KEY, QOD_KB_HI);
  drawQoderBubble(bounce);
  // Q face: eyes + smile
  float blinkPhase = fmodf(t, 3.0f);
  float eyeH = (blinkPhase > 2.6f && blinkPhase < 2.75f) ? 0.1f : 1.5f;
  gfx->fillRect(sx(4), sy(9.0f + (1.5f - eyeH)/2.0f, bounce), sw(1.2f), sh(eyeH), QOD_FACE);
  gfx->fillRect(sx(9.8f), sy(9.0f + (1.5f - eyeH)/2.0f, bounce), sw(1.2f), sh(eyeH), QOD_FACE);
  // Smile
  gfx->fillRect(sx(5), sy(11.5f, bounce), sw(1), sh(0.8f), QOD_FACE);
  gfx->fillRect(sx(6), sy(12, bounce), sw(3), sh(0.8f), QOD_FACE);
  gfx->fillRect(sx(9), sy(11.5f, bounce), sw(1), sh(0.8f), QOD_FACE);
}

void qoderAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5), sy(15), sw(1), sh(1.5f), QOD_DARK);
  gfx->fillRect(sx(9), sy(15), sw(1), sh(1.5f), QOD_DARK);
  drawQoderBubble(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  float eyeH2 = 1.5f * eScale;
  gfx->fillRect(sx(4), sy(9.0f + (1.5f - eyeH2)/2.0f, jumpY), sw(1.2f), sh(eyeH2), QOD_FACE);
  gfx->fillRect(sx(9.8f), sy(9.0f + (1.5f - eyeH2)/2.0f, jumpY), sw(1.2f), sh(eyeH2), QOD_FACE);
  drawBang(bangOp, bangSc, jumpY, jumpY, QOD_ALERT);
}
