package adapter

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/ut"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	fclogger "github.com/pigeonbox/core/pkg/logger"

	"github.com/pigeonbox/qnap/adapter/internal/qnapconfig"
)

// TestMain 初始化最小 logger,避免 Mount 内 logger 输出在全局变量为 nil 时 panic。
func TestMain(m *testing.M) {
	_ = fclogger.Init(&fclogger.Config{Level: "error"})
	os.Exit(m.Run())
}

// newTestEngine 建一个空 Hertz + 探针路由,挂载指定 cfg 的 adapter。
func newTestEngine(t *testing.T, cfg Config) *server.Hertz {
	t.Helper()
	h := server.Default()
	h.GET("/api/v1/ping", func(ctx context.Context, c *app.RequestContext) {
		c.JSON(consts.StatusOK, map[string]string{"msg": "pong"})
	})
	Mount(h, cfg)
	return h
}

// qtsStub 模拟 QTS authLogin.cgi(探测命中 + sid 校验)。
func qtsStub(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/cgi-bin/authLogin.cgi", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/xml")
		if r.URL.Query().Get("sid") == "good" {
			_, _ = fmt.Fprint(w,
				`<?xml version="1.0"?><QDocRoot version="1.0"><authPassed><![CDATA[1]]></authPassed>`+
					`<username><![CDATA[alice]]></username><userid><![CDATA[1002]]></userid>`+
					`<isAdmin><![CDATA[0]]></isAdmin></QDocRoot>`)
			return
		}
		if r.URL.Query().Get("sid") != "" {
			_, _ = fmt.Fprint(w, `<QDocRoot version="1.0"><authPassed><![CDATA[0]]></authPassed></QDocRoot>`)
			return
		}
		_, _ = fmt.Fprint(w, `<?xml version="1.0"?><QDocRoot version="1.0"><doQuick><![CDATA[]]></doQuick></QDocRoot>`)
	})
	mux.HandleFunc("/cgi-bin/sys/sysRequest.cgi", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/xml")
		_, _ = fmt.Fprint(w,
			`<?xml version="1.0"?><QDocRoot version="1.0"><model><modelName><![CDATA[TS-X53D]]></modelName></model>`+
				`<firmware><version><![CDATA[5.2.1]]></version></firmware><hostname><![CDATA[D643]]></hostname></QDocRoot>`)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// TestCapabilitiesEnabled 联动可用:capabilities 如实回报 sso/system。
func TestCapabilitiesEnabled(t *testing.T) {
	srv := qtsStub(t)
	h := newTestEngine(t, Config{Enabled: true, QTSBase: srv.URL})

	w := ut.PerformRequest(h.Engine, consts.MethodGet, "/api/qnap/capabilities", nil)
	require.Equal(t, consts.StatusOK, w.Code)
	body := w.Body.String()
	assert.Contains(t, body, `"sso":true`)
	assert.Contains(t, body, `"system":true`)
	assert.Contains(t, body, `"disabled":false`)
}

// TestCapabilitiesDisabled 降级:如实回报原因,不造假开关。
func TestCapabilitiesDisabled(t *testing.T) {
	h := newTestEngine(t, Config{Enabled: false, DisabledReason: "未探测到本机 QTS API"})

	w := ut.PerformRequest(h.Engine, consts.MethodGet, "/api/qnap/capabilities", nil)
	require.Equal(t, consts.StatusOK, w.Code)
	body := w.Body.String()
	assert.Contains(t, body, `"sso":false`)
	assert.Contains(t, body, `"disabled":true`)
	assert.Contains(t, body, "未探测到本机 QTS API")
}

// TestDisabledDoesNotAffectBusiness 降级不影响业务路由。
func TestDisabledDoesNotAffectBusiness(t *testing.T) {
	h := newTestEngine(t, Config{Enabled: false, DisabledReason: "x"})

	w := ut.PerformRequest(h.Engine, consts.MethodGet, "/api/v1/ping", nil)
	require.Equal(t, consts.StatusOK, w.Code)
	assert.Contains(t, w.Body.String(), "pong")
}

// TestLoadConfigProbeAgainstStub 探测器全链路:stub QTS 命中。
func TestLoadConfigProbeAgainstStub(t *testing.T) {
	srv := qtsStub(t)
	t.Setenv("PB_QNAP_QTS_BASE", srv.URL)
	t.Setenv("PB_QNAP_DISABLED", "")

	cfg := LoadConfig()
	require.True(t, cfg.Enabled)
	assert.Equal(t, srv.URL, cfg.QTSBase)
}

// TestSystemRequiresSid system 端点缺 QTS 会话 401(不进匿名面)。
func TestSystemRequiresSid(t *testing.T) {
	srv := qtsStub(t)
	h := newTestEngine(t, Config{Enabled: true, QTSBase: srv.URL})

	// 未登录(PigeonBox 会话)→ 401;带 sid 但未登录同样被鉴权拦下
	w := ut.PerformRequest(h.Engine, consts.MethodGet, "/api/qnap/system",
		nil, []ut.Header{{Key: "X-QNAP-Sid", Value: "good"}}...)
	assert.Equal(t, consts.StatusUnauthorized, w.Code)
}

// TestLoginEndpointAlive SSO 端点挂载在启用态也响应(无效 sid 401 而非 404)。
func TestLoginEndpointAlive(t *testing.T) {
	srv := qtsStub(t)
	h := newTestEngine(t, Config{Enabled: true, QTSBase: srv.URL})

	w := ut.PerformRequest(h.Engine, consts.MethodPost, "/api/qnap/login",
		nil,
		[]ut.Header{{Key: "Content-Type", Value: "application/json"}, {Key: "Cookie", Value: "NAS_SID=forged"}}...)
	assert.Equal(t, consts.StatusUnauthorized, w.Code)
}

var _ = qnapconfig.Config{} // 保持 qnapconfig 引用(重导出类型一致性)
