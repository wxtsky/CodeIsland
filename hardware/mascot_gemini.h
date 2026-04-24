#pragma once
#include "mascot_common.h"

// Gemini — Four-pointed sparkle star with gradient
#define GEM_BLUE    RGB565(71, 150, 228)
#define GEM_PURPLE  RGB565(132, 122, 206)
#define GEM_ROSE    RGB565(195, 103, 127)
#define GEM_EYE     0xFFFF
#define GEM_ALERT   RGB565(255, 61, 0)
#define GEM_KB_BASE RGB565(56, 64, 96)
#define GEM_KB_KEY  RGB565(102, 112, 148)
#define GEM_KB_HI   0xFFFF

static void drawGemStar(float cx, float cy, float dy, float scale, uint16_t col) {
  float r = 4.5f * scale;
  float ri = 1.8f * scale;
  // Vertical points
  gfx->fillTriangle(sx(cx), sy(cy - r, dy), sx(cx - ri), sy(cy, dy), sx(cx + ri), sy(cy, dy), col);
  gfx->fillTriangle(sx(cx), sy(cy + r, dy), sx(cx - ri), sy(cy, dy), sx(cx + ri), sy(cy, dy), col);
  // Horizontal points
  gfx->fillTriangle(sx(cx - r), sy(cy, dy), sx(cx), sy(cy - ri, dy), sx(cx), sy(cy + ri, dy), col);
  gfx->fillTriangle(sx(cx + r), sy(cy, dy), sx(cx), sy(cy - ri, dy), sx(cx), sy(cy + ri, dy), col);
  // Center fill
  gfx->fillRect(sx(cx - ri), sy(cy - ri, dy), sw(ri * 2), sh(ri * 2), col);
}

void geminiSleep(float t) {
  float phase = fmodf(t, 4.0f) / 4.0f;
  float fl = sinf(phase * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(14), sw(1), sh(1.5f), GEM_PURPLE);
  gfx->fillRect(sx(8.5f), sy(14), sw(1), sh(1.5f), GEM_PURPLE);
  drawGemStar(7.5f, 10.0f, fl, 0.9f, GEM_PURPLE);
  // Dim eyes
  float blinkPhase = fmodf(t, 4.0f);
  if (blinkPhase < 3.5f || blinkPhase > 3.7f) {
    gfx->fillRect(sx(5.5f), sy(9.5f, fl), sw(1.2f), sh(0.5f), GEM_EYE);
    gfx->fillRect(sx(8.3f), sy(9.5f, fl), sw(1.2f), sh(0.5f), GEM_EYE);
  }
  drawZParticles(t);
}

void geminiWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(14), sw(1), sh(1.5f), GEM_PURPLE);
  gfx->fillRect(sx(8.5f), sy(14), sw(1), sh(1.5f), GEM_PURPLE);
  drawKeyboard(t, GEM_KB_BASE, GEM_KB_KEY, GEM_KB_HI);
  drawGemStar(7.5f, 10.0f, bounce, 1.0f, GEM_PURPLE);
  // Eyes with blink
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.0f;
  gfx->fillRect(sx(5.5f), sy(9.5f, bounce), sw(1.2f), sh(eyeH), GEM_EYE);
  gfx->fillRect(sx(8.3f), sy(9.5f, bounce), sw(1.2f), sh(eyeH), GEM_EYE);
}

void geminiAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  float pulse = 1.0f + sinf(pct * 20) * 0.15f;
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(14), sw(1), sh(1.5f), GEM_PURPLE);
  gfx->fillRect(sx(8.5f), sy(14), sw(1), sh(1.5f), GEM_PURPLE);
  drawGemStar(7.5f, 10.0f, jumpY, pulse, GEM_BLUE);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  gfx->fillRect(sx(5.5f), sy(9.5f, jumpY), sw(1.2f), sh(eScale), GEM_EYE);
  gfx->fillRect(sx(8.3f), sy(9.5f, jumpY), sw(1.2f), sh(eScale), GEM_EYE);
  drawBang(bangOp, bangSc, jumpY, jumpY, GEM_ALERT);
}
