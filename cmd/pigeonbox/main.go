// Package main 是 PigeonBox 的威联通 QNAP QTS 原生应用(QPKG)入口。
//
// 运行时形态:单进程单端口。本二进制以库调用方式拉起 PigeonBox 全部业务
// (bootstrap.BootstrapWithOptions),同端口经 SPA 回退服务前端静态资源;
// 由 QPKG 服务脚本(pigeonbox.sh)托管:setsid 后台引导 + PID 文件 +
// 看门狗自愈(ping×3 失败重启),配置经 .env → PB_* 环境变量注入。
//
// 与 server 仓部署壳的差异:
//   - JWT 密钥自动生成并持久化到数据目录——NAS 用户不应被迫手工生成密钥
//     (core 安全基线在 production 模式缺强密钥时拒绝启动);
//   - 管理员密码重置在启动前消费 .admin_reset 标记(internal/adminreset,
//     对齐 fnos v1.14.3 语义;QTS 不保证 python3/sqlite3 CLI 故纯 Go 实现)。
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/pigeonbox/core/bootstrap"
	"github.com/pigeonbox/core/pkg/logger"
	"github.com/pigeonbox/qnap/internal/adminreset"
	"github.com/pigeonbox/kit/version"

	"go.uber.org/zap"
)

// ensureJWTSecret 保证 PB_JWT_SECRET 存在:未显式配置时自动生成强密钥,
// 持久化到数据目录(.jwt_secret,权限 0600),重启复用(已签发 token 不失效)。
// 依据:core 的 validateSecrets 在 secret 缺失/弱值时拒绝启动(安全基线)。
// 与 fnos/openwrt 入口同款逻辑,三处需同步演进。
func ensureJWTSecret() {
	if os.Getenv("PB_JWT_SECRET") != "" {
		return
	}
	dataDir := os.Getenv("PB_DATA_PATH")
	if dataDir == "" {
		dataDir = "./data"
	}
	secretPath := filepath.Join(dataDir, ".jwt_secret")
	if b, err := os.ReadFile(secretPath); err == nil {
		if s := strings.TrimSpace(string(b)); len(s) >= 32 {
			_ = os.Setenv("PB_JWT_SECRET", s)
			return
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		// 加密源不可用属系统级故障,直接失败
		_, _ = os.Stderr.WriteString("无法生成 JWT 密钥(crypto/rand 不可用): " + err.Error() + "\n")
		os.Exit(1)
	}
	secret := hex.EncodeToString(raw)
	_ = os.MkdirAll(dataDir, 0o755)
	if err := os.WriteFile(secretPath, []byte(secret), 0o600); err != nil {
		_, _ = os.Stderr.WriteString("无法持久化 JWT 密钥(" + secretPath + "): " + err.Error() + "\n")
		os.Exit(1)
	}
	_ = os.Setenv("PB_JWT_SECRET", secret)
}

// dbPath 解析业务库路径:服务脚本导出的 PB_DATABASE_DB_NAME 优先,
// 缺省回退数据目录约定名(与 core 默认 schema 同名,老库无缝延续)。
func dbPath() string {
	if p := os.Getenv("PB_DATABASE_DB_NAME"); p != "" {
		return p
	}
	dataDir := os.Getenv("PB_DATA_PATH")
	if dataDir == "" {
		dataDir = "./data"
	}
	return filepath.Join(dataDir, "fileCodeBox.db")
}

// consumeAdminReset 消费密码重置请求(尽力而为:任何失败只记 stderr,
// 不阻断启动——重置语义失败时标记保留,下次启动自动重试)。
// PB_APP_HOME 由服务脚本导出(应用目录);缺失时跳过(裸跑/CI 冒烟场景)。
func consumeAdminReset() {
	home := os.Getenv("PB_APP_HOME")
	if home == "" {
		return
	}
	db := dbPath()
	consumed, err := adminreset.Consume(
		db,
		filepath.Join(home, ".admin_reset"),
		filepath.Join(home, ".env"),
		filepath.Join(filepath.Dir(db), ".admin_reset.log"),
		os.Getenv("PB_ADMIN_PASSWORD"),
	)
	if err != nil {
		_, _ = os.Stderr.WriteString("admin reset failed(will retry next start): " + err.Error() + "\n")
		return
	}
	if consumed {
		_, _ = os.Stderr.WriteString("admin reset consumed; admin recreated from PB_ADMIN_PASSWORD on this start\n")
	}
}

func main() {
	// --config 指定 PigeonBox 配置文件路径(透传给 bootstrap)。
	// QPKG 默认纯 env 注入;高级用户可在应用目录自建 config.yaml,
	// 服务脚本检测到后才传本参数(env 优先级始终高于该文件)。
	configPath := flag.String("config", "", "PigeonBox 配置文件路径(默认纯环境变量注入)")
	// --static 前端静态资源目录:存在则以 WithStaticDir 注入 core(同端口服务
	// 内嵌前端 SPA);不存在保持 core 默认(缺目录时优雅降级为纯 API,CI 冒烟即此形态)。
	staticDir := flag.String("static", "www", "前端静态资源目录")
	flag.Parse()

	// 0. 启动前置:密码重置请求消费 + JWT 密钥保证(都必须在 bootstrap 读配置前完成)。
	consumeAdminReset()
	ensureJWTSecret()

	// 1. 以库调用方式拉起 PigeonBox 全部业务,SPA 回退服务前端。
	//    返回的 *server.Hertz 已完成:读配置→初始化logger→建DB→建storage→装路由→装中间件。
	bootOpts := make([]bootstrap.Option, 0, 1)
	if st, err := os.Stat(*staticDir); err == nil && st.IsDir() {
		bootOpts = append(bootOpts, bootstrap.WithStaticDir(*staticDir))
	}
	h, err := bootstrap.BootstrapWithOptions(*configPath, bootOpts...)
	if err != nil {
		// 此时 logger 可能未初始化,fallback 到标准错误输出。
		_, _ = os.Stderr.WriteString("PigeonBox bootstrap 失败: " + err.Error() + "\n")
		os.Exit(1)
	}
	defer bootstrap.Cleanup()

	// 2. 启动 HTTP 服务。
	go func() {
		logger.Info("PigeonBox QNAP 服务启动中...",
			zap.String("version", version.Version),
			zap.String("commit", version.BuildCommit))
		h.Spin()
	}()

	// 3. 优雅退出:服务脚本 stop 发 SIGTERM,给在途请求 5s 排空窗口
	//    (脚本 TERM 等待 10s 后 KILL,窗口留足余量)。
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("正在关闭服务...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.Shutdown(shutdownCtx); err != nil {
		logger.Warn("优雅关闭超时,存在未完成的在途请求", zap.Error(err))
	}
	logger.Info("服务已停止")
}
