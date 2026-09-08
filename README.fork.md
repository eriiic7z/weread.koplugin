# weread.koplugin · 个人 UI 定制版（fork 1.4.2-fork.2）

基于 [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin) v1.4.2 的 UI 定制分支，**与 SimpleUI 深度整合**：让 weread 书架看起来、用起来和 SimpleUI 的界面是一套的。仅供个人学习使用，许可证 AGPL-3.0（来源与免责声明见上游 [README.md](README.md) / [NOTICE](NOTICE)）。

## 这是什么

在上游 weread 完整功能（登录、书架、下载、阅读、同步、划线想法）不变的前提下，把书架界面的视觉与交互统一到 SimpleUI 风格：

- **和 SimpleUI 同一套视觉语言**：书架页顶部让位给 SimpleUI 状态栏、底部使用与 SimpleUI 一致的 dock，两界面来回切换不跳变。
- **书架封面更干净**：封面细框紧贴封面图，任何比例的封面都完整显示，不拉伸不裁切。
- **头部一行搞定**：书籍/公众号标签 + 排序/筛选/搜索/刷新合并在一行。
- **在 weread 里就能用 SimpleUI 的 dock**：书库/主页/电源直达，不再需要先退回 SimpleUI。
- **顶部下拉原生菜单**：书架顶部点击 / 下滑，与 KOReader 其它页面一样呼出原生主菜单（上次的标签页记忆不变）。
- **Kindle 式菜单遮罩（全局）**：菜单弹出时页面压暗，外观对标 Kindle 原生下拉（4px 棋盘）；作用于 KOReader 所有原生菜单（书架、文件管理、阅读页），不限于 weread。
- **前光快捷手势**：左缘上下滑 / 双指上下滑直接调光，原生通知反馈。

## 安装

1. 确认已安装 **KOReader ≥ 2026.03** 与 **SimpleUI**。
2. 用本仓库内容替换 Kindle 上的插件目录：将本目录整体拷贝覆盖到 `koreader/plugins/weread.koplugin/`（本 fork 与上游同版本部署方式）。
3. 重启 KOReader。

> 开发期在 Mac 与 Kindle 间同步的命令见下文「维护者同步」。

## 前置：在 SimpleUI 里放一个「weread」入口

本 fork 的 weread dock 读取你的 SimpleUI dock 配置（`simpleui_bar_tabs`）。要让「weread」出现在 weread 页内 dock 上：

1. 在 SimpleUI 的 dock 里添加一个快捷项指向本插件（插件 → weread），如你的配置中该项为 `custom_qa_*`。
2. weread 书架打开时，底部 dock 会按 SimpleUI 的顺序显示同样几项，其中 weread 项高亮为当前页。

## 使用要点

- 顶部标题栏**没有 ✕ 关闭按钮**：离开 weread 用底部 dock（书库/主页）。
- 底部 dock 各档行为：
  - **书库 / 设置 / 历史**：离开 weread 并跳到 SimpleUI 对应屏；
  - **主页**：直接切到 SimpleUI 主页（无中间跳帧）；
  - **电源**：在 weread 页内直接弹出电源菜单（重启 / 休眠 / 退出），退出会正常保存数据；
  - **weread**：当前页。
- **顶部带手势**（书架页顶部，SimpleUI 状态栏所在区域）：点击、或从顶部下滑（含顶部中间扩展带）→ 呼出 KOReader 原生主菜单；左缘 1/8 上下滑、或双指上下滑 → 调整前光。
- **菜单遮罩为全局行为**：安装本 fork 后，KOReader 任何原生菜单（书架 / 文件管理 / 阅读页）弹出时菜单下方都会压暗（Kindle 式棋盘）；由本插件在启动时的一次性运行时补丁实现，禁用 / 卸载本插件即不生效。
- 页码导航与上游一致（单页不显示）。

## 已知边界

- 镜像的是 SimpleUI 的 **default / icons / 不透明** 配置；若在 SimpleUI 里切换 dock 的 bar style（framed/bare）、显示模式（text/both）或透明背景，本 fork 的 dock 暂不跟随。
- dock 依赖 SimpleUI 的设置文件结构（`settings/simpleui/sui_settings.lua`），SimpleUI 大版本如改动存储结构可能需要适配。

## 维护者同步

- 与上游合并：`git fetch upstream && git merge upstream/main`（在 `main` 分支进行）。
- 合并约定：**保留**主 README.md 顶部 `<!-- fork-banner -->` 块（以上游冲突时以本 fork 为准）；**不要改动** `_meta.lua` 的 `version` 与上游 CHANGELOG.md 的正式发布段——版本号跟随上游，fork 变更记录见 [CHANGELOG.fork.md](CHANGELOG.fork.md)。
- Mac → Kindle 同步：

```bash
rsync -av --delete \
  --exclude '.git/' --exclude '.gitignore' --exclude '.github/' \
  --exclude 'spec/' --exclude 'scripts/' --exclude 'docs/' \
  --exclude 'screenshots/' --exclude 'CHANGELOG.md' --exclude 'CLAUDE.md' \
  --exclude 'CONTRIBUTING.md' --exclude 'README.fork.md' --exclude 'CHANGELOG.fork.md' \
  ./ /Volumes/Kindle/koreader/plugins/weread.koplugin/
```

## 来源

fork 自 finlater/weread.koplugin（AGPL-3.0）；协议与上游代码归属原作者，UI 定制为本分支变更。所有产品名称与商标归各自所有者。
