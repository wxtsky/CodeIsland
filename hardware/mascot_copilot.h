#pragma once
#include "mascot_common.h"

// Copilot — Rose robot head with ear loops and gold eyes
#define COP_EARS    RGB565(51, 51, 51)
#define COP_BODY    RGB565(204, 51, 102)
#define COP_FACE    RGB565(34, 34, 40)
#define COP_EYE     RGB565(255, 215, 0)
#define COP_ALERT   RGB565(254, 76, 37)
#define COP_KB_BASE RGB565(31, 20, 26)
#define COP_KB_KEY  RGB565(89, 38, 56)
#define COP_KB_HI   0xFFFF

static void drawCopilotBody(float dy) {
  // Ear loops (hollow rectangles)
  // Left ear
  gfx->fillRect(sx(3), sy(5, dy), sw(3), sh(1), COP_EARS);  // top
  gfx->fillRect(sx(3), sy(6, dy), sw(1), sh(1), COP_EARS);  // left wall
  gfx->fillRect(sx(5), sy(6, dy), sw(1), sh(1), COP_EARS);  // right wall
  gfx->fillRect(sx(3), sy(7, dy), sw(3), sh(1), COP_EARS);  // bottom
  // Right ear
  gfx->fillRect(sx(9), sy(5, dy), sw(3), sh(1), COP_EARS);  // top
  gfx->fillRect(sx(9), sy(6, dy), sw(1), sh(1), COP_EARS);  // left wall
  gfx->fillRect(sx(11), sy(6, dy), sw(1), sh(1), COP_EARS); // right wall
  gfx->fillRect(sx(9), sy(7, dy), sw(3), sh(1), COP_EARS);  // bottom
  // Ear stems
  gfx->fillRect(sx(4), sy(8, dy), sw(1), sh(1), COP_BODY);
  gfx->fillRect(sx(10), sy(8, dy), sw(1), sh(1), COP_BODY);
  // Main body (rose shell)
  gfx->fillRect(sx(3), sy(9, dy), sw(9), sh(6), COP_BODY);
  // Face screen (dark inset)
  gfx->fillRect(sx(4), sy(10, dy), sw(7), sh(3.5f), COP_FACE);
}

void copilotSleep(float t) {
  float phase = fmodf(t, 4.0f) / 4.0f;
  float fl = sinf(phase * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), COP_BODY);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), COP_BODY);
  drawCopilotBody(fl);
  // Screen off (no eyes)
  drawZParticles(t);
}

void copilotWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), COP_BODY);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), COP_BODY);
  drawKeyboard(t, COP_KB_BASE, COP_KB_KEY, COP_KB_HI);
  drawCopilotBody(bounce);
  // Gold eyes with blink
  float blinkPhase = fmodf(t, 3.2f);
  float eyeH = (blinkPhase > 2.8f && blinkPhase < 2.95f) ? 0.1f : 1.0f;
  gfx->fillRect(sx(5), sy(10, bounce), sw(1), sh(eyeH), COP_EYE);
  gfx->fillRect(sx(9), sy(10, bounce), sw(1), sh(eyeH), COP_EYE);
  // Ear signal flash
  float sigPhase = fmodf(t, 2.5f);
  if (sigPhase > 2.0f && sigPhase < 2.3f) {
    gfx->fillRect(sx(4), sy(6, bounce), sw(1), sh(1), COP_EYE);
    gfx->fillRect(sx(10), sy(6, bounce), sw(1), sh(1), COP_EYE);
  }
}

void copilotAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5.5f), sy(15), sw(1), sh(1.5f), COP_BODY);
  gfx->fillRect(sx(8.5f), sy(15), sw(1), sh(1.5f), COP_BODY);
  drawCopilotBody(jumpY);
  // Flashing eyes (widen during alert)
  bool flash = sinf(pct * 30) > 0;
  uint16_t eyeCol = (pct > 0.03f && pct < 0.55f && flash) ? COP_ALERT : COP_EYE;
  float eScale = lerpKF(kfEyeSCommon, 6, pct);
  gfx->fillRect(sx(5), sy(10, jumpY), sw(1), sh(eScale), eyeCol);
  gfx->fillRect(sx(9), sy(10, jumpY), sw(1), sh(eScale), eyeCol);
  drawBang(bangOp, bangSc, jumpY, jumpY, COP_ALERT);
}
