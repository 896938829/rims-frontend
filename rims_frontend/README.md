# RIMS Flutter Frontend

RIMS 前端当前目标是内部验收可用的 APP，不是发布版。应用依赖真实后端 API，不再提供 Demo 登录、前端假账号或公开注册入口。

## 运行前提

- Flutter SDK 已安装，并已执行过依赖下载。
- RIMS 后端服务已启动。
- 后端 API 地址可访问，默认地址为 `http://localhost:8080/api/v1`。
- 已获得一个后端账号。账号来源应是后端种子数据或管理员在 APP 管理入口中创建的用户。

前端不内置可登录账号，也不支持公开自助注册。如果本地后端按教程或种子数据初始化，常见开发账号可能是 `admin/admin123`；如果无法登录，以当前后端实际 seed 或数据库用户为准。

## 启动前端

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
