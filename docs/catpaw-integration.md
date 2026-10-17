# CatPaw 基础接入

当前仅适配 macOS，同一协议对应两个独立集成：

| 集成 | source | 配置文件 |
| --- | --- | --- |
| CatPaw IDE | `catpaw` | `~/Library/Application Support/CatPaw IDE/User/globalStorage/mt-idekit.mt-idekit-code/settings/hooks.json` |
| IntelliJ IDEA 插件 IDEKit | `catpaw-idekit` | `~/.sankuai/idekit/config/settings/hooks.json` |

两者分别检测、安装、卸载和开关，共用事件适配器；会话 ID 使用 `<source>:<conversation_id>` 隔离。
安装器根据当前用户的主目录展开路径，hook 的 `command` 只填写 shell 脚本的绝对路径（不带命令行参数）：

- CatPaw IDE：`~/.codeisland/codeisland-catpaw-hook.sh`
- IDEKit：`~/.codeisland/codeisland-catpaw-idekit-hook.sh`

脚本与 bridge 放在同一目录，通过 stdin 传递事件；脚本内部固定 `--source`，
事件名读取输入的 `hook_event_name`。现有 Claude 的 `codeisland-hook.sh` 保持不变。
启动、重新安装或自动修复时会把旧 bridge 命令迁移为脚本路径，并修复缺失/过期/不可执行的脚本。


CatPaw IDE 本机已核实 bundle ID 为 `com.meituan.catpaw`，可通过以下命令读取：

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '/Applications/CatPaw IDE.app/Contents/Info.plist'
```

## IDEKit 宿主定位边界

bundle ID 只识别应用产品，不能定位项目窗口或对话。
IDEKit 在 hook 执行时检查最多 32 层祖先进程，仅接受主可执行文件为
`*.app/Contents/MacOS/idea` 且 bundle ID 为 `com.jetbrains.intellij` 或其点分后缀的 IDEA 宿主。
这是一组保守的识别规则，不保证覆盖所有 IDEA 打包/启动方式，需真实运行日志验证。

记录该祖先进程的 PID，用于进程跟踪；点击卡片时校验 PID 和进程启动时间，
再激活这个确切的运行实例。不会根据 bundle ID 搜索任意 IDEA，也不会用项目名猜窗口。
启动时间缺失、进程已退出、PID 被复用或宿主校验失败时均跳过跳转，
不回退到其他 IDEA 实例或终端，也不会启动新的 IDEA 进程。
没有找到符合条件的祖先时不绑定短命 shell，不尝试跳转。

现有 hook 字段能区分对话、展示工作区，但没有项目窗口 ID、对话跳转协议或插件 RPC。
同一 IDEA 进程有多个项目窗口时，本次只能激活宿主实例，不能精确定位窗口或插件对话。
真正精确的跳转需要 IDEKit 额外提供宿主身份与窗口/项目/对话标识及可调用的跳转接口。

## 当前范围

- `beforeSubmitPrompt`：主 Agent 仅保留前 30 个字符的输入预览，更新工作状态。
- `beforeShellExecution` / `afterShellExecution`：展示 Shell 工具活动，命令最多保留前 30 个字符。
- `beforeMCPExecution` / `afterMCPExecution`：仅展示工具名称，不解析或传输参数和结果。
- `afterAgentResponse`：主 Agent 仅记录前 30 个字符的回复预览，不单独触发完成通知。
- `stop`：使用专用 `CatPawStop` 事件按请求归属进行保守处理；不直接映射通用 `Stop`。

所有 hook 都是观察用途，不审批、不拒绝、不回答问题，不生成 followup。
`conversation_id` 标识会话；`suggest_uuid` 用于请求归属匹配，不映射 tool_use_id。
`is_sub_agent=true` 的受支持活动/回复事件仅保留身份、请求和状态元数据。
bridge 在发送 socket 前剥离 Prompt、回复、命令、参数、输出、附件及未知内容字段；
应用不为子会话创建聊天/工具历史，也不逐个启动宿主监控或切换活跃卡片。
子会话名称仅用于显示，实例身份仍是 conversation_id；所有子任务音效和完成通知静默。

同来源、宿主 PID、远端主机、workspace_roots 和版本范围内，只有一个时间上兼容的活跃主会话时，
子任务先作为显示分组折叠进主卡片，仅展示运行/完成数量。
这只是显示推断，不证明直接父子关系，也不用于 stop 判定。
多个主会话有歧义时保持独立状态卡；共享请求明确归属后再确认父会话。
折叠关系和请求缓存不持久化，重启后不会沿用旧的推断证据。

`stop` 的 conversation_id / is_sub_agent 可能属于主会话，即使实际结束的是子任务。
仅接受 `status=completed`，优先用 suggest_uuid 查找活动/回复事件提供的唯一请求归属；
stop 自身不建立归属。跨会话匹配要求已识别宿主 PID，且子回合不早于主回合。
唯一命中当前子回合时仅置该子会话空闲；唯一命中当前主回合时触发一次主任务完成提示。

协议说明 stop 发生在会话结束，不保证请求 ID 曾在其他 Hook 出现。
对未知请求允许一个受约束的主任务完成候选：同上下文只有一个活跃主会话，所有观察到的
当前子任务均已通过请求匹配确认归属并结束，且主回复在这些结束之后、之后没有继续工具活动。
候选与回复可任意顺序到达；后续工具活动撤销未知 stop 的主任务候选，但保留对子请求的补匹配。
这是兼容现有日志的启发式推断，不能保证覆盖缺失 Hook、嵌套子 Agent 或尚未到达的事件。
不通过“完成了”等回复内容判断结束，也不使用 loop_count 统计子任务。

支持历史请求及 stop 先于响应到达；主任务最终文本晚到仍可更新，晚到工具不重新激活已结束回合。
新 Prompt 开启新回合并清空未匹配 stop；旧回合已知请求不能结束新回合。
每个会话最多保留 512 个请求、128 个待匹配 stop。
冲突、过期请求及非 completed 状态不改变完成状态，不猜测中止、错误或删除语义。
不安装读取文件、编辑文件、思考事件，也不采集思考正文。
CatPaw IDE 与 IDEKit 共用已确认的像素猫爪角色 `CatPawView`，分别表现空闲、思考、执行工具、等待确认和等待回答。
五张 40×40 PNG 位于 `Resources/catpaw-mascot/`，启动后按需缓存，运行时不解码 GIF。
8fps 的四秒动画复用 MascotTimeline 的暂停、速度和减少动态效果机制。
角色设置中可预览并选为默认角色；不会自动修改用户原有的默认空闲角色。

无法确定归属的回合可能继续显示工作状态，直到既有超时/清理机制处理；
这不代表 CatPaw 仍在执行，也不能把超时清理理解为正常完成。

## Hook 共存限制

CatPaw 的 before / stop 只执行第一个有效 hook，项目级配置优先。
若全局配置中本次需要的 before / stop 事件已有其他 hook，安装返回失败并保持文件不变，
不重排、不覆盖已有策略。after hook 保留原条目并追加 CodeIsland 条目。
项目级 hook 也可能遮蔽全局条目，当前不扫描或改写项目配置。

## 日志

联调结束后已移除 CatPaw 专用 JSONL 采集、宿主解析日志和事件耗时埋点。
CatPaw 事件也不写入 bridge 通用调试日志；CodeIsland 未运行时直接返回空对象。
CatPaw 自身的 Hook 执行日志仍由 CatPaw 管理。

## 验证

```sh
swift build --product codeisland-bridge
python3 scripts/test-catpaw-bridge.py
swift test --filter CatPaw
```

bridge 回放使用临时 socket，不会启动 Agent 或改写用户配置。
Swift 单元测试还验证来源隔离、回复不触发完成、安装幂等和已有 hook 的保留；需完整 Xcode。

## 协议核对与性能边界

- before Hook 同步执行，stop 也同步；after Hook 异步，因此响应与 stop 可乱序。
- afterAgentResponse 表示一条完整 assistant 回复，不能单独认定整个任务结束。
- loop_count 是 stop 返回 followup_message 后的续聊次数，从 0 起，最大 5；CodeIsland 始终返回空对象，不发起续聊。
- command 的 cwd 是工具执行目录，不能作为稳定的会话关联键；优先使用 workspace_roots。
- CatPaw 普通事件在收到完整输入后先发送 ACK，再执行界面状态更新；bridge 收到 ACK 即结束等待，不等待连接关闭。
  其他 Agent 的阻塞审批和问题交互不改变。

## 文本预览范围

主 Agent 的 Prompt、回复和 Shell 命令最多保留前 30 个 Unicode 字符，超过时追加 `…`；
短文本原样保留，中文和组合 Emoji 不按字节切割。子 Agent 继续只保留元数据，不恢复正文展示。
参数、输出、MCP 结果、附件、账号以及未知内容字段不进入 socket；工具名称和会话关联元数据保持完整。
过滤在 bridge 的输入适配阶段完成，不增加 shell 解析程序或额外进程；CatPaw 自身的执行日志仍由 CatPaw 管理。
主会话持久化也执行相同预览限制；恢复旧版本保存的主文本时缩短后再进入界面，子正文仍不恢复。
其他来源的 Agent 文本策略保持原样。

CatPaw 子任务数量在普通卡片右侧使用与 Claude 相同的 `+N Sub` 短标记；紧凑卡片也优先保留该短标记。运行／完成数量通过悬浮提示展示，避免长摘要挤占项目名、分支和会话 ID。
