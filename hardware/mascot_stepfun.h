#pragma once
#include "mascot_common.h"

// StepFun — Teal blocky rectangle with step accent
#define STP_BODY    RGB565(46, 191, 179)
#define STP_DARK    RGB565(30, 153, 143)
#define STP_LIGHT   RGB565(76, 222, 209)
#define STP_FACE    0xFFFF
#define STP_ALERT   RGB565(255, 61, 0)
#define STP_KB_BASE RGB565(31, 46, 43)
#define STP_KB_KEY  RGB565(56, 82, 77)
#define STP_KB_HI   0xFFFF

static void drawStepBody(float dy) {
  gfx->fillRect(sx(3), sy(7, dy), sw(9), sh(7), STP_BODY);
  // Step accent blocks (side by side, above body)
  gfx->fillRect(sx(9.5f), sy(5.5f, dy), sw(2.5f), sh(1.5f), STP_LIGHT);
  gfx->fillRect(sx(7), sy(5.5f, dy), sw(2.5f), sh(1.5f), STP_DARK);
}

void stepfunSleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), STP_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), STP_DARK);
  drawStepBody(fl);
  float blinkPhase = fmodf(t, 4.0f);
  float eyeH = (blinkPhase > 3.5f && blinkPhase < 3.7f) ? 0.15f : 0.5f;
  gfx->fillRect(sx(5.2f), sy(10.0f + (1.5f - eyeH*3.0f)/2.0f, fl), sw(1.3f), sh(eyeH), STP_FACE);
  gfx->fillRect(sx(8.5f), sy(10.0f + (1.5f - eyeH*3.0f)/2.0f, fl), sw(1.3f), sh(eyeH), STP_FACE);
  drawZParticles(t);
}

void stepfunWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), STP_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), STP_DARK);
  drawKeyboard(t, STP_KB_BASE, STP_KB_KEY, STP_KB_HI);
  drawStepBody(bounce);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.5f;
  gfx->fillRect(sx(5.2f), sy(10.0f + (1.5f - eyeH)/2.0f, bounce), sw(1.3f), sh(eyeH), STP_FACE);
  gfx->fillRect(sx(8.5f), sy(10.0f + (1.5f - eyeH)/2.0f, bounce), sw(1.3f), sh(eyeH), STP_FACE);
}

void stepfunAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), STP_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), STP_DARK);
  drawStepBody(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  float eyeH = 1.5f * eScale;
  gfx->fillRect(sx(5.2f), sy(10.0f + (1.5f - eyeH)/2.0f, jumpY), sw(1.3f), sh(eyeH), STP_FACE);
  gfx->fillRect(sx(8.5f), sy(10.0f + (1.5f - eyeH)/2.0f, jumpY), sw(1.3f), sh(eyeH), STP_FACE);
  drawBang(bangOp, bangSc, jumpY, jumpY, STP_ALERT);
}
