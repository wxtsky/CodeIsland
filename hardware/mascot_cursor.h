#pragma once
#include "mascot_common.h"

// Cursor — Hexagonal gem with diagonal highlight
#define CUR_DARK    RGB565(20, 18, 11)
#define CUR_MID     RGB565(38, 37, 30)
#define CUR_LIGHT   RGB565(237, 236, 236)
#define CUR_EDGE    RGB565(77, 71, 61)
#define CUR_ALERT   RGB565(255, 61, 0)
#define CUR_KB_BASE RGB565(30, 28, 20)
#define CUR_KB_KEY  RGB565(77, 71, 61)
#define CUR_KB_HI   RGB565(237, 236, 236)

static void drawCursorHex(float cx, float cy, float dy) {
  // Hexagonal body approximated as filled rects
  gfx->fillRect(sx(cx - 4), sy(cy - 2, dy), sw(8), sh(5), CUR_DARK);
  gfx->fillRect(sx(cx - 3), sy(cy - 3, dy), sw(6), sh(1), CUR_MID);
  gfx->fillRect(sx(cx - 3), sy(cy + 3, dy), sw(6), sh(1), CUR_MID);
  // Diagonal highlight slash
  gfx->fillRect(sx(cx + 1), sy(cy - 2, dy), sw(1.5f), sh(4), CUR_LIGHT);
}

void cursorSleep(float t) {
  float phase = fmodf(t, 4.0f) / 4.0f;
  float fl = sinf(phase * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), CUR_EDGE);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), CUR_EDGE);
  drawCursorHex(7.5f, 10.0f, fl);
  // Dim eyes (nearly closed)
  gfx->fillRect(sx(4.2f), sy(9.5f, fl), sw(1.3f), sh(0.3f), CUR_LIGHT);
  gfx->fillRect(sx(6.8f), sy(9.5f, fl), sw(1.3f), sh(0.3f), CUR_LIGHT);
  drawZParticles(t);
}

void cursorWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), CUR_EDGE);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), CUR_EDGE);
  drawKeyboard(t, CUR_KB_BASE, CUR_KB_KEY, CUR_KB_HI);
  drawCursorHex(7.5f, 10.0f, bounce);
  // Eyes with blink
  float blinkPhase = fmodf(t, 3.0f);
  float eyeH = (blinkPhase > 2.6f && blinkPhase < 2.75f) ? 0.1f : 1.3f;
  gfx->fillRect(sx(4.2f), sy(9.5f + (1.3f - eyeH)/2.0f, bounce), sw(1.3f), sh(eyeH), CUR_LIGHT);
  gfx->fillRect(sx(6.8f), sy(9.5f + (1.3f - eyeH)/2.0f, bounce), sw(1.3f), sh(eyeH), CUR_LIGHT);
}

void cursorAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), CUR_EDGE);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), CUR_EDGE);
  drawCursorHex(7.5f, 10.0f, jumpY);
  // Eye flash
  bool flash = sinf(pct * 30) > 0;
  uint16_t eyeCol = (pct > 0.03f && pct < 0.55f && flash) ? CUR_ALERT : CUR_LIGHT;
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  float eyeH2 = 1.3f * eScale;
  gfx->fillRect(sx(4.2f), sy(9.5f + (1.3f - eyeH2)/2.0f, jumpY), sw(1.3f), sh(eyeH2), eyeCol);
  gfx->fillRect(sx(6.8f), sy(9.5f + (1.3f - eyeH2)/2.0f, jumpY), sw(1.3f), sh(eyeH2), eyeCol);
  drawBang(bangOp, bangSc, jumpY, jumpY, CUR_ALERT);
}
