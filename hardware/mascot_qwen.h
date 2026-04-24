#pragma once
#include "mascot_common.h"

// Qwen — Purple 6-pointed star (hexagram)
#define QWN_BODY    RGB565(124, 58, 237)
#define QWN_LIGHT   RGB565(139, 92, 246)
#define QWN_DARK    RGB565(109, 40, 217)
#define QWN_FACE    0xFFFF
#define QWN_ALERT   RGB565(255, 61, 0)
#define QWN_KB_BASE RGB565(51, 38, 77)
#define QWN_KB_KEY  RGB565(97, 77, 133)
#define QWN_KB_HI   0xFFFF

static void drawQwenStar(float cx, float cy, float dy, float scale) {
  // 6-pointed star: two overlapping triangles
  float r = 4.8f * scale;
  float ri = 2.5f * scale;
  // Upward triangle
  gfx->fillTriangle(
    sx(cx), sy(cy - r, dy),
    sx(cx - r * 0.87f), sy(cy + r * 0.5f, dy),
    sx(cx + r * 0.87f), sy(cy + r * 0.5f, dy),
    QWN_BODY
  );
  // Downward triangle
  gfx->fillTriangle(
    sx(cx), sy(cy + r, dy),
    sx(cx - r * 0.87f), sy(cy - r * 0.5f, dy),
    sx(cx + r * 0.87f), sy(cy - r * 0.5f, dy),
    QWN_LIGHT
  );
  // Center fill
  gfx->fillRect(sx(cx - ri * 0.5f), sy(cy - ri * 0.3f, dy), sw(ri), sh(ri * 0.6f), QWN_BODY);
}

void qwenSleep(float t) {
  float phase = fmodf(t, 4.0f) / 4.0f;
  float fl = sinf(phase * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), QWN_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), QWN_DARK);
  drawQwenStar(7.5f, 10.0f, fl, 0.9f);
  float blinkPhase = fmodf(t, 4.0f);
  float eyeH = (blinkPhase > 3.5f && blinkPhase < 3.7f) ? 0.15f : 0.5f;
  gfx->fillRect(sx(5.5f), sy(9.5f, fl), sw(1.2f), sh(eyeH), QWN_FACE);
  gfx->fillRect(sx(8.3f), sy(9.5f, fl), sw(1.2f), sh(eyeH), QWN_FACE);
  drawZParticles(t);
}

void qwenWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), QWN_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), QWN_DARK);
  drawKeyboard(t, QWN_KB_BASE, QWN_KB_KEY, QWN_KB_HI);
  drawQwenStar(7.5f, 10.0f, bounce, 1.0f);
  float blinkPhase = fmodf(t, 2.5f);
  float eyeH = (blinkPhase > 2.2f && blinkPhase < 2.35f) ? 0.1f : 1.0f;
  gfx->fillRect(sx(5.5f), sy(9.5f, bounce), sw(1.2f), sh(eyeH), QWN_FACE);
  gfx->fillRect(sx(8.3f), sy(9.5f, bounce), sw(1.2f), sh(eyeH), QWN_FACE);
}

void qwenAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  float pulse = 1.0f + sinf(pct * 20) * 0.15f;
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), QWN_DARK);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), QWN_DARK);
  drawQwenStar(7.5f, 10.0f, jumpY, pulse);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  gfx->fillRect(sx(5.5f), sy(9.5f, jumpY), sw(1.2f), sh(eScale), QWN_FACE);
  gfx->fillRect(sx(8.3f), sy(9.5f, jumpY), sw(1.2f), sh(eScale), QWN_FACE);
  drawBang(bangOp, bangSc, jumpY, jumpY, QWN_ALERT);
}
