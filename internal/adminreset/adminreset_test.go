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

// consume 场景封装:写入 marker/.env,跑 Consume,返回(是否消费, 错误)。
func consume(t *testing.T, dir, dbPath, password string) (bool, error) {
	t.Helper()
	marker := filepath.Join(dir, ".admin_reset")
	envFile := filepath.Join(dir, ".env")
	auditLog := filepath.Join(filepath.Dir(dbPath), ".admin_reset.log")
	return Consume(dbPath, marker, envFile, auditLog, password)
}

func TestConsumeNoMarker(t *testing.T) {
	dir := t.TempDir()
	db := newDB(t, 1, 1)
	consumed, err := consume(t, dir, db, "secret-pw-123")
	require.NoError(t, err)
	assert.False(t, consumed)
	assert.Equal(t, 1, adminCount(t, db), "无标记不得动库")
}

func TestConsumeDeletesAdminOnly(t *testing.T) {
	dir := t.TempDir()
	db := newDB(t, 1, 2)
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".admin_reset"), nil, 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".env"), []byte("PB_SERVER_PORT=12345\nPB_ADMIN_PASSWORD=\"old-pw\"\n"), 0o600))

	consumed, err := consume(t, dir, db, "new-pw-456")
	require.NoError(t, err)
	assert.True(t, consumed)
	assert.Equal(t, 0, adminCount(t, db), "admin 行应被删除")
	assert.Equal(t, 2, allUsers(t, db), "普通用户不受影响")

	_, statErr := os.Stat(filepath.Join(dir, ".admin_reset"))
	assert.True(t, os.IsNotExist(statErr), "标记应被移除")

	// 审计日志落盘
	logRaw, err := os.ReadFile(filepath.Join(filepath.Dir(db), ".admin_reset.log"))
	require.NoError(t, err)
	assert.Contains(t, string(logRaw), "admin deleted (remaining=0)")

	// .env 明文密码清除,其余行保留
	envRaw, err := os.ReadFile(filepath.Join(dir, ".env"))
	require.NoError(t, err)
	assert.Contains(t, string(envRaw), `PB_ADMIN_PASSWORD=""`)
	assert.Contains(t, string(envRaw), "PB_SERVER_PORT=12345")
	assert.NotContains(t, string(envRaw), "old-pw")
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

func TestConsumeEmptyPasswordKeepsMarker(t *testing.T) {
	dir := t.TempDir()
	db := newDB(t, 1, 0)
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".admin_reset"), nil, 0o600))

	consumed, err := consume(t, dir, db, "")
	require.NoError(t, err, "空密码不视为错误,仅保留标记待下次启动")
	assert.False(t, consumed)
	assert.Equal(t, 1, adminCount(t, db))

	_, statErr := os.Stat(filepath.Join(dir, ".admin_reset"))
	assert.NoError(t, statErr, "标记保留")

	logRaw, _ := os.ReadFile(filepath.Join(filepath.Dir(db), ".admin_reset.log"))
	assert.Contains(t, string(logRaw), "PB_ADMIN_PASSWORD empty")
}

func TestConsumeMissingDBConsumesAsSeed(t *testing.T) {
	dir := t.TempDir()
	missingDB := filepath.Join(dir, "data", "fileCodeBox.db") // 不存在
	require.NoError(t, os.MkdirAll(filepath.Dir(missingDB), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".admin_reset"), nil, 0o600))

	consumed, err := consume(t, dir, missingDB, "seed-pw-789")
	require.NoError(t, err)
	assert.True(t, consumed, "库不存在=首启播种场景,直接消费")

	logRaw, err := os.ReadFile(filepath.Join(dir, "data", ".admin_reset.log"))
	require.NoError(t, err)
	assert.Contains(t, string(logRaw), "seeded from PB_ADMIN_PASSWORD")
}

func TestConsumeMissingDBKeepsMarkerOnSQLError(t *testing.T) {
	dir := t.TempDir()
	// 非 sqlite 文件冒充业务库 → SQL 失败 → 保留标记待重试
	bad := filepath.Join(dir, "fileCodeBox.db")
	require.NoError(t, os.WriteFile(bad, []byte("this is not a database"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".admin_reset"), nil, 0o600))

	consumed, err := consume(t, dir, bad, "pw")
	assert.Error(t, err, "坏库应报错")
	assert.False(t, consumed, "SQL 失败保留标记")

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
