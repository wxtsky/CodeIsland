#pragma once
#include "mascot_common.h"

// AntiGravity — Rainbow gradient "A" triangle
#define AG_BLUE   RGB565(77, 127, 242)
#define AG_PURPLE RGB565(153, 89, 230)
#define AG_PINK   RGB565(230, 102, 140)
#define AG_ORANGE RGB565(242, 153, 77)
#define AG_FACE   0xFFFF
#define AG_ALERT  RGB565(255, 61, 0)
#define AG_KB_BASE RGB565(46, 41, 64)
#define AG_KB_KEY  RGB565(82, 72, 102)
#define AG_KB_HI   0xFFFF

static void drawAGBody(float dy) {
  // "A" triangle: gradient approximated with horizontal slices
  float cx = 7.5f, topY = 6.0f, botY = 14.0f;
  float halfW = 5.0f;
  uint16_t colors[] = { AG_BLUE, AG_BLUE, AG_PURPLE, AG_PURPLE, AG_PINK, AG_PINK, AG_ORANGE, AG_ORANGE };
  int slices = 8;
  for (int i = 0; i < slices; i++) {
    float frac = (float)i / slices;
    float y = topY + frac * (botY - topY);
    float w = halfW * frac * 2.0f;
    if (w < 1.0f) w = 1.0f;
    gfx->fillRect(sx(cx - w / 2), sy(y, dy), sw(w), sh((botY - topY) / slices + 0.1f), colors[i]);
  }
}

void antigravSleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), AG_PURPLE);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), AG_PINK);
  drawAGBody(fl);
  float blinkPhase = fmodf(t, 4.0f);
  float eyeH = (blinkPhase > 3.5f && blinkPhase < 3.7f) ? 0.15f : 0.5f;
  gfx->fillRect(sx(5.5f), sy(9.0f, fl), sw(1.2f), sh(eyeH), AG_FACE);
  gfx->fillRect(sx(8.3f), sy(9.0f, fl), sw(1.2f), sh(eyeH), AG_FACE);
  drawZParticles(t);
}

void antigravWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), AG_PURPLE);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), AG_PINK);
  drawKeyboard(t, AG_KB_BASE, AG_KB_KEY, AG_KB_HI);
  drawAGBody(bounce);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.0f;
  gfx->fillRect(sx(5.5f), sy(9.0f, bounce), sw(1.2f), sh(eyeH), AG_FACE);
  gfx->fillRect(sx(8.3f), sy(9.0f, bounce), sw(1.2f), sh(eyeH), AG_FACE);
}

void antigravAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), AG_PURPLE);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), AG_PINK);
  drawAGBody(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  gfx->fillRect(sx(5.5f), sy(9.0f, jumpY), sw(1.2f), sh(eScale), AG_FACE);
  gfx->fillRect(sx(8.3f), sy(9.0f, jumpY), sw(1.2f), sh(eScale), AG_FACE);
  drawBang(bangOp, bangSc, jumpY, jumpY, AG_ALERT);
}
