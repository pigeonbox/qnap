package adminreset

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	_ "github.com/glebarez/go-sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ── 管理员口令**原地**重置（fnos#182 同源修复，2026-11-04）─────────────
//
// 旧行为：平台层直接 DELETE users 表 admin 行，core 启动时按 PB_ADMIN_PASSWORD
// 重建 ⇒ admin 的 **user id 变化** ⇒ 名下 file_codes / user_api_keys 全部成孤儿。
//
// 新行为：平台层**彻底不碰数据库**，只把新口令一次性投递给 core
// （PB_ADMIN_PASSWORD_RESET_FILE）⇒ core **原地**改 bcrypt 哈希 ⇒ user id 不变。

// newDB 建带 users 表的真实 sqlite 库(core 同款表名/列名),返回库路径。
func newDB(t *testing.T, admins, users int) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fileCodeBox.db")
	db, err := sql.Open("sqlite", path)
	require.NoError(t, err)
	defer db.Close()
	_, err = db.Exec(`CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL)`)
	require.NoError(t, err)
	for i := 0; i < admins; i++ {
		_, err = db.Exec(`INSERT INTO users (username) VALUES (?)`, "admin")
		require.NoError(t, err)
	}
	for i := 0; i < users; i++ {
		_, err = db.Exec(`INSERT INTO users (username) VALUES (?)`, "user"+string(rune('a'+i)))
		require.NoError(t, err)
	}
	return path
}

func adminCount(t *testing.T, dbPath string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	require.NoError(t, err)
	defer db.Close()
	var n int
	require.NoError(t, db.QueryRow(`SELECT COUNT(*) FROM users WHERE username = 'admin'`).Scan(&n))
	return n
}

func allUsers(t *testing.T, dbPath string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	require.NoError(t, err)
	defer db.Close()
	var n int
	require.NoError(t, db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n))
	return n
}

// prepare 场景封装:写入 marker/.env,跑 Prepare,返回(是否投递, 错误)。
func prepare(t *testing.T, dir, dataDir, password string) (bool, error) {
	t.Helper()
	marker := filepath.Join(dir, ".admin_reset")
	envFile := filepath.Join(dir, ".env")
	return Prepare(marker, dataDir, envFile, filepath.Join(dataDir, ".admin_reset.log"), password)
}

func TestPrepare_KeepsAdminRowAndStagesPassword(t *testing.T) {
	dir := t.TempDir()
	dataDir := filepath.Join(dir, "data")
	require.NoError(t, os.MkdirAll(dataDir, 0o755))
	db := newDB(t, 1, 2)
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".admin_reset"), nil, 0o600))
	// .env 里是**旧**口令（平台凭据与 admin 口令可能不同步 ⇒ 由 Prepare 对齐）
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".env"),
		[]byte("PB_SERVER_PORT=12345\nPB_ADMIN_PASSWORD=\"old-pw\"\n"), 0o600))

	staged, err := prepare(t, dir, dataDir, "new-pw")
	require.NoError(t, err)
	require.True(t, staged, "有标记且口令非空 ⇒ 必须投递重置")

	// ① admin 行必须还在（原地改哈希，不是删号重建）
	assert.Equal(t, 1, adminCount(t, db), "不得删 admin 行（否则名下分享/Key 成孤儿）")
	assert.Equal(t, 3, allUsers(t, db), "普通用户也不受影响")

	// ② 一次性重置文件已投递（core 原地改哈希的载体）
	rf := filepath.Join(dataDir, ".admin_password_reset")
	raw, err := os.ReadFile(rf)
	require.NoError(t, err)
	assert.Equal(t, "new-pw", string(raw), "重置文件内容 = 提交的新口令")
	info, err := os.Stat(rf)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm(), "重置文件必须 0600")

	// ③ core 的取件路径已导出（core 启动时据此消费）
	assert.Equal(t, rf, os.Getenv(EnvAdminPasswordResetFile))

	// ④ 标记已消费
	_, statErr := os.Stat(filepath.Join(dir, ".admin_reset"))
	assert.True(t, os.IsNotExist(statErr), "标记应被移除")

	// ⑤ .env 里的明文口令必须与 admin 口令一致（prewire 自愈要靠它重新登录）
	envRaw, err := os.ReadFile(filepath.Join(dir, ".env"))
	require.NoError(t, err)
	assert.Contains(t, string(envRaw), `PB_ADMIN_PASSWORD="new-pw"`,
		"平台凭据必须与新口令对齐（否则 prewire 重建 Key 时用旧口令登录失败）")
	assert.NotContains(t, string(envRaw), `PB_ADMIN_PASSWORD=""`)
	assert.Contains(t, string(envRaw), "PB_SERVER_PORT=12345", "其余行逐字保留")

	// ⑥ 审计日志落盘
	logRaw, err := os.ReadFile(filepath.Join(dataDir, ".admin_reset.log"))
	require.NoError(t, err)
	assert.Contains(t, string(logRaw), "staged")
}

func TestPrepareNoMarker(t *testing.T) {
	dir := t.TempDir()
	dataDir := filepath.Join(dir, "data")
	require.NoError(t, os.MkdirAll(dataDir, 0o755))
	db := newDB(t, 1, 1)
	t.Setenv(EnvAdminPasswordResetFile, "")

	staged, err := prepare(t, dir, dataDir, "secret-pw-123")
	require.NoError(t, err)
	assert.False(t, staged)
	assert.Equal(t, 1, adminCount(t, db), "无标记不得动库")
	assert.Empty(t, os.Getenv(EnvAdminPasswordResetFile), "无待处理重置时不得导出路径")
}

func TestPrepareEmptyPasswordKeepsMarker(t *testing.T) {
	dir := t.TempDir()
	dataDir := filepath.Join(dir, "data")
	require.NoError(t, os.MkdirAll(dataDir, 0o755))
	db := newDB(t, 1, 0)
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".admin_reset"), nil, 0o600))

	staged, err := prepare(t, dir, dataDir, "")
	require.NoError(t, err, "空密码不视为错误,仅保留标记待下次启动")
	assert.False(t, staged)
	assert.Equal(t, 1, adminCount(t, db))

	_, statErr := os.Stat(filepath.Join(dir, ".admin_reset"))
	assert.NoError(t, statErr, "标记保留")

	logRaw, _ := os.ReadFile(filepath.Join(dataDir, ".admin_reset.log"))
	assert.Contains(t, string(logRaw), "PB_ADMIN_PASSWORD empty")
}

// 上一次启动没起来（投递了但 core 没消费）⇒ 下次启动仍须能应用。
func TestPrepare_ArmsExistingResetFile(t *testing.T) {
	dir := t.TempDir()
	dataDir := filepath.Join(dir, "data")
	require.NoError(t, os.MkdirAll(dataDir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dataDir, ".admin_password_reset"),
		[]byte("pending-pw"), 0o600))
	t.Setenv(EnvAdminPasswordResetFile, "")

	staged, err := prepare(t, dir, dataDir, "")
	require.NoError(t, err)
	assert.False(t, staged, "没有标记就没有新投递")
	assert.Equal(t, filepath.Join(dataDir, ".admin_password_reset"),
		os.Getenv(EnvAdminPasswordResetFile),
		"已存在的待消费重置文件必须被导出（上次没启动成功的补投）")
}

// 投递失败（数据目录不可用）⇒ 保留标记待下次启动重试。
func TestPrepare_StagingFailureKeepsMarker(t *testing.T) {
	dir := t.TempDir()
	// 数据目录路径被一个**普通文件**占住 ⇒ mkdir 必然失败
	blocked := filepath.Join(dir, "data")
	require.NoError(t, os.WriteFile(blocked, []byte("not a dir"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".admin_reset"), nil, 0o600))

	staged, err := prepare(t, dir, blocked, "pw")
	require.Error(t, err, "投递失败必须报错")
	assert.False(t, staged)

	_, statErr := os.Stat(filepath.Join(dir, ".admin_reset"))
	assert.NoError(t, statErr, "标记保留待下次启动重试")
}

func TestRequested(t *testing.T) {
	dir := t.TempDir()
	marker := filepath.Join(dir, ".admin_reset")
	assert.False(t, Requested(marker))
	require.NoError(t, os.WriteFile(marker, nil, 0o600))
	assert.True(t, Requested(marker))
}
