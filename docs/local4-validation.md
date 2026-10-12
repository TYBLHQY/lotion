# 7.37.1+local4 验证记录

验证日期：2026-10-12。源代码基于 local3（`b1c4cf8`），继续使用官方 Windows EXE 解包路线。

## 来源与产物

- 官方下载入口：`https://www.notion.so/desktop/windows/download`
- 本次重定向：`https://desktop-release.notion-static.com/Notion%20Setup%207.37.1.exe`
- EXE SHA-256：`7f00e0d00eb364043e1f44c5bed97fcd43697b8ee68a0ad7c47a0d42c96d1891`
- 提取版本：Notion 7.37.1，Electron 43.6.0，better-sqlite3 13.0.1。
- DEB：`dist/Notion_7.37.1+local4_amd64.deb`
- DEB SHA-256：`e44039866a1100c6ff75c7b1a8a03ea3a518525cb3ea1463e7e3faf7d5d96c01`
- 包内 `usr/share/doc/notion/build-manifest.json` 记录 EXE、ASAR、构建源文件、补丁和实际打包的原生模块哈希。

## Alt 弹出菜单的原因与修复

上游主进程将 `notion:alt-key-down` / `notion:alt-key-up` 的菜单处理应用于所有非 macOS 系统。Linux 因此会在 Alt 松开时打开应用菜单。组合键取消事件未到达时，也会走这条路径。

两个处理器的菜单平台条件改为仅 Windows。Linux 仍接收原有按键事件，但不再设置 Alt 菜单状态或调用弹出菜单。`notion:open-app-menu` 的手动入口保持不变；补丁没有拦截其他 Alt 快捷键。

六个兼容补丁使用 Acorn AST 定位，每个目标必须唯一匹配，缺失、重复或重复应用都会停止构建。构建工具版本由 npm lockfile 固定。SQLite 按提取的 Electron 版本编译，移除 SQLite 的其他平台预编译文件和测试扩展。

## REA 辅助分析

使用 [morluto/rea](https://github.com/morluto/rea)，CLI 固定为 `rea-agents@6.4.0`：

```sh
npx --yes rea-agents@6.4.0 analyze-javascript-application /path/to/app.asar --integrity-policy record-and-continue --json
```

原始 ASAR 分析读取 160 个相关文件、解析 97 个 JavaScript 文件、访问 1,813,041 个 AST 节点，解析失败为 0。证据 ID：`ev_d09da4007ba3dd24453f7e4499889c37017fe1f7f242590d07c9735fdaf5cfa6`。

REA 发现原始 EXE 内 5 个原生模块的 ASAR 元数据与实际 unpacked 文件哈希不一致，按未受信任的观察保留。其应用图未解析出打包后的自定义 IPC，Alt 通道追踪没有匹配结果。因此 Alt 因果关系由补充的 AST 检查和真实 Electron 运行测试确认；不能把 REA 的部分静态结果当作完整 IPC 证明。

完整诊断保存在忽略目录 `build/analysis/rea-new.json`，精简记录在 `build/analysis/rea-summary.json`。

## 验证结果

构建时执行真实上游 IPC 回调的 5 项回归测试，全部通过，覆盖 Linux 修复、Windows 保留、macOS 不触发、手动入口不变及补丁失败保护。

隔离 Xvfb 桌面、临时配置目录下执行最终 DEB staging 中的实际 Electron：

| 检查 | local3 | local4 |
| --- | --- | --- |
| 真实 Alt 单键输入 | 弹出菜单 1 次 | 0 次 |
| Alt+Left / Right / A / F / Shift+A | 取消事件正常时未弹出 | 均未弹出 |
| 实际 IPC 中模拟取消事件丢失 | 弹出菜单 1 次 | 0 次 |
| 手动菜单 IPC | 弹出菜单 1 次 | 弹出菜单 1 次 |
| SQLite 内存查询 | 返回 42 | 返回 42 |

local4 的原生菜单栏始终隐藏。`/proc/<pid>/maps` 证明 SQLite 查询实际加载了包内 `app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node`，SQLite 运行版本为 3.53.3。

复现命令：

```sh
xvfb-run -a node scripts/verify-alt-menu.cjs /opt/Notion/notion old
xvfb-run -a node scripts/verify-alt-menu.cjs build/deb-staging/opt/Notion/notion fixed
```

结果与截图保存在 `build/analysis/runtime-{old,fixed}.json`、`alt-{old,fixed}.png` 和 `manual-menu-{old,fixed}.png`。测试仅在临时实例开启 localhost 主进程 inspector；普通启动器未开启 inspector。

上述隔离测试验证启动、菜单和 SQLite。组合键的业务动作、桌面全局快捷键冲突和系统主题切换不在本次测试结论内。

## 本机安装

已通过 apt 从 `7.35.1+local3` 升级至 `7.37.1+local4`，保持原配置目录 `~/.config/Notion`。升级前的完整配置备份为 `~/.local/share/lotion-backups/Notion-before-7.37.1-20261012`，目录权限 0700；原 local3 DEB 保留。

通过用户 systemd 临时服务 `notion-local4.service` 启动普通 launcher。服务状态为 active/running，有可见窗口；实际配置下的 `app_shell_launch` 日志报告 `success: true`。SQLite 工具进程映射了安装路径下的 Linux `better_sqlite3.node`。安装后的 ASAR 哈希与构建清单一致。
