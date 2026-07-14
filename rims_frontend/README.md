# RIMS Flutter Frontend

RIMS 前端当前目标是内部验收可用的 APP，不是发布版。应用依赖真实后端 API，不再提供 Demo 登录、前端假账号或公开注册入口。

## 运行前提

- Flutter SDK 已安装，并已执行过依赖下载。
- RIMS 后端服务已启动。
- 后端 API 地址可访问，默认地址为 `http://localhost:8080/api/v1`。
- 已获得一个后端账号。账号来源应是后端种子数据或管理员在 APP 管理入口中创建的用户。

前端不内置可登录账号，也不支持公开自助注册。如果本地后端按教程或种子数据初始化，常见开发账号可能是 `admin/admin123`；如果无法登录，以当前后端实际 seed 或数据库用户为准。

## 启动前端

推荐从仓库根目录使用托管生命周期启动。它会检查 WSL、Docker、后端迁移、
确定性夹具、端口和进程所有权，并由 AI 或开发者在本机非交互执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command up -Target web -IncludeDependencies
```

Android 使用已安装 AVD 名称，不使用 `-d all`：

```powershell
$env:RIMS_ANDROID_DEVICE = 'Medium_Phone_API_36.1'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command smoke -Target android -IncludeDependencies -AndroidDevice $env:RIMS_ANDROID_DEVICE
```

以下命令保留为只启动 Flutter 的手工开发方式。使用前应先自行确认后端已经健康。

在本目录执行：

```powershell
flutter pub get --offline
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080/api/v1
```

如果后端使用默认地址，也可以省略 `--dart-define`：

```powershell
flutter run -d chrome
```

桌面端或移动端同样使用 `API_BASE_URL` 指向后端：

```powershell
flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8080/api/v1
```

## 登录和账号

- 登录页只接受真实后端账号。
- 没有账号时，先让管理员创建测试用户，或确认后端 seed 是否已创建管理员账号。
- 管理员登录后可在“我的”页进入轻量管理能力，创建用户、重置密码、管理商品、仓库和角色权限。
- 普通用户不会看到管理入口。

登录失败时请优先检查：

- 后端是否已启动。
- `API_BASE_URL` 是否指向正确后端。
- 账号是否存在于当前后端数据库。
- 密码是否和后端 seed 或管理员设置一致。
- 当前用户是否被禁用或没有绑定可用仓库。

## 本地验收冒烟

完整的真实后端验收优先使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command smoke -Target web -IncludeDependencies
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command smoke -Target android -IncludeDependencies -AndroidDevice $env:RIMS_ANDROID_DEVICE
```

报告位于仓库根目录 `.runtime/rims-local/reports/`。Web 与 Android 执行相同的
登录、会话恢复、跨仓库库存、入库/出库库存影响、普通用户权限和退出旅程。
脚本只清理自己精确拥有的服务和模拟器，并在失败时保留日志、截图和原始输出。

M10 扫码与附件专项验收使用本地后端、本地磁盘和指定 AVD，不依赖云账号：

```powershell
$env:RIMS_ANDROID_DEVICE = 'Medium_Phone_API_36.1'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_m10_smoke.ps1 -AndroidDevice $env:RIMS_ANDROID_DEVICE -BackendDir $env:RIMS_BACKEND_DIR -Output Json
```

AI 会自行启动后端和模拟器，验证相机拒绝/授权、手工条码回退、扫码反馈、
多行出入库及库存影响、5 MiB 附件中断恢复、替换和删除，随后恢复种子基线并
清理受管资源。测试文件位于 `.runtime/rims-local/providers/files`，专项报告位于
`.runtime/m10-smoke-artifacts/`。本地账号为 `admin/admin123` 和
`m9_operator/admin123`；常用条码为 `M10-ACTIVE-001`、
`M10-DISABLED-001`、`M10-WH001-ONLY-001`。

APP 仅申请相机权限；相册和文件使用 Android 系统选择器，不申请旧版存储权限。
用户拒绝相机后仍可手工输入条码，也可重试或前往系统设置。种子重置只允许
`dev`、`development`、`test` 环境，且不会接管或删除非脚本拥有的进程、模拟器
和文件。

### M11 有限离线与同步验收

M11 可由 AI 从完全停止状态自行启动后端、指定 AVD、回环桥接和本次运行独占的
故障代理，无需云账号或对象存储：

```powershell
$env:RIMS_ANDROID_DEVICE = 'Medium_Phone_API_36.1'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_m11_smoke.ps1 -AndroidDevice $env:RIMS_ANDROID_DEVICE -BackendDir $env:RIMS_BACKEND_DIR -BackendWorkspaceRoot $env:RIMS_BACKEND_WORKSPACE_ROOT -Output Json
```

Android 原生数据库位于系统 application-support 目录下的
`rims_offline.sqlite`，由 Drift 和 secure storage 中的独立密钥加密；Web 与
组件测试使用内存实现。基础引用和库存缓存 24 小时内视为新鲜，之后最多保留
30 天作为过期回退；报表新鲜期为 6 小时、额外保留 14 天；最近单据新鲜期为
7 天、额外保留 30 天。使用缓存时界面会显示来源、年龄和过期状态。

离线时可以继续编辑并自动保存六类单据草稿，进程被终止后仍可恢复。创建、完成、
确认、结算和附件操作只有在用户审阅不可变快照并明确确认后才进入待同步队列。
网络恢复不会自动写入后端；用户必须从“同步中心”手工发起前台同步。未知响应会先
查询操作状态，并以同一幂等键重放；服务端冲突不会被覆盖，只能丢弃或创建新的替代
操作。离线缓存库存不具备写入权威。

“我的”页的数据清理入口会先展示当前账号范围的精确数量，内容变化后必须重新确认。
退出会清理缓存、待同步操作、暂存附件、下载和扫码状态；只有用户明确选择保留时，
才可为同一账号保留加密草稿。本地 provider 文件位于仓库根目录
`.runtime/rims-local/providers/files`，M11 报告和故障证据位于
`.runtime/reports/` 与 `.runtime/m11-smoke-artifacts/`。

故障钩子仅在测试构建定义 `RIMS_E2E_M11=true` 时生效，并要求本次运行独占的
`RIMS_E2E_M11_FAULT_CONTROL_URL`。正式默认构建无法开启。验收覆盖飞行模式、
延迟、丢包/API 不可达、Wi-Fi 切换、进程重建、会话和权限过期、未知/重复投递、
服务端冲突、数据库损坏隔离以及失败后的精确清理。

1. 启动后端，确认 `http://localhost:8080/api/v1` 可访问。
2. 启动 Flutter 前端。
3. 使用后端账号登录。
4. 查看“我的”页，确认当前用户、角色、当前仓库显示正确。
5. 切换仓库，确认首页、库存、单据、报表刷新。
6. 搜索库存商品并打开详情。
7. 创建采购入库单并完成，确认库存、流水、首页最近单据变化。
8. 创建销售出库单并完成，确认库存减少；库存不足时显示后端错误。
9. 查看销售报表和库存报表，切换日期范围。
10. 管理员创建测试用户并重置密码。
11. 使用普通用户登录，确认管理入口不可见。
12. 退出登录，确认受保护页面回到登录页。

## 验证命令

从仓库根目录优先执行固定冒烟脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1
```

脚本会隔离 Flutter 工具状态到 `rims_frontend/.tool-state-smoke`，依次执行离线依赖检查、静态检查、测试、Demo 残留扫描和 `git diff --check`，完成后清理临时目录。

如果当前机器的 Pub 缓存缺少依赖，但 `pubspec.lock` 已经解析过，可先跳过离线依赖检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1 -SkipPubGet
```

查看脚本将执行的步骤：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_smoke.ps1 -ListSteps
```

手工验证命令如下。先进入 `rims_frontend`：

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

再从仓库根目录额外执行：

```powershell
git diff --check
rg -n "DemoAuthRepository|DemoUser|登录 Demo|管理员 Demo|普通用户 Demo|admin123|user123|DM-|2024-05|Good morning, 张三|U10086|假数据|模拟数据|固定数据" rims_frontend/lib rims_frontend/test
```

`admin123` / `user123` 等字符串允许出现在历史计划或教程文档中，但不应出现在 `rims_frontend/lib` 主业务代码中。
