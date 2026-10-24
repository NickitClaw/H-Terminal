# H-Terminal 方案设计

H-Terminal 是一款专门适配 Huawei Pura X Max 折叠屏、HarmonyOS 7 的终端/命令行 App，支持通过 SSH 连接远端 Linux/Unix 服务器。其核心交互是在内屏约 90° 展开时提供类似笔记本电脑的体验：上方显示终端，下方显示桌面式全功能键盘。

## 1. 总体结论

该方案可行，不需要从零编写终端仿真器，也不建议直接照搬 Termux。推荐首版采用：

> **HarmonyOS 7 / API 26 + ArkUI 原生外壳 + xterm.js 终端 + Native C++ SSH + 自定义下屏全功能键盘。**

终端区域首版可以使用 ArkWeb，因此不是“纯无 WebView 原生”。如果坚持纯原生，可评估较新的 `libghostty-ohos`，但需要预留更多真机验证和缺陷修复时间。

本文基于官方文档和社区源码调研，尚未在 Pura X Max 真机上验证。

## 2. 平台能力与社区方案

[Pura X Max 官方规格](https://consumer.huawei.com/cn/phones/pura-x-max/specs/)确认其内屏为 7.7 英寸、2584×1828，运行 HarmonyOS 7；[HarmonyOS 7 开发者公告](https://developer.huawei.com/consumer/cn/notice/detail/?id=9002210958618976001)明确其目标 SDK 为 **API 26**。华为的 [Pura X Max 适配指南](https://developer.huawei.com/consumer/cn/doc/doccenter-multi-device/bpta-purax-guide)也明确包含悬停态。

因此，专供这款设备时可以直接以 API 26 为基线，不必为首版增加旧系统兼容负担。

### 2.1 当前主要技术路线

鸿蒙终端目前还没有像 Termux 那样的单一事实标准，更准确地说是以下几类方案：

| 路线 | 代表项目 | 适用判断 |
| --- | --- | --- |
| ArkWeb + 设备内 Node.js | [electerm-harmony](https://github.com/electerm/electerm-harmony) | 已有完整 SSH/SFTP 等产品能力，适合快速功能验证；但 Node 运行时较重，还要维护本地服务和运行时的安全边界 |
| ArkWeb/xterm.js + Native SSH | [CrossShellNext](https://gitcode.com/OpenHarmonyPCDeveloper/CrossShellNext) 等 | 终端兼容性、开发量和包体之间最平衡，推荐作为本产品首版路线 |
| 原生 VT + 原生渲染 | [libghostty-ohos](https://github.com/wiedymi/libghostty-ohos) | 已提供 `TerminalSurface`、XComponent、IME、选择和滚动区；但不提供 SSH，且目前仍属早期的 0.1.x 项目 |
| 本地 Shell/Linux 兼容环境 | [Termony](https://github.com/TermonyHQ/Termony)、Harmonix、HiSH | 主要解决本地命令、HNP、QEMU 或 Linux 环境，不是现成 SSH SDK；首版做 SSH 不必引入这些复杂度 |
| 商业原生产品 | [TermNext](https://termnext.com/en/) | SSH、Mosh、SFTP、MFA、跳板机和转发可作为功能标杆；本次调研未找到可复用的开源实现 |

### 2.2 可借鉴的终端交互

- [Termux 的 Extra Keys](https://github.com/termux/termux-app/blob/master/termux-shared/src/main/java/com/termux/shared/termux/settings/properties/TermuxPropertyConstants.java)：可配置按键、宏、弹出键。
- [Termius 扩展键盘](https://docs.termius.com/terminal/mobile-terminal)：功能键、导航键、自定义键组、片段“插入/运行”分离、外接硬件键盘模式。
- [Windows Terminal 的交互保护](https://learn.microsoft.com/en-us/windows/terminal/customize-settings/interaction)：多行/大段粘贴警告、应用快捷键与终端输入分层。

但在 90° 姿态下不应继续使用“26 键系统键盘＋两行快捷键”，下屏应直接升级为桌面式键盘。

## 3. 推荐总体架构

```text
┌──────────────────── ArkUI / ArkTS ────────────────────┐
│ 主机管理   会话标签   设置   SFTP 页面                 │
│                                                       │
│ PostureEngine       TerminalContainer                 │
│ 折叠/角度/折痕  →   xterm.js @ ArkWeb                 │
│                     ↑ 可替换为 libghostty-ohos         │
│ LaptopKeyboard → InputRouter → 终端键盘编码            │
└──────────────────────┬────────────────────────────────┘
                       │ N-API：批量字节流、状态事件、resize
┌──────────────────────▼────────────────────────────────┐
│ Native SessionManager                                 │
│ SSH Session / Channel / SFTP / Forwarding             │
│ HostKey 校验 / 重连 / 有界队列 / 背压                  │
│ libssh2 安全审计构建，或 libssh 备选                   │
└──────────────────────┬────────────────────────────────┘
                       │
                HUKS / ASSET / 沙箱
```

### 3.1 关键设计原则

- **不要自己实现 VT 解析器**。[xterm.js](https://github.com/xtermjs/xterm.js)已经覆盖 curses、vim、tmux、鼠标、Unicode、IME 等大量终端边界情况。
- SSH 放在 Native 层，避免为了 SSH 引入完整 Node.js 运行时。
- `SessionManager` 不依赖 ArkUI 页面生命周期。开合屏幕只改变布局，不能重建 SSH 会话。
- Native 到 ArkWeb 使用受控桥接，按块传递数据并设置有界队列、背压；不要逐字节调用 `runJavaScript`，也不要把远端输出拼接成 JS 源码。
- 定义统一的 `TerminalBackend` 接口，后续只有实测证明 ArkWeb 性能或 IME 不达标时，才替换为原生 Ghostty。
- SSH 库若选 libssh2，应使用固定、经过安全补丁审计的构建，不能直接复制社区示例附带的旧库。其[公钥签名回调](https://libssh2.org/libssh2_userauth_publickey.html)便于接 HUKS。
- 如果团队没有能力维护 libssh2 安全分支，建议改用已有安全正式版的 [libssh 0.12.2+](https://www.libssh.org/2026/07/28/libssh-0-12-2-security-release/)，同时完成 HUKS 签名适配和 LGPL 合规评审。

## 4. 90°“类笔记本”布局

### 4.1 姿态识别

使用官方 [display API](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-References/js-apis-display) 和[悬停态适配指南](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-folded-hover)，组合判断：

- `FOLD_STATUS_HALF_FOLDED`：只表示半折，不等于恰好 90°。
- `foldAngleChange`：角度范围 0～180°，用于识别约 90° 区间。
- `getLiveCreaseRegion()` 或当前折痕接口：确认折痕确实将应用窗口分成上下区域。
- `foldDisplayModeChange`、`windowRectChange`：确认当前使用内屏，并等待窗口尺寸稳定。
- 分屏、悬浮窗、外屏或折痕不与窗口相交时，退回普通布局。

可以从“75°～105°进入，小于 65°或大于 120°退出，稳定约 200ms 后再布局”作为初始参数，加入迟滞避免反复跳动；这些数值必须通过真机校准，同时提供手动切换按钮。

建议使用**自定义 ArkUI 布局**，而不是强依赖 `FolderStack` 或 `FoldSplitContainer`，因为本产品还需要手动模式、紧凑键盘、外接键盘和多窗口回退。

布局时让终端组件始终保留在同一个组件节点，只调整位置和尺寸。尺寸稳定后再计算终端行列，并发送 SSH `window-change`，避免连续触发远端 TUI 重绘。

### 4.2 下屏键盘

建议采用 **75% 风格、六行紧凑全功能键盘**：

```text
Esc  F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12  Del
`~   1! 2@ 3# 4$ 5% 6^ 7& 8* 9( 0) -_ =+      Backspace
Tab  Q  W  E  R  T  Y  U  I  O  P  [{ ]}  \|
Caps A  S  D  F  G  H  J  K  L  ;:  '"         Enter
Shift Z X  C  V  B  N  M  ,<  .>  /?  Shift      ↑
Ctrl Fn 中/英 Alt       Space       AltGr Ctrl  ← ↓ →
```

设计要点：

- `Esc`、独立 F1～F12、完整符号、左右 Ctrl/Alt、倒 T 方向键始终可用。
- `Fn+方向键` 提供 Home、End、PgUp、PgDn；紧凑模式下用 `Fn+数字键`提供功能键。
- 数字小键盘作为可选覆盖层，不常驻。这里是**键位桌面化**，不是实体键盘的全尺寸键距。
- 下屏使用普通 ArkUI 组件，而不是依赖覆盖式的 `TextInput.customKeyboard`，这样更容易严格限制在折痕以下。
- 按实际下屏尺寸计算 15u 网格；主键热区以约 48vp 为起点，空间不足时切换五行紧凑模式，不要无限缩小按键。
- 支持真实多点组合，也支持粘滞修饰键：单击只作用于下一次组合，双击锁定，状态必须可见；切换会话或失焦时清除。
- `Ctrl+C`固定发送远端中断，`Ctrl+Shift+C`才复制；`Ctrl+Shift+V`粘贴，多行和大段粘贴先警告。
- 上屏支持滚动、长按选择、双指缩放；TUI 捕获鼠标时，可用 Shift 强制本地选择。
- 接入外接键盘后，下屏可切换为快捷键、片段或触控板，但允许用户保留触屏键盘。

### 4.3 其他设备形态

- **完全展开**：单终端，可选会话侧栏，不机械保留上下分屏。
- **外屏**：终端＋紧凑 Extra Keys，不硬塞完整键盘。
- **分屏/悬浮窗**：只按实际窗口尺寸布局。

## 5. 中文输入设计

华为[自定义键盘能力](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-customize-keyboard)解决的是键盘 UI，**并不自带拼音组字、词库和候选词引擎**。

建议分两步：

1. **首版**：英文、符号和控制键直接发送；提供“系统中文”模式，通过真实输入焦点和系统 IME 输入，只把最终提交的 Unicode 文本发送一次，并采用 `KeyboardAvoidMode.RESIZE` 尽量保持终端可见。
2. **严格要求中文候选也固定在下屏时**：后续在应用内键盘中接入离线拼音引擎，自己绘制预编辑和候选栏。除非还要给其他 App 使用，否则不必首版就开发系统级 `InputMethodExtensionAbility`。

普通应用无法保证第三方系统 IME 的键盘和候选窗口始终落在物理下屏，这一点不能作为首版未经验证的承诺。

## 6. SSH、安全与断线恢复

首版安全基线应包括：

- 密码、公钥、`keyboard-interactive`，后者覆盖常见 MFA/跳板机交互。
- 首次连接展示 SHA-256 主机密钥指纹并采用 TOFU；主机密钥变化默认阻止连接，且必须在校验主机后再认证。
- 优先通过 [HUKS](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/huks-key-generation-overview) 生成和使用不可导出的 Ed25519 私钥；密码或密钥口令经用户同意后使用 [ASSET](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/asset-scenario1) 保存。
- 私钥、密码不得进入 ArkWeb、日志或明文备份；旧算法只能按单个主机显式放开。
- Agent forwarding、远端读取本地剪贴板默认关闭；OSC 52 写入剪贴板按主机配置为询问或允许，并限制大小。
- SSH 自动重连只能重建连接，**不能自动恢复原 Shell**。首版推荐“重连＋远端 tmux”，Mosh 作为后续独立协议支持，不要把它当成 SSH 的一个开关。

## 7. 实施顺序

1. **真机技术验证**：折痕坐标与角度、90°布局、完整键盘焦点、xterm.js 性能、Native SSH、HUKS 签名、中文 IME。
2. **MVP**：主机管理、三种认证、主机密钥校验、多会话、上下屏布局、完整特殊键、复制粘贴、滚动区、终端 resize、安全存储。
3. **桌面体验完善**：自定义键位和片段、物理键盘/触控板、SFTP、跳板机、本地转发、中文输入增强。
4. **按需扩展**：原生 Ghostty 渲染、远程/动态转发、Mosh、本地 Shell；均由实测需求驱动，不首发堆功能。

## 8. 验收标准

发布前至少验证：

- `vim`、`tmux`、`htop`、true color、CJK/emoji、鼠标和 alternate screen 正常。
- 反复进行“展开→90°→折叠→展开”，SSH 不重连，滚动区、选区和输入状态不丢失，`stty size` 与可见终端一致。
- Ctrl/Alt/Esc/F 键、方向键、组合键和中文提交不重复、不串会话。
- 大输出和大粘贴有背压与警告，UI 不被网络回调阻塞。
- 错误主机密钥会被阻止，日志无秘密，Native SSH 通过恶意服务器与模糊测试。
- Wi-Fi/蜂窝切换、熄屏、后台和进程被杀后的行为明确；不能把系统后台存活当作无限保证。

## 9. 核心产品决策

把“折叠姿态”和“桌面式输入”做好，而不是首版堆最多的协议。xterm.js＋Native SSH 是目前最平衡的起点，原生渲染和 Mosh 都可以在其后平滑增加。
