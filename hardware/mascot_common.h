#pragma once
#include <Adafruit_GFX.h>

// Shared drawing context and helpers used by all mascot headers
extern GFXcanvas16* gfx;

#define RGB565(r, g, b) (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3))

#define SVG_W  15.0f
#define SVG_H  10.0f
#define SVG_Y0 6.0f
#define LCD_W_  172
#define LCD_H_  320
#define SC_     (LCD_W_ / SVG_W)
#define OX__    0.0f
#define OY__    ((LCD_H_ - SVG_H * SC_) / 2.0f)

inline int sx(float x)              { return (int)(OX__ + x * SC_); }
inline int sy(float y, float dy=0)  { return (int)(OY__ + (y - SVG_Y0 + dy) * SC_); }
inline int sw(float w)              { return (int)(w * SC_); }
inline int sh(float h)              { return (int)(h * SC_); }

inline float lerpKF(const float* kf, int nPairs, float pct) {
  if (pct <= kf[0]) return kf[1];
  for (int i = 1; i < nPairs; i++) {
    int j = i * 2;
    if (pct <= kf[j]) {
      float t0 = kf[j-2], v0 = kf[j-1];
      float t1 = kf[j],   v1 = kf[j+1];
      float r = (pct - t0) / (t1 - t0);
      return v0 + (v1 - v0) * r;
    }
  }
  return kf[(nPairs-1)*2 + 1];
}

inline void fillRotatedRect(float rx, float ry, float rw, float rh,
                     float pivX, float pivY, float angleDeg, float dy,
                     uint16_t color) {
  float a = angleDeg * PI / 180.0f;
  float ca = cosf(a), sa = sinf(a);
  float cx[4] = { rx - pivX, rx + rw - pivX, rx + rw - pivX, rx - pivX };
  float cy[4] = { ry - pivY, ry - pivY, ry + rh - pivY, ry + rh - pivY };
  int16_t px[4], py[4];
  for (int i = 0; i < 4; i++) {
    float rotX = cx[i] * ca - cy[i] * sa + pivX;
    float rotY = cx[i] * sa + cy[i] * ca + pivY;
    px[i] = sx(rotX);
    py[i] = sy(rotY, dy);
  }
  gfx->fillTriangle(px[0],py[0], px[1],py[1], px[2],py[2], color);
  gfx->fillTriangle(px[0],py[0], px[2],py[2], px[3],py[3], color);
}

// Common alert jump keyframes (shared by most mascots)
static const float kfJumpCommon[] = {
  0,0, 0.03f,0, 0.10f,-1, 0.15f,1.5f, 0.175f,-10, 0.20f,-10,
  0.25f,1.5f, 0.275f,-8, 0.30f,-8, 0.35f,1.2f, 0.375f,-5, 0.40f,-5,
  0.45f,1.0f, 0.475f,-3, 0.50f,-3, 0.55f,0.5f, 0.62f,0, 1.0f,0
};
static const float kfEyeSCommon[] = {
  0,1.0f, 0.03f,1.0f, 0.031f,1.3f, 0.15f,1.3f, 0.151f,1.0f, 1.0f,1.0f
};
static const float kfBangOpCommon[] = {
  0,0, 0.03f,1, 0.10f,1, 0.55f,1, 0.62f,0, 1.0f,0
};
static const float kfBangScCommon[] = {
  0,0.3f, 0.03f,1.3f, 0.10f,1.0f, 0.55f,1.0f, 0.62f,0.6f, 1.0f,0.6f
};

// Draw floating "z" particles (shared sleep element)
inline void drawZParticles(float t, float baseX = 12.0f, float baseY = 8.0f) {
  for (int i = 0; i < 3; i++) {
    float period = 2.8f + i * 0.3f;
    float offset = i * 0.9f;
    float p = fmodf(t - offset, period);
    if (p < 0) p += period;
    p /= period;
    float opacity = (p < 0.2f) ? (p / 0.2f) : (1.0f - (p - 0.2f) / 0.8f);
    if (opacity <= 0.05f) continue;
    float zx = baseX + sinf(p * PI * 2.0f) * 0.5f;
    float zy = baseY - p * 5.0f;
    int size = (i == 0) ? 2 : 1;
    uint8_t gray = (uint8_t)(100 * opacity);
    uint16_t zcol = RGB565(gray, gray, (uint8_t)min(255, gray + 20));
    gfx->setTextColor(zcol);
    gfx->setTextSize(size);
    gfx->setCursor(sx(zx), sy(zy));
    gfx->print("z");
  }
}

// Draw keyboard (shared work element)
inline void drawKeyboard(float t, uint16_t baseCol, uint16_t keyCol, uint16_t hiCol) {
  gfx->fillRect(sx(-0.5f), sy(11.8f), sw(16), sh(3.5f), baseCol);
  int keyPhase = ((int)(t / 0.1f)) % 6;
  for (int row = 0; row < 2; row++) {
    for (int col = 0; col < 6; col++) {
      float kx = 0.3f + col * 2.5f;
      float ky = 12.2f + row * 1.2f;
      uint16_t c = (row * 3 + col % 3 == keyPhase) ? hiCol : keyCol;
      gfx->fillRect(sx(kx), sy(ky), sw(1.8f), sh(0.7f), c);
    }
  }
}

// Draw exclamation bang (shared alert element)
inline void drawBang(float bangOp, float bangSc, float jumpY, float dy, uint16_t alertCol) {
  if (bangOp <= 0.05f) return;
  float bx = 13.0f;
  float by = 4.5f + jumpY * 0.15f;
  float bw = 2.0f * bangSc;
  float bh1 = 3.5f * bangSc;
  float bh2 = 1.5f * bangSc;
  gfx->fillRect(sx(bx), sy(by, dy * 0.15f), sw(bw), sh(bh1), alertCol);
  gfx->fillRect(sx(bx), sy(by + 4.0f * bangSc, dy * 0.15f), sw(bw), sh(bh2), alertCol);
}

// Shadow helper
inline void drawShadow(float width, float jumpY = 0) {
  float sw_ = width * (1.0f - fabsf(fminf(0, jumpY)) * 0.04f);
  uint8_t sg = (uint8_t)(50 - fabsf(fminf(0, jumpY)) * 3);
  if (sg > 50) sg = 0;
  gfx->fillRect(sx(3 + (9 - sw_)/2), sy(15), sw(sw_), sh(1), RGB565(sg, sg, sg));
}
