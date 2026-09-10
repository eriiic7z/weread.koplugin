# weread.koplugin · 个人 UI 定制版（fork 1.4.2-fork.6）

基于 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin) v1.4.2 的 UI 定制分支，**与 SimpleUI 深度整合**：让 weread 书架看起来、用起来和 SimpleUI 的界面是一套的。仅供个人学习使用，许可证 AGPL-3.0（来源与免责声明见上游 [README.md](README.md) / [NOTICE](NOTICE)）。

## 这是什么

在上游 weread 完整功能（登录、书架、下载、阅读、同步、划线想法）不变的前提下，把界面统一到 SimpleUI 风格，并让阅读统计页同套体验。

### 外观与布局

- **同一套视觉语言**：书架页顶部让位给 SimpleUI 状态栏、底部使用与 SimpleUI 一致的 dock，来回切换不跳变。
- **视觉规范统一**：书架 / 公众号 / 统计三处一致的字号与 24px 边距；「书籍 / 公众号」tab 高亮为直角小矩形、激活指示线与 dock 分隔线同粗。
- **对齐本地书库（FM）**：顶部标题「微信读书」的字号与高度、标题下分隔线、封面网格左右留白、封面下书名与作者，均与 FM「书库」同参；分页器同款（chevron 图标 + `x/y` 页码、同几何间距），书架 / 公众号 / 本地书库一致。
- **头部紧凑**：书籍 / 公众号标签与排序 / 筛选 / 搜索 / 刷新合并在一行。
- **封面更干净**：细框紧贴封面图，任何比例的封面都完整显示，不拉伸不裁切。

### 交互

- **页内直接使用 SimpleUI 的 dock**：书库 / 主页 / 电源直达，不再需要先退回 SimpleUI；dock 图标与项目跟随 SimpleUI 配置（换图标、加自定义项、改名自动同步）；当前页项无操作并高亮，点统计项直达统计页（详见「使用要点」）。
- **顶部手势**：书架顶部点击 / 下滑呼出 KOReader 原生主菜单（保留上次标签页记忆）。
- **前光手势**：左缘上下滑或双指上下滑直接调光，原生通知反馈。
- **Kindle 式菜单遮罩（全局）**：任何 KOReader 原生菜单（书架 / 文件管理 / 阅读页）弹出时，菜单下方页面压暗（4px 棋盘），不限于 weread。

### 阅读统计页

- 从 dock 打开统计：统计页自带状态栏与底部导航栏（dock 高亮统计项），与书架同一套体验；在阅读器内打开则保持官方全屏样式。

## 安装

1. 确认已安装 **KOReader ≥ 2026.03** 与 **SimpleUI**。
2. 用本仓库内容替换 Kindle 上的插件目录：将本目录整体拷贝覆盖到 `koreader/plugins/weread.koplugin/`（本 fork 与上游同版本部署方式）。
3. 重启 KOReader。

## 前置：在 SimpleUI 里放一个「weread」入口

本 fork 的 weread dock 读取你的 SimpleUI dock 配置（`simpleui_bar_tabs`）。要让「weread」出现在 weread 页内 dock 上：

1. 在 SimpleUI 的 dock 里添加一个快捷项指向本插件（插件 → weread），如你的配置中该项为 `custom_qa_*`。
2. weread 书架打开时，底部 dock 会按 SimpleUI 的顺序显示同样几项，其中 weread 项高亮为当前页。

## 使用要点

1. **离开 weread**：顶部标题栏没有 ✕ 关闭按钮，用底部 dock（书库 / 主页）。
2. **底部 dock 各档行为**：
   - **书库 / 设置 / 历史**：离开 weread 并跳到 SimpleUI 对应屏；
   - **主页**：直接切到 SimpleUI 主页（无中间跳帧）；
   - **电源**：在 weread 页内直接弹出电源菜单（重启 / 休眠 / 退出），退出会正常保存数据；
   - **weread**：当前页（无操作），并显示当前页高亮。
3. **阅读统计页**：在书架 dock 或任意 SimpleUI 屏的 dock 点统计 = 带外壳直达（书架 / 公众号的统计入口同理）；统计页 dock 点「微信读书」项回书架；在阅读器内打开统计仍为官方全屏。
4. **手势**：顶部带（SimpleUI 状态栏所在区域）点击或下滑 → 呼出 KOReader 原生主菜单；左缘 1/8 上下滑或双指上下滑 → 调整前光。
5. **页码导航**：单页时不显示；书架 / 公众号与本地书库为同款样式。
6. **菜单遮罩**：全局行为，禁用 / 卸载本插件即不生效。

## 已知边界

- 镜像的是 SimpleUI 的 **default / icons / 不透明** 配置；若切换 dock 的 bar style（framed/bare）、显示模式（text/both）或透明背景，本 fork 的 dock 暂不跟随。
- dock 依赖 SimpleUI 的设置文件结构（`settings/simpleui/sui_settings.lua`）；对 SimpleUI 的分页尺寸与本地书库视觉适配以运行时补丁实现，不改 SimpleUI 源文件——SimpleUI 大版本更新后需复核。
- **统计页内容区左缘单指调光暂不支持**（与内容滚动为同一手势通道，物理冲突）；统计页可用**双指**调光，书架页左缘单指调光正常可用。
- **SimpleUI 顶部下拉面板的电源 → 退出**，在遮罩启用且 weread 全屏页在场时可能卡住（SimpleUI 面板未适配第三方全屏页叠加）。**请用底部 dock 的电源退出**（页内电源菜单，正常）。
- **e-ink 残影**：原生菜单「长 → 短」切换瞬间，让出区域在 e-ink 屏上可能残留旧帧（关闭菜单即恢复，不影响使用）。

## 来源

fork 自 finlater/weread.koplugin（AGPL-3.0）；协议与上游代码归属原作者，UI 定制为本分支变更。所有产品名称与商标归各自所有者。
