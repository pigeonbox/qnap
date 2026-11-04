// Package adminreset 消费管理员口令重置请求(.admin_reset 标记机制)。
//
// 2026-11-04（fnos#182 同源修复）：**不再删 users 表 admin 行**。
//
//	旧语义:删 admin 行 → core 启动时按 PB_ADMIN_PASSWORD 重建
//	  ⇒ admin 的 **user id 变化** ⇒ 名下 file_codes / user_api_keys 全部成孤儿
//	  （真机 88 份分享 + 3 把 Key;过程无任何告警,只有数据悄悄失去归属）。
//	新语义:平台层**彻底不碰数据库**,只把新口令一次性投递给 core
//	  （PB_ADMIN_PASSWORD_RESET_FILE）⇒ core **原地**改 bcrypt 哈希
//	  ⇒ user id 不变 ⇒ 名下数据归属不变;旧 API Key 继续有效;旧 JWT 失效。
//
// 附带修掉的次生缺陷:旧实现在消费标记后把 .env 里的明文口令**清空**
// ⇒ prewire_beam_box 的「每次启动校验有效性、失效才重建」只剩第一次生效。
// ⇒ 现在 .env 里的口令与 admin 口令保持**一致**（且绝不被清空）。
//
// QTS 不保证 python3/sqlite3 CLI —— 新实现**连数据库都不碰**（零驱动依赖）。
package adminreset

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	// EnvAdminPasswordResetFile core 侧消费一次性重置文件的环境变量名。
	// 与 core bootstrap.EnvAdminPasswordResetFile 同名（core 是消费方）。
	EnvAdminPasswordResetFile = "PB_ADMIN_PASSWORD_RESET_FILE"
	// resetFileName 数据目录下的一次性重置文件名（core 消费后即删除）。
	resetFileName = ".admin_password_reset"
)

var envPasswordLine = regexp.MustCompile(`(?m)^PB_ADMIN_PASSWORD=.*$`)

// Requested 报告是否存在待消费的重置请求。
func Requested(marker string) bool {
	_, err := os.Stat(marker)
	return err == nil
}

// Prepare 消费一次密码重置请求:把新口令**原地**投递给 core。
//
// 参数:
//
//	marker    待消费的重置标记（PB_APP_HOME/.admin_reset）
//	dataDir   数据目录（PB_DATA_PATH）——一次性重置文件落这里
//	envFile   .env（平台凭据文件）——口令对齐到新值
//	auditLog  审计日志路径
//	password  新的管理员口令（来自 PB_ADMIN_PASSWORD）
//
// 返回（是否**投递了**重置, 错误）。
//
// 语义:
//   - 标记不存在        → (false, nil);但若已有待消费的重置文件,仍导出路径
//     （「上次启动没成功」的补投:文件由 core 消费后删除,天然一次性）。
//   - 口令为空          → 保留标记 + 审计日志,待下次启动（不视为错误）。
//   - 投递失败          → 保留标记待下次启动重试,返回错误（调用方记日志,不阻断启动）。
//   - 投递成功          → 移除标记 → 写审计日志 → 把 .env 口令对齐到新值。
func Prepare(marker, dataDir, envFile, auditLog, password string) (bool, error) {
	staged := false
	if Requested(marker) {
		if password == "" {
			audit(auditLog, "reset requested but PB_ADMIN_PASSWORD empty; keep marker")
			return false, nil
		}
		if err := stageResetFile(dataDir, password); err != nil {
			audit(auditLog, "reset staging failed: "+err.Error())
			return false, err // 保留标记 ⇒ 下次启动重试
		}
		if err := os.Remove(marker); err != nil && !os.IsNotExist(err) {
			audit(auditLog, "reset staged but marker removal failed: "+err.Error())
		}
		audit(auditLog, "admin password reset staged (core applies it in place on startup; user id preserved)")
		syncEnvPassword(envFile, password)
		staged = true
	}
	// 已有待消费的重置文件（本次没投递）⇒ 导出路径给 core。
	if file := filepath.Join(dataDir, resetFileName); fileExists(file) {
		_ = os.Setenv(EnvAdminPasswordResetFile, file)
	}
	return staged, nil
}

// stageResetFile 把新口令写进一次性文件（0600,原子写）。
// 原子写（临时文件 + rename）⇒ core 不会读到半截口令。
func stageResetFile(dataDir, password string) error {
	if strings.TrimSpace(dataDir) == "" {
		return fmt.Errorf("data dir is empty")
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return err
	}
	file := filepath.Join(dataDir, resetFileName)
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, []byte(password), 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, file); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// syncEnvPassword 把 .env 里的明文口令对齐到新口令（best-effort,失败不阻断）。
//
// 为什么需要:.env 是平台凭据文件,prewire_beam_box 的「Key 失效后重建」要用它
// 重新登录（/admin/login）⇒ 口令过期 ⇒ 重建失败 ⇒ 自愈失效。
// ⇒ 重置后把 .env 里的口令同步成新口令,保持平台凭据与 admin 口令一致。
//
// ⚠️ **绝不清空**（旧实现在消费标记后把口令清成空串 ⇒ prewire 自愈只剩第一次,
// 正是 fnos#182 记的次生缺陷）。
func syncEnvPassword(envFile, password string) {
	if envFile == "" || password == "" {
		return
	}
	raw, err := os.ReadFile(envFile)
	if err != nil {
		return
	}
	updated := envPasswordLine.ReplaceAllLiteralString(string(raw),
		`PB_ADMIN_PASSWORD="`+escapeEnvValue(password)+"\"")
	if updated == string(raw) {
		return
	}
	_ = os.WriteFile(envFile, []byte(updated), 0o600)
}

// escapeEnvValue 转义 .env 双引号值里的特殊字符（与 fnos 侧 quote() 同口径）。
func escapeEnvValue(v string) string {
	v = strings.ReplaceAll(v, `\`, `\\`)
	v = strings.ReplaceAll(v, `"`, `\"`)
	v = strings.ReplaceAll(v, `$`, `\$`)
	return v
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
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
