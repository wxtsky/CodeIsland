#pragma once
#include "mascot_common.h"

// WorkBuddy — Purple circle body with antenna
#define WB_BODY    RGB565(121, 97, 222)
#define WB_DARK    RGB565(97, 74, 191)
#define WB_LIGHT   RGB565(148, 122, 240)
#define WB_FACE    0xFFFF
#define WB_ALERT   RGB565(255, 61, 0)
#define WB_KB_BASE RGB565(26, 46, 43)
#define WB_KB_KEY  RGB565(46, 82, 74)
#define WB_KB_HI   0xFFFF

static void drawWBBody(float dy) {
  // Circle body (approximated with stacked rects)
  float cx = 7.5f, cy = 10.5f, r = 4.5f;
  for (int row = 0; row < 9; row++) {
    float frac = (float)row / 8.0f;
    float y = cy - r + frac * r * 2;
    float halfW = sqrtf(r * r - (y - cy) * (y - cy));
    if (halfW < 0.5f) halfW = 0.5f;
    gfx->fillRect(sx(cx - halfW), sy(y, dy), sw(halfW * 2), sh(r * 2 / 9 + 0.1f), WB_BODY);
  }
  // Antenna stem + tip
  gfx->fillRect(sx(7), sy(5, dy), sw(1), sh(2), WB_DARK);
  gfx->fillRect(sx(6.2f), sy(3.5f, dy), sw(2.6f), sh(2), WB_LIGHT);
}

void workbuddySleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), WB_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), WB_DARK);
  drawWBBody(fl);
  float blinkPhase = fmodf(t, 4.0f);
  float eyeH = (blinkPhase > 3.5f && blinkPhase < 3.7f) ? 0.15f : 0.5f;
  gfx->fillRect(sx(5), sy(10, fl), sw(1.5f), sh(eyeH), WB_FACE);
  gfx->fillRect(sx(8.5f), sy(10, fl), sw(1.5f), sh(eyeH), WB_FACE);
  drawZParticles(t);
}

void workbuddyWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), WB_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), WB_DARK);
  drawKeyboard(t, WB_KB_BASE, WB_KB_KEY, WB_KB_HI);
  drawWBBody(bounce);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.0f;
  gfx->fillRect(sx(5), sy(10, bounce), sw(1.5f), sh(eyeH), WB_FACE);
  gfx->fillRect(sx(8.5f), sy(10, bounce), sw(1.5f), sh(eyeH), WB_FACE);
}

void workbuddyAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), WB_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), WB_DARK);
  drawWBBody(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  gfx->fillRect(sx(5), sy(10, jumpY), sw(1.5f), sh(eScale), WB_FACE);
  gfx->fillRect(sx(8.5f), sy(10, jumpY), sw(1.5f), sh(eScale), WB_FACE);
  drawBang(bangOp, bangSc, jumpY, jumpY, WB_ALERT);
}
