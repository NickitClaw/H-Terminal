# 验证与测试夹具

所有 SSH 验证连接隔离的本地夹具，使用临时生成的密钥和合成输入。不要把这些脚本指向生产服务器。

| 命令 | 前置条件与范围 |
| --- | --- |
| `./scripts/verify.sh unit` | Node 24.14.1、Python 3.9+；控制器、键盘、存储、桥接及验证工具回归 |
| `./scripts/verify.sh browser` | 同上及 Chrome；同步固定 xterm 资源，运行真实页面恶意数据测试 |
| `./scripts/verify.sh build` | DevEco/API26；完整双 ABI 依赖和 HAP 构建、产物审计 |
| `./scripts/verify.sh device` | 已完成构建，一台解锁且完成 IME 初始化的 API26 arm64 模拟器；Native 流控/认证/ASan/UBSan、真实 HUKS 和全部 UI 场景 |
| `./scripts/verify.sh compat` | 已完成构建、模拟器、Docker 和 Chrome；真实 OpenSSH、PAM、vim、tmux、htop |
| `./scripts/verify.sh soak` | 已完成构建、模拟器；单会话和四会话各至少 600 秒持续输出 |
| `./scripts/verify.sh all` | 全部前置条件；依次执行全部检查 |

本地 Chrome 默认使用 macOS 应用路径，其他位置设置 `HT_CHROME`。Linux 浏览器 CI 使用 `npm --prefix terminal exec -- playwright-core install --with-deps chromium` 安装固定版本驱动对应的 Chromium。`HT_DOCKER_CONTEXT` 默认 `colima`；可以指定已有 Docker context，不修改全局默认。`HT_OPENSSH_IMAGE` 可指定已构建测试镜像；默认镜像从固定基础镜像摘要构建，Docker 缓存避免重复安装。测试报告记录实际包版本和镜像 ID，不能仅凭 Docker 标签判断兼容性环境。

`DEVECO_HOME` 默认 `/Applications/DevEco-Studio.app/Contents`。测试假定 hdc 仅有一个目标；不要同时启动多个 UI 测试进程，它们共享模拟器的 UITest 服务。Native 独立进程使用不同临时目录。

## 报告与证据

每次统一验证写入 `.runtime/verification/<UTC 时间>-<模式>/`。`report.json` 区分 `passed`、`failed` 和 `not_run`；记录 Git 提交、是否有未提交修改、源文件内容摘要、执行前后源码变化和 HAP 摘要。检查失败或运行期间源码变化时退出非零，不把后续未执行项标为通过。源码摘要覆盖非忽略的跟踪及新增文件；临时探针必须在退出前恢复源文件。

失败截图、布局和日志只来自合成测试。报告日志会遮蔽私钥 PEM；签名、原始临时私钥、凭据库和整个 `.runtime` 不作为 CI 附件上传。HAP 审计检查双 ABI、测试目录、残留探针和完整私钥块。正常解析器中的 PEM 标题常量不是私钥块。

文件导入测试通过系统保存/选择对话框准备临时合成文件，测试后清空正文并尝试删除。文档 URI 的删除权限可能受平台限制，空文件名可能仍在模拟器中。探针脚本在 `finally` 中恢复源码、清理构建、检查正常产物，并重新安装正常 HAP；探针不进入提交。

## 长时测试

```bash
HT_UI_SCENARIO=soak HT_SOAK_SECONDS=600 ./scripts/test-ui.sh
# 单独重跑四会话，不伪造首次连接代次：
HT_UI_SCENARIO=soak HT_SOAK_COUNTS=4 HT_SOAK_SECONDS=600 ./scripts/test-ui.sh
```

默认结果在 `.runtime/soak`；统一入口将结果放入对应报告目录。每轮预热后测量至少 600 秒，验证实际起始连接代次保持、隐藏输出可恢复、输入和 Ctrl+C 可到达服务器、各层队列未越界。RSS 汇总主进程和渲染进程，共享页可能重复统计；匿名内存的后半段变化和全部样本同时保存。内存有周期性回收时，单个起止差值不能证明持续泄漏。

`inputDispatchToFixtureP95Ms` 从 hdc 点击发起计到本地 SSH 夹具收到输入，包括工具调度和网络路径；不等于本地触控反馈延迟。模拟器结果不能代替真机性能、电量、折叠、多点触控和实体键盘体验验收。

## CI

push/PR 执行 `unit` 和 `browser`。完整模拟器任务需要手动触发、仓库变量 `HT_DEVICE_RUNNER=enabled`，以及标签为 `hterminal-api26` 的 macOS runner。runner 至少为 v2.327.1，并须具备 DevEco、初始化好的模拟器、Docker 和 Chrome；Docker context 可通过仓库变量 `HT_DOCKER_CONTEXT` 指定。Actions 均固定到上游提交。

本地报告只证明本地运行；远端成功与否必须查看对应提交的 GitHub Actions run。
