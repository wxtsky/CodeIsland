# 灵动岛展开与收起性能记录

基于 v1.0.41（03c77e9），2026-11-01 在 M4 MacBook Air、16 GB、macOS 15.7.3 上测量。

## 已确认的问题与改动

真实 NotchPanelView、生产 NotchHostingView、固定三条模拟会话可以自动复现舒适模式展开卡顿。线程采样显示，耗时集中在 GraphHost/AttributeGraph 更新期间的 RootGeometry、sizeThatFits 和嵌套 StackLayout 测量；这部分发生在 NSHostingView.layout() 之外，仅记录后者会低估阻塞。

会话列表、舒适卡片、卡片标题行和 SessionIdentityLine 的高度由内容决定，滚动容器负责限制可见范围。为这些边界指定 `.fixedSize(horizontal: false, vertical: true)`，减少父布局对零高度、无限高度等提案的递归测量。水平尺寸仍参与布局，项目名、分支、会话名、短 ID 的三个 ViewThatFits 候选及原有优先级均保留。

弹簧参数、悬停延迟、模糊/淡入淡出/位移过渡、消息与状态更新、分组、审批/问答及滚动代码没有删减。NotchHostingView 仅从 private 改为 internal，让测试直接使用生产宿主。

## 自动测量

测试在独立窗口中循环八次展开/收起，使用模拟会话，不读取用户会话。ScreenCaptureKit 记录面板中线边缘位置与时间戳；同时保存动作时间、主线程 Timer 和宿主 layout 耗时。分析取边缘运动的 5%–95% 区间，不把静止时段当作低帧率。数据是捕获到的可见更新率，不是显示器硬件 FPS。

```bash
PANEL_BENCH_DIR="$PWD/build-dir/benchmark" swift test -c release --filter PanelAnimationBenchmarkTests
python3 scripts/analyze-panel-animation.py build-dir/benchmark
```

已构建后可加 `--skip-build`。`PANEL_BENCH_IDLE=1` 使用全空闲会话；`PANEL_BENCH_COUNT=5` 使用五条会话；`PANEL_BENCH_CONTROL=1` 使用简单弹簧矩形作采集校验。需要本机屏幕捕获能力；默认未设置 PANEL_BENCH_DIR 时跳过性能测试。

统计脚本必须包含跨越动作开始时刻的 Timer 间隔。例如开始前 5 ms 的一次回调与开始后 173 ms 的下一次回调，代表 178 ms 停顿。已为该边界添加 Python 测试。早期仅统计起点在动作之后的间隔，结果低估了主线程阻塞，不能引用。

## 结果与限制

每行八次展开/收起；更新率与首次变化延迟为中位数。

| 场景 | 展开更新/秒 | 收起更新/秒 | 展开首次变化 ms | 收起首次变化 ms |
| --- | ---: | ---: | ---: | ---: |
| 原版，生产宿主，三会话 | 13.1 | 36.5 | 189.4 | 83.5 |
| 最终改动，三会话，首次测试 | 38.2 | 48.0 | 56.7 | 59.7 |
| 最终改动，三会话，重复测试 | 26.0 | 35.7 | 60.0 | 54.4 |
| 最终改动，三会话全空闲 | 25.9 | 38.6 | 59.5 | 54.6 |
| 最终改动，五会话 | 17.4 | 33.2 | 74.3 | 53.0 |

改动降低了起步延迟，但没有实现稳定 60 FPS；五会话仍较慢。首次展开存在 160–220 ms 的捕获空档，不能声称消除了全部卡顿。测试受本机其它负载和捕获开销影响，不是跨设备保证。macOS 26 尚未验证。

仅固定外层宽度、保留列表、去掉模糊、缓存 HStack 尺寸等早期实验没有足够改善，未进入最终生产源码。

## 验证

- 67 项定向 Swift 测试通过：性能测试、列表/完成卡布局、大小字体和高内容边界、标题字段、动画参数、面板窗口等。
- 2 项 Python 分析脚本测试通过。
- 三会话重复、全空闲、五会话自动测试通过；性能结果见上表，不把“测试执行成功”等同于流畅达标。
- Release 可执行文件已打包为独立 CodeIsland-smooth.app，并通过本地签名校验；实际检查了舒适卡片、分组、用量栏与收起状态。
- 没有运行全仓库测试，也没有验证所有外部 AI 工具集成。

本地 CSV、JSON、构建日志与实验备份位于忽略的 build-dir/。原版 /Applications/CodeIsland.app 未覆盖。
