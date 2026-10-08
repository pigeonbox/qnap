# PigeonBox QNAP QTS

[![CI](https://github.com/pigeonbox/qnap/actions/workflows/ci.yml/badge.svg)](https://github.com/pigeonbox/qnap/actions/workflows/ci.yml)
[![Release](https://github.com/pigeonbox/qnap/actions/workflows/release.yml/badge.svg)](https://github.com/pigeonbox/qnap/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)

PigeonBox（文件快递柜，匿名口令分享文本/文件）的 **威联通 QTS 原生应用包（QPKG）**：包内自带双架构静态二进制与前端产物，单进程单端口直接运行——**免 Container Station、免 Docker、免在线拉镜像**（对齐 fnos 飞牛应用的原生进程模式）。

- **双架构**：`x86_64` / `arm_64`（按 NAS 机型选包）
- **QTS 4.5+ 即可安装**（此前 Docker 编排壳要求 QTS 5 + Container Station 3）
- 装完即启、开机自启；**看门狗自愈**（进程崩溃自动拉起，`/ping` 连续 3 次无响应自动重启）
- App Center 图标直达 `http://NAS的IP:12345`（改端口后图标链接自动跟随）
- JWT 密钥首启自动生成并持久化到数据目录，重启/升级不丢
- **卸载保留数据**：数据在存储卷根 `pigeonbox/` 目录（QPKG 卸载会删除安装目录，卷根数据不受影响）
- **Docker 旧版原地升级**：QPKG 同名升级即切换为原生进程，卷根数据（SQLite 库/上传文件）直接延续

> 系统要求：QTS 4.5+。无外部依赖。

## 安装

1. App Center → 设置 → General → 勾选 **允许安装没有有效数字签名的应用**（本包为社区签名，一次性设置）
2. App Center 右上角 **手动安装**（人形/加号图标）→ 选择本仓 [Releases](https://github.com/pigeonbox/qnap/releases) 下载的 `PigeonBox_<版本>_<架构>.qpkg`
3. 安装完成自动启动，App Center 主菜单/桌面点 PigeonBox 图标，或浏览器访问 `http://NAS的IP:12345`
4. 默认管理员 `admin/admin123`——**装完先改密码**（或按下文在 `.env` 预置 `PB_ADMIN_PASSWORD` 后再首启）

> **真机验证状态**：qbuild 组包 + payload 结构断言 + 真二进制运行冒烟过 CI；QTS 真机安装验证待补（欢迎反馈 issue）。

## 配置

所有配置集中在存储卷根 `pigeonbox/.env`（File Station 可编辑；改完在 App Center **停止→启动** 本应用生效）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PB_SERVER_PORT` | `12345` | 服务端口（App Center 图标链接自动跟随） |
| `PB_ADMIN_PASSWORD` | 空 | 管理员密码（首启无管理员时以本值播种 admin；留空 = 默认 `admin/admin123`，装完立即改密） |
| `PB_SERVER_BASE_URL` | 空 | 对外完整地址（有域名/HTTPS 反代时填，分享链接会用它；留空按请求来源推断） |
| `PB_USER_ALLOW_REGISTRATION` | `false` | 开放注册（NAS 场景默认关闭，管理员建号） |
| `PB_TRUSTED_PROXIES` | 空 | 可信代理 CIDR（套反代时必填，否则限流按代理 IP 计数） |
| `PB_JWT_SECRET` | 空 | 留空=数据目录自动生成持久化（`.jwt_secret`） |
| `PB_REDIS_HOST` | 空 | 默认单机内存模式（免 Redis 全功能；启用需自备实例） |

### 改/重置管理员密码

管理员密码不会覆盖已有账号（防误改）。改密码三步：

1. 编辑 `pigeonbox/.env`：`PB_ADMIN_PASSWORD="新密码"`
2. `touch /share/CACHEDEV1_DATA/pigeonbox/.admin_reset`（卷根 `pigeonbox/` 目录旁）
3. App Center 停止→启动应用

启动时自动删除 admin 账号并按新密码重建（全程审计在 `pigeonbox/data/.admin_reset.log`，重置成功后 `.env` 中的明文密码自动清空）。忘记密码走同样流程。

更多高级项（存储后端切换、联邦等）见生态主仓 [ENVIRONMENT_VARIABLES.md](https://github.com/pigeonbox/pigeonbox/blob/main/docs/ENVIRONMENT_VARIABLES.md)；高级用户可在卷根 `pigeonbox/` 放置 `config.yaml`（服务脚本检测到即启用，env 优先级始终更高）。

## 数据与备份

- 全部状态在卷根 `pigeonbox/` 一个目录里：`data/fileCodeBox.db`（SQLite）、`data/uploads/`、`.jwt_secret`、`pigeonbox.log`（应用日志，超 10MB 自动截尾）
- 备份 = Hybrid Backup Sync / File Station 复制该目录（停止应用后拷贝最干净）
- **卸载应用默认保留**该目录；确认不要了在 File Station 手动删除

## 常见问题

- **装完图标点开端口不对**：图标端口在服务启动时自动同步 `.env` 的 `PB_SERVER_PORT`；刚改完配置重启一次应用即可
- **启动后一会儿显示已停止**：看卷根 `pigeonbox/pigeonbox.log`；看门狗每 30s 自检，进程崩溃会被自动拉起，持续停止多为端口被占（改 `PB_SERVER_PORT`）
- **从 Docker 旧版（≤1.14.3）升级**：直接装新 QPKG 即可，数据无缝延续；升级钩子会自动清掉旧编排遗留的死配置行（`PB_IMAGE_TAG`/`FCB_API_PORT` 等）

## 开发与构建

仓库结构：`cmd/pigeonbox`（Go 入口,库调用 core）+ `internal/adminreset`（密码重置）+ `qpkg/`（qpkg.cfg / package_routines / shared 服务脚本+env 模板 / icons / 双架构 bin 产物位）+ `scripts/`（build-native 组产物,build-qpkg QDK 组包）+ `tests/`（mock 冒烟）。

依赖钉版走发版列车：`CORE_PIN`/`FRONTEND_REF` 在 `DEPS.env`（真相源=hub `release/train.yaml`,由 `make train-bump` 写入,勿手改）。

```sh
# 本地开发(工作区内联编本地 core / GOWORK=off 钉正式 tag,两者皆可)
go build ./cmd/pigeonbox && go vet ./... && go test -race ./...

# 组包三步(产物均 gitignored)
make native                    # 双架构静态二进制 + 前端 www → qpkg/(GOWORK=off 钉版构建)
make qpkg                      # QDK qbuild 双架构组包 → dist/*.qpkg(.md5),需先装 QDK:
git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
./tests/run-tests.sh           # 服务脚本/安装钩子 mock 冒烟(无 QTS 也可跑)
```

打 `v*` tag 自动：原生构建 → 双架构组包+结构断言 → 挂本仓 Release → 回挂生态主仓 `qnap-v*` Release（需 `QNAP_PAT`,未配置时 CI 放行失败、本地 `gh release upload` 兜底）。

**真机验证状态**：CI 覆盖 qbuild 组包、payload 结构断言与真二进制运行冒烟；QTS 真机安装/升级(Docker 旧版→原生)验证待补（欢迎反馈 issue）。

## 参考（格式来源）

- [qnap-dev/QDK](https://github.com/qnap-dev/QDK)（官方打包器：qpkg.cfg 模板 / qinstall.sh / qbuild）
- 生态同构先例：[pigeonbox/fnos](https://github.com/pigeonbox/fnos)（fpk 原生进程模式）、[pigeonbox/openwrt](https://github.com/pigeonbox/openwrt)（ipk 库式调 core）

## License

Apache-2.0（与生态一致，见 [LICENSE](./LICENSE)）。
