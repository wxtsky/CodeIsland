#pragma once
#include "mascot_common.h"

// OpenCode — Gray square with { } bracket face
#define OPC_BODY    RGB565(56, 56, 61)
#define OPC_FRAME   RGB565(140, 140, 145)
#define OPC_FACE    RGB565(217, 217, 222)
#define OPC_LEG     RGB565(89, 89, 94)
#define OPC_ALERT   RGB565(255, 140, 0)  // Amber (not red!)
#define OPC_KB_BASE RGB565(31, 31, 36)
#define OPC_KB_KEY  RGB565(77, 77, 82)
#define OPC_KB_HI   0xFFFF

static void drawOpenCodeBody(float dy) {
  // Square block
  gfx->fillRect(sx(3), sy(7, dy), sw(9), sh(7), OPC_BODY);
  // Frame border (top/bottom + left/right edges)
  gfx->fillRect(sx(3), sy(6, dy), sw(9), sh(0.5f), OPC_FRAME);
  gfx->fillRect(sx(3), sy(12.5f, dy), sw(9), sh(0.5f), OPC_FRAME);
  gfx->fillRect(sx(3), sy(6, dy), sw(0.5f), sh(7), OPC_FRAME);
  gfx->fillRect(sx(11.5f), sy(6, dy), sw(0.5f), sh(7), OPC_FRAME);
}

static void drawBrackets(float dy, float scale, uint16_t col) {
  // Left bracket {
  gfx->fillRect(sx(4.5f), sy(9, dy), sw(0.8f), sh(2.0f * scale), col);
  gfx->fillRect(sx(4.0f), sy(10, dy), sw(0.7f), sh(0.8f), col);
  // Right bracket }
  gfx->fillRect(sx(9.7f), sy(9, dy), sw(0.8f), sh(2.0f * scale), col);
  gfx->fillRect(sx(10.2f), sy(10, dy), sw(0.7f), sh(0.8f), col);
  // Center cursor dot
  gfx->fillRect(sx(7.1f), sy(10, dy), sw(0.8f), sh(0.8f), col);
}

void opencodeSleep(float t) {
  float fl = sinf(fmodf(t, 4.0f) / 4.0f * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(4), sy(15), sw(1), sh(1.5f), OPC_LEG);
  gfx->fillRect(sx(10), sy(15), sw(1), sh(1.5f), OPC_LEG);
  drawOpenCodeBody(fl);
  drawBrackets(fl, 0.3f, OPC_FACE);
  drawZParticles(t);
}

void opencodeWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(4), sy(15), sw(1), sh(1.5f), OPC_LEG);
  gfx->fillRect(sx(10), sy(15), sw(1), sh(1.5f), OPC_LEG);
  drawKeyboard(t, OPC_KB_BASE, OPC_KB_KEY, OPC_KB_HI);
  drawOpenCodeBody(bounce);
  float blinkPhase = fmodf(t, 3.0f);
  float scale = (blinkPhase > 2.6f && blinkPhase < 2.75f) ? 0.1f : 1.0f;
  drawBrackets(bounce, scale, OPC_FACE);
}

void opencodeAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(4), sy(15), sw(1), sh(1.5f), OPC_LEG);
  gfx->fillRect(sx(10), sy(15), sw(1), sh(1.5f), OPC_LEG);
  drawOpenCodeBody(jumpY);
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  drawBrackets(jumpY, eScale, OPC_FACE);
  drawBang(bangOp, bangSc, jumpY, jumpY, OPC_ALERT);
}
