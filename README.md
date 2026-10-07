# PigeonBox QNAP QTS

[![CI](https://github.com/pigeonbox/qnap/actions/workflows/ci.yml/badge.svg)](https://github.com/pigeonbox/qnap/actions/workflows/ci.yml)
[![Release](https://github.com/pigeonbox/qnap/actions/workflows/release.yml/badge.svg)](https://github.com/pigeonbox/qnap/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)

PigeonBox（文件快递柜，匿名口令分享文本/文件）的 **威联通 QTS 应用包（QPKG）**：基于官方 Docker 镜像（`ghcr.io/pigeonbox/server` + `frontend`）的 docker-compose 编排，容器在 Container Station 界面可见可管理。

- **双架构**：`x86_64` / `arm_64`（按 NAS 机型选包）
- 装完即启、开机自启（rcS 托管，自动等待 Container Station 就绪）
- App Center 图标直达 `http://NAS的IP:12345`（改端口后图标链接自动跟随）
- JWT 密钥首启自动生成并持久化到数据目录，重启/升级不丢
- **卸载保留数据**：数据在存储卷根 `pigeonbox/` 目录（QPKG 卸载会删除安装目录，卷根数据不受影响）
- 升级自动对齐镜像版本（`.env` 的 `FCB_IMAGE_TAG` 随包刷新）

> 系统要求：**QTS 5.0+**，App Center 已安装 **Container Station 3**（docker/compose 由其提供）。

## 安装

1. App Center 已装 **Container Station**（首次使用先完成其初始化）
2. App Center → 设置 → General → 勾选 **允许安装没有有效数字签名的应用**（本包为社区签名，一次性设置）
3. App Center 右上角 **手动安装**（人形/加号图标）→ 选择本仓 [Releases](https://github.com/pigeonbox/qnap/releases) 下载的 `PigeonBox_<版本>_<架构>.qpkg`
4. 安装完成自动启动，App Center 主菜单/桌面点 PigeonBox 图标，或浏览器访问 `http://NAS的IP:12345`
5. 默认管理员 `admin/admin123`——**装完先改密码**

> 首次启动需从 ghcr.io 拉取镜像（约 200MB），启动脚本会后台等待拉取完成。国内网络拉取慢/失败时，先在 Container Station「镜像」页手动拉取/导入同名镜像，再重启本应用。

## 配置

所有配置集中在存储卷根 `pigeonbox/.env`（File Station 可编辑；改完在 App Center **停止→启动** 本应用生效）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `FCB_IMAGE_TAG` | 随包版本 | 镜像版本（升级包会自动刷新，勿手改） |
| `FCB_API_PORT` | `12345` | 对外端口（App Center 图标链接自动跟随） |
| `FCB_DATA_DIR` | `<卷>/pigeonbox/data` | 数据目录（SQLite+上传文件+JWT 密钥；**备份它=备份全部**） |
| `FCB_ADMIN_PASSWORD` | 空 | 管理员密码（留空=`admin123`；改后停止→启动生效） |
| `FCB_SERVER_BASE_URL` | 空 | 对外完整地址（有域名/HTTPS 反代时填，分享链接会用它） |
| `FCB_USER_ALLOW_REGISTRATION` | `false` | 开放注册（NAS 场景默认关闭，管理员建号） |
| `FCB_JWT_SECRET` | 空 | 留空=数据目录自动生成持久化 |

更多高级项（Redis、存储后端切换、可信代理等）见生态主仓 [ENVIRONMENT_VARIABLES.md](https://github.com/pigeonbox/pigeonbox/blob/main/docs/ENVIRONMENT_VARIABLES.md)；默认即全功能单机模式（免 Redis）。

## 数据与备份

- 全部状态在 `pigeonbox/` 一个目录里：`data/fileCodeBox.db`（SQLite）、上传文件、`.jwt_secret`
- 备份 = Hybrid Backup Sync / File Station 复制该目录（停止应用后拷贝最干净）
- **卸载应用默认保留**该目录；确认不要了在 File Station 手动删除

## 常见问题

- **装完图标点开端口不对**：图标端口在服务启动时自动同步 `.env` 的 `FCB_API_PORT`；刚改完配置重启一次应用即可
- **启动后一会儿显示已停止/页面打不开**：`pigeonbox/pigeonbox.log`（卷根）看 compose 输出；多为镜像未拉全或端口占用
- **取件/上传报权限错误**：数据目录属主需与容器内运行身份一致（uid 1000），SSH 执行
  `chown -R 1000:1000 /share/CACHEDEV1_DATA/pigeonbox/data` 后重启应用

## 开发与构建

共享资产（`compose.yml` / `env.example`）的**真相源在生态主仓 [`deploy/nas/`](https://github.com/pigeonbox/pigeonbox/tree/main/deploy/nas)**：改编排/默认值请改 hub 模板后执行 `bash deploy/nas/sync.sh sync`，**勿直接改本仓这两个文件**——CI 有「与 hub 模板对齐」漂移门禁，模板一动未同步的仓全部变红。跟随 server 新镜像版本走发版列车：hub 仓 `scripts/nas-release-train.sh <镜像tag> --push` 一条命令完成四处钉版+打 tag。
仓库结构：`qpkg/`（qpkg.cfg / package_routines / shared 服务脚本+编排 / icons / arch 占位）+ `scripts/build-qpkg.sh`（QDK 官方 qbuild 组包）。

```sh
# 安装 QDK(Ubuntu/CI 同款)
git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
./scripts/build-qpkg.sh x86_64 0.1.0   # → dist/PigeonBox_0.1.0_x86_64.qpkg(.md5)
shellcheck qpkg/shared/pigeonbox.sh
```

打 `v*` tag 自动：双架构组包 → 挂本仓 Release → 回挂生态主仓 `qnap-v*` Release（需 `QNAP_PAT`，未配置时 CI 放行失败、本地 `gh release upload` 兜底）。

**真机验证状态**：qbuild 组包 + 结构断言过 CI；QTS 真机安装验证待补（欢迎反馈 issue）。

## 参考（格式来源）

- [qnap-dev/QDK](https://github.com/qnap-dev/QDK)（官方打包器：qpkg.cfg 模板 / qinstall.sh / qbuild）
- [qnap-dev/containerized-qpkg](https://github.com/qnap-dev/containerized-qpkg)（官方容器化 QPKG 教学）
- [ivanusto/qpkg-template](https://github.com/ivanusto/qpkg-template)（2026 活跃模板：CS 就绪等待 / setsid 后台启动 / 卸载保数据）
- [ivanusto/roon-qpkg](https://github.com/ivanusto/roon-qpkg)（ghcr 镜像场景的成品先例）

## License

Apache-2.0（与生态一致，见 [LICENSE](./LICENSE)）。
