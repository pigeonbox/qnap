// Package adminreset 消费管理员密码重置请求(.admin_reset 标记机制)。
//
// 语义对齐 fnos v1.14.3(壳层 python3+sqlite3 实现):标记存在且
// PB_ADMIN_PASSWORD 非空时删除 users 表 admin 行——core 启动语义为
// 「库中无管理员时按 PB_ADMIN_PASSWORD 重建」,故紧随的进程启动即以
// 新密码完成重置。QTS 不保证 python3/sqlite3 CLI,故复用 core 同款
// glebarez 纯 Go sqlite 驱动:blank import 与 core 经 gorm 链到的是
// 同一个包实例,驱动只注册一次,零新增外部依赖。
package adminreset

import (
	"database/sql"
	"fmt"
	"os"
	"regexp"
	"time"

	// 与 core(gorm 经 glebarez/sqlite)链接同一驱动包:driver 名 "sqlite"
	// 在 core 侧已注册,此处显式引用仅为表达直接依赖,不产生二次注册。
	_ "github.com/glebarez/go-sqlite"
)

const adminUser = "admin"

var envPasswordLine = regexp.MustCompile(`(?m)^PB_ADMIN_PASSWORD=.*$`)

// Requested 报告是否存在待消费的重置请求。
func Requested(marker string) bool {
	_, err := os.Stat(marker)
	return err == nil
}

// Consume 消费一次密码重置请求,返回是否已消费。
//
//   - 标记不存在          → (false, nil)
//   - 密码为空            → 保留标记 + 审计日志,待下次启动(不视为错误)
//   - 业务库不存在        → 直接消费(core 首启将按 PB_ADMIN_PASSWORD 播种 admin,重置语义已达成)
//   - 删除 SQL 失败       → 保留标记待下次启动重试,返回错误(调用方记日志,不阻断启动)
//
// 成功:删 admin 行 → 移除标记 → 追加审计日志 → 清除 .env 明文密码。
// 注意只清文件不清环境变量——紧随其后的本次启动仍凭已导出的 env 完成 admin 重建。
func Consume(dbPath, marker, envFile, auditLog, password string) (bool, error) {
	if !Requested(marker) {
		return false, nil
	}
	if password == "" {
		audit(auditLog, "reset requested but PB_ADMIN_PASSWORD empty; keep marker")
		return false, nil
	}
	if _, err := os.Stat(dbPath); err != nil {
		audit(auditLog, "db not found; admin will be seeded from PB_ADMIN_PASSWORD on first start")
		finish(marker, envFile)
		return true, nil
	}
	remaining, err := deleteAdmin(dbPath)
	if err != nil {
		audit(auditLog, "reset SQL failed; keep marker for next start")
		return false, err
	}
	audit(auditLog, fmt.Sprintf("admin deleted (remaining=%d)", remaining))
	finish(marker, envFile)
	return true, nil
}

// deleteAdmin 删除 admin 行并返回删除后的剩余 admin 计数(审计语义与 fnos 对齐:
// remaining>0 意味着库里有异常的多行 admin,需人工关注)。
func deleteAdmin(dbPath string) (int64, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return 0, err
	}
	defer db.Close()
	if _, err := db.Exec("DELETE FROM users WHERE username = ?", adminUser); err != nil {
		return 0, err
	}
	var remaining int64
	err = db.QueryRow("SELECT COUNT(*) FROM users WHERE username = ?", adminUser).Scan(&remaining)
	return remaining, err
}

// finish 移除标记并尽力清除 .env 明文密码(写失败不影响重置结果:
// 密码已删行,本次启动凭 env 重建,残留明文仅在下次人工查看 .env 时可见)。
func finish(marker, envFile string) {
	_ = os.Remove(marker)
	if envFile == "" {
		return
	}
	raw, err := os.ReadFile(envFile)
	if err != nil {
		return
	}
	cleared := envPasswordLine.ReplaceAllLiteralString(string(raw), `PB_ADMIN_PASSWORD=""`)
	if cleared != string(raw) {
		_ = os.WriteFile(envFile, []byte(cleared), 0o600)
	}
}

func audit(logFile, msg string) {
	if logFile == "" {
		return
	}
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format("2006-01-02T15:04:05"), msg)
}
