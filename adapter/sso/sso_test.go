package sso

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/ut"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	coredb "github.com/pigeonbox/core/repo/db"
	"github.com/pigeonbox/core/repo/db/model"

	"github.com/pigeonbox/qnap/adapter/internal/qnapapi"
)

// newTestDB 注入内存 sqlite(与 fnos sso 测试同语义)并迁移 users 表。
func newTestDB(t *testing.T) {
	t.Helper()
	gormDB, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	require.NoError(t, err)
	require.NoError(t, gormDB.AutoMigrate(&model.User{}))
	coredb.SetDatabaseInstance(gormDB)
	t.Cleanup(func() { coredb.SetDatabaseInstance(nil) })
}

// newQTSStub 模拟 QTS authLogin.cgi?sids 校验。
func newQTSStub(t *testing.T, valid map[string]string) *qnapapi.Client {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/cgi-bin/authLogin.cgi", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/xml")
		sid := r.URL.Query().Get("sid")
		if uid, ok := valid[sid]; ok {
			_, _ = fmt.Fprintf(w,
				`<?xml version="1.0"?><QDocRoot version="1.0"><authPassed><![CDATA[1]]></authPassed>`+
					`<username><![CDATA[%s]]></username><userid><![CDATA[%s]]></userid>`+
					`<isAdmin><![CDATA[0]]></isAdmin></QDocRoot>`, "alice", uid)
			return
		}
		_, _ = fmt.Fprint(w, `<?xml version="1.0"?><QDocRoot version="1.0"><authPassed><![CDATA[0]]></authPassed></QDocRoot>`)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	c, err := qnapapi.New(srv.URL)
	require.NoError(t, err)
	return c
}

func newEngine(t *testing.T, client *qnapapi.Client) *server.Hertz {
	t.Helper()
	h := server.Default()
	Mount(h.Group("/api/qnap"), client, "")
	return h
}

// TestLoginWithCookie 携带 NAS_SID cookie(浏览器自动带)成功登录并映射建号。
func TestLoginWithCookie(t *testing.T) {
	newTestDB(t)
	client := newQTSStub(t, map[string]string{"good-sid": "1002"})
	h := newEngine(t, client)

	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
		nil,
		[]ut.Header{{Key: "Content-Type", Value: "application/json"}, {Key: "Cookie", Value: "NAS_SID=good-sid"}}...)
	require.Equal(t, consts.StatusOK, w.Code)

	var resp struct {
		Code int `json:"code"`
		Data struct {
			Token string          `json:"token"`
			User  json.RawMessage `json:"user"`
		} `json:"data"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	assert.Equal(t, 200, resp.Code)
	assert.NotEmpty(t, resp.Data.Token)

	// 落库形态:oidc_sub 前缀隔离 + 无密码
	var user model.User
	require.NoError(t, coredb.GetDB().Where("oidc_sub = ?", "qnap:1002").First(&user).Error)
	assert.Equal(t, "qnap-alice", user.Username)
	assert.Equal(t, "user", user.Role)
	assert.Empty(t, user.PasswordHash)
}

// TestLoginSidInBody 无 cookie 时支持 body 显式传 sid(API 客户端)。
func TestLoginSidInBody(t *testing.T) {
	newTestDB(t)
	client := newQTSStub(t, map[string]string{"good-sid": "1002"})
	h := newEngine(t, client)

	body, _ := json.Marshal(map[string]string{"sid": "good-sid"})
	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
		bodyReader(body),
		[]ut.Header{{Key: "Content-Type", Value: "application/json"}}...)
	require.Equal(t, consts.StatusOK, w.Code)
}

// TestLoginNoSid 缺凭据 401。
func TestLoginNoSid(t *testing.T) {
	newTestDB(t)
	h := newEngine(t, newQTSStub(t, nil))

	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
		nil,
		[]ut.Header{{Key: "Content-Type", Value: "application/json"}}...)
	require.Equal(t, consts.StatusUnauthorized, w.Code)
}

// TestLoginInvalidSid 伪造/过期 sid 401(信任锚=QTS 实时校验)。
func TestLoginInvalidSid(t *testing.T) {
	newTestDB(t)
	h := newEngine(t, newQTSStub(t, map[string]string{"good-sid": "1002"}))

	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
		nil,
		[]ut.Header{{Key: "Content-Type", Value: "application/json"}, {Key: "Cookie", Value: "NAS_SID=forged"}}...)
	require.Equal(t, consts.StatusUnauthorized, w.Code)
}

// TestLoginDisabled QTS API 不可用时 503 且文案可读。
func TestLoginDisabled(t *testing.T) {
	newTestDB(t)
	h := server.Default()
	Mount(h.Group("/api/qnap"), nil, "未探测到本机 QTS API")

	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
		nil,
		[]ut.Header{{Key: "Content-Type", Value: "application/json"}, {Key: "Cookie", Value: "NAS_SID=x"}}...)
	require.Equal(t, consts.StatusServiceUnavailable, w.Code)
	assert.Contains(t, w.Body.String(), "QNAP")
}

// TestLoginRebind 同一 QTS 身份重复登录复用同一本地用户(不重复建号)。
func TestLoginRebind(t *testing.T) {
	newTestDB(t)
	client := newQTSStub(t, map[string]string{"s1": "1002", "s2": "1002"})
	h := newEngine(t, client)

	for _, sid := range []string{"s1", "s2"} {
		w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
			nil,
			[]ut.Header{{Key: "Content-Type", Value: "application/json"}, {Key: "Cookie", Value: "NAS_SID=" + sid}}...)
		require.Equal(t, consts.StatusOK, w.Code)
	}
	var count int64
	require.NoError(t, coredb.GetDB().Model(&model.User{}).Where("oidc_sub = ?", "qnap:1002").Count(&count).Error)
	assert.Equal(t, int64(1), count)
}

// TestUsernameSanitize 用户名消毒 + 本地同名去重。
func TestUsernameSanitize(t *testing.T) {
	newTestDB(t)
	// 预占 qnap-alice
	require.NoError(t, coredb.GetDB().Create(&model.User{
		Username: "qnap-alice", Email: "a@b.c", Role: "user", Status: "active",
	}).Error)

	client := newQTSStub(t, map[string]string{"s": "1002"})
	h := newEngine(t, client)
	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
		nil,
		[]ut.Header{{Key: "Content-Type", Value: "application/json"}, {Key: "Cookie", Value: "NAS_SID=s"}}...)
	require.Equal(t, consts.StatusOK, w.Code)

	var user model.User
	require.NoError(t, coredb.GetDB().Where("oidc_sub = ?", "qnap:1002").First(&user).Error)
	assert.Equal(t, "qnap-alice-1", user.Username)
}

// bodyReader 把请求体字节转 io.Reader(ut.PerformRequest 的 body 参数)。
func bodyReader(b []byte) *ut.Body { return &ut.Body{Body: bytes.NewReader(b), Len: len(b)} }
