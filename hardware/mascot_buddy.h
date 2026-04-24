#pragma once
#include "mascot_common.h"

// Buddy (CodeBuddy) — Purple cat astronaut with cyan glow
#define BUD_BODY    RGB565(108, 77, 255)
#define BUD_DARK    RGB565(88, 62, 211)
#define BUD_GLOW    RGB565(50, 230, 185)
#define BUD_FACE    0xFFFF
#define BUD_ALERT   RGB565(255, 61, 0)
#define BUD_KB_BASE RGB565(46, 39, 77)
#define BUD_KB_KEY  RGB565(89, 77, 140)
#define BUD_KB_HI   RGB565(50, 230, 185)

static void drawBuddyBody(float dy) {
  // Cat body
  gfx->fillRect(sx(3), sy(8, dy), sw(9), sh(7), BUD_BODY);
  gfx->fillRect(sx(4), sy(7, dy), sw(7), sh(1), BUD_BODY);
  // Pointed ears
  gfx->fillRect(sx(2.5f), sy(5, dy), sw(2.5f), sh(2), BUD_BODY);
  gfx->fillRect(sx(10), sy(5, dy), sw(2.5f), sh(2), BUD_BODY);
  // Inner ears (cyan glow)
  gfx->fillRect(sx(3), sy(5.5f, dy), sw(1.5f), sh(1.2f), BUD_GLOW);
  gfx->fillRect(sx(10.5f), sy(5.5f, dy), sw(1.5f), sh(1.2f), BUD_GLOW);
  // Helmet visor (deep purple, matching bodyDk)
  gfx->fillRect(sx(3.5f), sy(7, dy), sw(8), sh(2.5f), BUD_DARK);
  // Tail
  gfx->fillRect(sx(12), sy(12, dy), sw(2), sh(1), BUD_BODY);
  gfx->fillRect(sx(13), sy(11, dy), sw(1), sh(1), BUD_BODY);
}

void buddySleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.6f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(4), sy(15), sw(1.5f), sh(1.5f), BUD_DARK);
  gfx->fillRect(sx(9.5f), sy(15), sw(1.5f), sh(1.5f), BUD_DARK);
  drawBuddyBody(fl);
  // Dim closed eyes
  gfx->fillRect(sx(5), sy(7.5f, fl), sw(1.2f), sh(0.3f), BUD_FACE);
  gfx->fillRect(sx(8.8f), sy(7.5f, fl), sw(1.2f), sh(0.3f), BUD_FACE);
  drawZParticles(t);
}

void buddyWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(4), sy(15), sw(1.5f), sh(1.5f), BUD_DARK);
  gfx->fillRect(sx(9.5f), sy(15), sw(1.5f), sh(1.5f), BUD_DARK);
  drawKeyboard(t, BUD_KB_BASE, BUD_KB_KEY, BUD_KB_HI);
  drawBuddyBody(bounce);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.2f;
  gfx->fillRect(sx(5), sy(7.5f + (1.2f - eyeH)/2.0f, bounce), sw(1.2f), sh(eyeH), BUD_FACE);
  gfx->fillRect(sx(8.8f), sy(7.5f + (1.2f - eyeH)/2.0f, bounce), sw(1.2f), sh(eyeH), BUD_FACE);
  // Nose dot
  gfx->fillRect(sx(7), sy(9.5f, bounce), sw(1), sh(0.5f), BUD_GLOW);
}

void buddyAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(4), sy(15), sw(1.5f), sh(1.5f), BUD_DARK);
  gfx->fillRect(sx(9.5f), sy(15), sw(1.5f), sh(1.5f), BUD_DARK);
  drawBuddyBody(jumpY);
  // Eye flash cyan/red
  bool flash = sinf(pct * 25) > 0;
  uint16_t eyeCol = (pct > 0.03f && pct < 0.55f && flash) ? BUD_ALERT : BUD_GLOW;
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  float eyeH = 1.2f * eScale;
  gfx->fillRect(sx(5), sy(7.5f + (1.2f - eyeH)/2.0f, jumpY), sw(1.2f), sh(eyeH), eyeCol);
  gfx->fillRect(sx(8.8f), sy(7.5f + (1.2f - eyeH)/2.0f, jumpY), sw(1.2f), sh(eyeH), eyeCol);
  drawBang(bangOp, bangSc, jumpY, jumpY, BUD_ALERT);
}
