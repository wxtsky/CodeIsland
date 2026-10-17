# CatPaw 像素猫爪 · 动态草稿 v1

这是一套原创猫爪概念及 GIF 预览，不是 CatPaw 官方标识。设计已确认并接入 macOS 应用中的 CatPaw IDE / IDEKit 角色。

## 项目实际接入方式

macOS 角色由 `MascotView` 路由到各自的 SwiftUI Canvas 和 `MascotTimeline`。
CatPaw 已使用专属 `CatPawView`，让 `catpaw` 和 `catpaw-idekit` 两个来源共用；主界面不加载 GIF。
已确认的五种姿态以 40×40 PNG 复制到 `Sources/CodeIsland/Resources/catpaw-mascot/`，运行时缓存并按同样的时间曲线动画。
应复用已有 `MascotTimeline` 的动画速度、暂停和限帧机制。列表通常显示 27–32pt。
CLI 图标和 GIF 导出器已加入 CatPaw 来源路由；`catpaw-app-preview.gif` 是应用实际渲染的执行状态预览。

## 建议状态与规格

| 文件 | 对应状态 | 意义 |
| --- | --- | --- |
| catpaw-idle.gif | idle | 空闲或任务完成，闭眼放松 |
| catpaw-processing.gif | processing | 思考中，托腮与思考泡泡 |
| catpaw-running.gif | running | 正在执行工具，键盘与忙碌动作 |
| catpaw-waiting-approval.gif | waitingApproval | 等待确认，琥珀色感叹号 |
| catpaw-waiting-question.gif | waitingQuestion | 等待回答，青色问号与轻微摆头 |

项目支持这 5 个状态；也可像 Claude 一样将 processing/running 和两种等待合并，
只设计 3 类场景，但建议 CatPaw 分别设计 5 类以区分含义。
idle 同时承载已完成状态；当前没有单独的“完成庆祝”角色状态。

GIF 草稿统一为透明背景、160×160px、40×40 原始像素格的整数 4 倍放大、
16 色调色板加透明色、32 帧、4 秒、约 8fps、无限循环。帧延时交替使用
120/130ms，以适配 GIF 的百分之一秒时间单位。单文件约 40–55KB。

这不是项目的硬性素材尺寸约束。新美术可采用 32×32 或 40×40 原始像素格，
预留边距、统一身体锚点，使用最近邻放大；在 27pt、32pt 和深浅背景下确认可读性。
原始 PNG 应保留完整 alpha，GIF 只能表达一位透明。正式动画建议单独制作眨眼、
爪部敲击与提示符动作；本批 GIF 是从五种独立姿态制作的平移/摆动动态草稿。

## 生成与复现

概念设计由内置 image_gen 生成，原文件保存为 design-sheet.png。
GIF 使用本目录的 export-drafts.swift 经原生 CoreGraphics / ImageIO 导出，
不需要 Python、GIF 插件或新增应用运行时依赖。可运行：

```sh
swift export-drafts.swift
```

使用的最终生成提示词：

> Use case: stylized-concept. Asset type: transparent pixel-art mascot design sheet for a tiny desktop coding-agent status indicator, not a ChatGPT pet. Create an original friendly CAT PAW mascot: the subject is a single upright cream-colored cat paw, four round toe pads and one soft coral pink central bean, a tiny expressive face in the central bean, crisp deep plum pixel outlines, flat limited palette, no gradients or antialiasing, chunky readable pixels equivalent to a 32 by 32 base sprite. Show five equally sized poses in a clean horizontal row with generous transparent separation, same character and scale, no labels, no text: relaxed sleepy paw, attentive thinking paw with three small thought dots, busy paw tapping a tiny simple keyboard, upright waiting paw with a small amber exclamation symbol, curious tilted paw with a small cyan question symbol. Transparent background genuinely alpha, no ground plane, no shadows beyond crisp sprite pixels, no full cat body, no existing brand logo. This is a visual design proposal; keep all silhouettes readable at 27–32 screen pixels.
