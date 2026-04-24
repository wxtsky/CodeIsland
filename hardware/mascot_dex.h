#pragma once
#include "mascot_common.h"

// Dex (Codex) — Cloud blob with terminal prompt face
#define DEX_BODY    RGB565(235, 235, 237)
#define DEX_LEG     RGB565(178, 178, 184)
#define DEX_PROMPT  0x0000
#define DEX_ALERT   RGB565(255, 140, 0)
#define DEX_KB_BASE RGB565(46, 46, 51)
#define DEX_KB_KEY  RGB565(102, 102, 107)
#define DEX_KB_HI   0xFFFF

static void drawDexBody(float dy) {
  // Cloud shape: detailed pixel rows matching Swift
  gfx->fillRect(sx(4), sy(14, dy), sw(7), sh(1), DEX_BODY);
  gfx->fillRect(sx(3), sy(13, dy), sw(9), sh(1), DEX_BODY);
  gfx->fillRect(sx(2), sy(12, dy), sw(11), sh(1), DEX_BODY);
  gfx->fillRect(sx(1), sy(9, dy), sw(13), sh(3), DEX_BODY);
  gfx->fillRect(sx(2), sy(8, dy), sw(11), sh(1), DEX_BODY);
  gfx->fillRect(sx(2), sy(7, dy), sw(11), sh(1), DEX_BODY);
  // Top bumps
  gfx->fillRect(sx(3), sy(6, dy), sw(3), sh(1), DEX_BODY);
  gfx->fillRect(sx(6), sy(6, dy), sw(3), sh(1), DEX_BODY);
  gfx->fillRect(sx(9), sy(6, dy), sw(3), sh(1), DEX_BODY);
  // Sub-bumps
  gfx->fillRect(sx(4), sy(5, dy), sw(2), sh(1), DEX_BODY);
  gfx->fillRect(sx(6.5f), sy(5, dy), sw(2), sh(1), DEX_BODY);
  gfx->fillRect(sx(9), sy(5, dy), sw(2), sh(1), DEX_BODY);
}

void dexSleep(float t) {
  float phase = fmodf(t, 4.0f) / 4.0f;
  float fl = sinf(phase * 2.0f * PI) * 0.8f;
  drawShadow(7.0f + fabsf(fl) * 0.3f);
  gfx->fillRect(sx(5), sy(15), sw(1), sh(1.5f), DEX_LEG);
  gfx->fillRect(sx(9), sy(15), sw(1), sh(1.5f), DEX_LEG);
  drawDexBody(fl);
  // Dim cursor bar only (mouth closed)
  float blinkPhase = fmodf(t, 1.2f);
  if (blinkPhase < 0.6f)
    gfx->fillRect(sx(8), sy(12, fl), sw(1.5f), sh(0.5f), DEX_PROMPT);
  drawZParticles(t);
}

void dexWork(float t) {
  float bounce = sinf(t * 2.0f * PI / 0.4f) * 1.0f;
  drawShadow(7.0f, bounce);
  gfx->fillRect(sx(5), sy(15), sw(1), sh(1.5f), DEX_LEG);
  gfx->fillRect(sx(9), sy(15), sw(1), sh(1.5f), DEX_LEG);
  drawKeyboard(t, DEX_KB_BASE, DEX_KB_KEY, DEX_KB_HI);
  drawDexBody(bounce);
  // Full ">_" prompt
  gfx->fillRect(sx(5), sy(11.5f, bounce), sw(1.5f), sh(1.5f), DEX_PROMPT); // >
  float blinkPhase = fmodf(t, 0.3f);
  if (blinkPhase < 0.15f)
    gfx->fillRect(sx(8), sy(12, bounce), sw(1.5f), sh(0.5f), DEX_PROMPT); // _
}

void dexAlert(float t) {
  float pct = fmodf(t, 3.5f) / 3.5f;
  float jumpY = lerpKF(kfJumpCommon, 18, pct);
  float bangOp = lerpKF(kfBangOpCommon, 6, pct);
  float bangSc = lerpKF(kfBangScCommon, 6, pct);
  drawShadow(7.0f, jumpY);
  gfx->fillRect(sx(5), sy(15), sw(1), sh(1.5f), DEX_LEG);
  gfx->fillRect(sx(9), sy(15), sw(1), sh(1.5f), DEX_LEG);
  drawDexBody(jumpY);
  // Flashing prompt
  bool flash = sinf(pct * 25) > 0;
  uint16_t promptCol = flash ? DEX_ALERT : DEX_PROMPT;
  gfx->fillRect(sx(5), sy(11.5f, jumpY), sw(1.5f), sh(1.5f), promptCol);
  gfx->fillRect(sx(8), sy(12, jumpY), sw(1.5f), sh(0.5f), promptCol);
  drawBang(bangOp, bangSc, jumpY, jumpY, DEX_ALERT);
}
