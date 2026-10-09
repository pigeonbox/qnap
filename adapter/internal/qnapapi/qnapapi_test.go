package qnapapi

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// qtsStub 按真机实测 XML 形态模拟 QTS CGI 面。
func qtsStub(t *testing.T, loginXML, sidXML, sysXML string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/cgi-bin/authLogin.cgi", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/xml")
		q := r.URL.Query()
		switch {
		case q.Get("sid") != "":
			_, _ = fmt.Fprint(w, sidXML)
		case q.Get("user") != "":
			_, _ = fmt.Fprint(w, loginXML)
		default:
			_, _ = fmt.Fprint(w, `<?xml version="1.0"?><QDocRoot version="1.0"><doQuick><![CDATA[]]></doQuick></QDocRoot>`)
		}
	})
	mux.HandleFunc("/cgi-bin/sys/sysRequest.cgi", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/xml")
		_, _ = fmt.Fprint(w, sysXML)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

const loginOK = `<?xml version="1.0" encoding="UTF-8" ?>
<QDocRoot version="1.0">
<authPassed><![CDATA[1]]></authPassed><authSid><![CDATA[maha9ylc]]></authSid>
<isAdmin><![CDATA[1]]></isAdmin><username><![CDATA[zhangyi]]></username>
<userid><![CDATA[1000]]></userid></QDocRoot>`

const loginBad = `<?xml version="1.0" encoding="UTF-8" ?>
<QDocRoot version="1.0">
<authPassed><![CDATA[0]]></authPassed><errorValue><![CDATA[-1]]></errorValue>
<username><![CDATA[]]></username></QDocRoot>`

const sidOK = `<?xml version="1.0" encoding="UTF-8" ?>
<QDocRoot version="1.0">
<authPassed><![CDATA[1]]></authPassed><isAdmin><![CDATA[0]]></isAdmin>
<user><![CDATA[alice]]></user><username><![CDATA[alice]]></username>
<groupname><![CDATA[everyone]]></groupname><userid><![CDATA[1002]]></userid>
<userType><![CDATA[local]]></userType><modelName><![CDATA[TS-X53D]]></modelName></QDocRoot>`

const sidBad = `<?xml version="1.0" encoding="UTF-8" ?>
<QDocRoot version="1.0"><authPassed><![CDATA[0]]></authPassed></QDocRoot>`

const sysOK = `<?xml version="1.0" encoding="UTF-8" ?>
<QDocRoot version="1.0">
<model><modelName><![CDATA[TS-X53D]]></modelName></model>
<firmware><version><![CDATA[5.2.1]]></version></firmware>
<hostname><![CDATA[D643]]></hostname></QDocRoot>`

// toLoopback httptest 监听 127.0.0.1,天然满足 isLoopback。
func TestLogin(t *testing.T) {
	srv := qtsStub(t, loginOK, sidBad, sysOK)
	c, err := New(srv.URL)
	require.NoError(t, err)

	id, err := c.Login(context.Background(), "zhangyi", "zx19950124")
	require.NoError(t, err)
	assert.Equal(t, "zhangyi", id.Username)
	assert.Equal(t, "1000", id.UID)
	assert.True(t, id.IsAdmin)
	assert.Equal(t, "maha9ylc", id.Sid)
}

func TestLoginBadCredential(t *testing.T) {
	srv := qtsStub(t, loginBad, sidBad, sysOK)
	c, err := New(srv.URL)
	require.NoError(t, err)

	_, err = c.Login(context.Background(), "zhangyi", "wrong")
	var authErr *AuthError
	require.ErrorAs(t, err, &authErr)
}

func TestCheckSid(t *testing.T) {
	srv := qtsStub(t, loginOK, sidOK, sysOK)
	c, err := New(srv.URL)
	require.NoError(t, err)

	id, err := c.CheckSid(context.Background(), "valid-sid")
	require.NoError(t, err)
	assert.Equal(t, "alice", id.Username)
	assert.Equal(t, "1002", id.UID)
	assert.False(t, id.IsAdmin)

	_, err = c.CheckSid(context.Background(), "valid-sid")
	require.NoError(t, err)
}

func TestCheckSidInvalid(t *testing.T) {
	srv := qtsStub(t, loginOK, sidBad, sysOK)
	c, err := New(srv.URL)
	require.NoError(t, err)

	_, err = c.CheckSid(context.Background(), "bogus")
	var authErr *AuthError
	require.ErrorAs(t, err, &authErr)

	_, err = c.CheckSid(context.Background(), "  ")
	require.ErrorAs(t, err, &authErr)
}

func TestCheckSidNoUID(t *testing.T) {
	// authPassed=1 但缺 userid:拒绝(外部身份键不可空)
	srv := qtsStub(t, loginOK,
		`<QDocRoot version="1.0"><authPassed><![CDATA[1]]></authPassed><username><![CDATA[x]]></username></QDocRoot>`,
		sysOK)
	c, err := New(srv.URL)
	require.NoError(t, err)

	_, err = c.CheckSid(context.Background(), "sid")
	var authErr *AuthError
	require.ErrorAs(t, err, &authErr)
}

func TestSystemInfo(t *testing.T) {
	srv := qtsStub(t, loginOK, sidOK, sysOK)
	c, err := New(srv.URL)
	require.NoError(t, err)

	info, err := c.SystemInfo(context.Background(), "sid")
	require.NoError(t, err)
	assert.Equal(t, "TS-X53D", info.ModelName)
	assert.Equal(t, "5.2.1", info.FirmwareVer)
	assert.Equal(t, "D643", info.Hostname)
}

func TestProbe(t *testing.T) {
	srv := qtsStub(t, loginOK, sidOK, sysOK)
	c, err := New(srv.URL)
	require.NoError(t, err)
	assert.True(t, c.Probe(context.Background()))

	// 非 QTS 面(返回 HTML)不命中
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = fmt.Fprint(w, "<html><body>hello</body></html>")
	}))
	t.Cleanup(other.Close)
	c2, err := New(other.URL)
	require.NoError(t, err)
	assert.False(t, c2.Probe(context.Background()))
}

// TestRejectNonLoopback 会话凭据不得外发:非 loopback 地址拒绝构造 client。
func TestRejectNonLoopback(t *testing.T) {
	for _, raw := range []string{
		"https://qnap.example.com:5001",
		"http://10.44.129.215:5001",
		"https://evil.example.com",
	} {
		_, err := New(raw)
		require.Error(t, err, raw)
		assert.Contains(t, err.Error(), "loopback", raw)
	}
	// loopback 变体放行
	for _, raw := range []string{
		"http://127.0.0.1:80",
		"https://127.0.0.1:5001",
		"http://localhost:8080",
		"http://[::1]:5001",
	} {
		_, err := New(raw)
		require.NoError(t, err, raw)
	}
}

// TestRedirectStaysLoopback http:80 的 302 跟随时目标也必须 loopback。
func TestRedirectStaysLoopback(t *testing.T) {
	final := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = fmt.Fprint(w, `<QDocRoot><authPassed><![CDATA[1]]></authPassed></QDocRoot>`)
	}))
	t.Cleanup(final.Close)

	redir := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, final.URL+"/cgi-bin/authLogin.cgi?sid=x", http.StatusFound)
	}))
	t.Cleanup(redir.Close)

	c, err := New(redir.URL)
	require.NoError(t, err)
	// 跟随后最终命中 stub(两者均 loopback)
	assert.True(t, c.Probe(context.Background()))
}

func TestLoginPwdIsBase64(t *testing.T) {
	// 真机契约:pwd=base64(utf8(password)),即 ezEncode(utf16to8(pwd))
	var gotPwd string
	mux := http.NewServeMux()
	mux.HandleFunc("/cgi-bin/authLogin.cgi", func(w http.ResponseWriter, r *http.Request) {
		gotPwd = r.URL.Query().Get("pwd")
		_, _ = fmt.Fprint(w, loginOK)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	c, err := New(srv.URL)
	require.NoError(t, err)
	_, err = c.Login(context.Background(), "u", "p@ss w0rd")
	require.NoError(t, err)
	assert.Equal(t, "cEBzcyB3MHJk", gotPwd)
	assert.False(t, strings.Contains(gotPwd, "p@ss"))
}
