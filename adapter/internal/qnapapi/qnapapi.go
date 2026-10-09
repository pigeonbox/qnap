// Package qnapapi 是 QNAP QTS 原生 CGI API 的统一 client。
//
// 真机契约(QTS 5.2.10 实测钉死,2026-10-09):
//
//	登录: GET {base}/cgi-bin/authLogin.cgi?user={u}&pwd={base64(utf8(pass))}
//	  → XML QDocRoot: authPassed(0/1), authSid, isAdmin(0/1), username, SUID,
//	    errorValue(-1=凭据错误)。pwd 是 ezEncode(utf16to8(pwd))——
//	    QTS 5.2 的 ezEncode 即标准 base64(真机 ezEncodeChars 确认)。
//
//	会话校验(SSO 信任锚): GET {base}/cgi-bin/authLogin.cgi?sid={sid}
//	  → XML QDocRoot: authPassed(0/1), isAdmin, user, username, groupname,
//	    userid, userType, modelName … 伪造/过期 sid 必然 authPassed=0。
//
//	系统信息: GET {base}/cgi-bin/sys/sysRequest.cgi?func=get_system_info&sid={sid}
//	  → XML QDocRoot: model.modelName / firmware.version / hostname …
//
// 安全边界:sid 是用户 QTS 会话凭据,只发往 loopback QTS API,不落盘、不记日志、
// 不回显前端。非 loopback 的 base 地址一律拒绝(防配置错误把会话凭据外发)。
package qnapapi

import (
	"context"
	"encoding/base64"
	"encoding/xml"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Client QTS 原生 CGI API client。
type Client struct {
	baseURL string
	http    *http.Client
}

// New 创建 client。baseURL 形如 https://127.0.0.1:5001。
// QTS Web 常为自签证书,仅对 loopback 目标跳过 TLS 校验(isLoopback 已把关)。
func New(baseURL string) (*Client, error) {
	if !isLoopback(baseURL) {
		return nil, fmt.Errorf("qnapapi: 拒绝非 loopback 的 QTS API 地址 %q(会话凭据不得外发)", baseURL)
	}
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		http: &http.Client{
			Timeout: 5 * time.Second,
			Transport: &http.Transport{
				DialContext:         (&net.Dialer{Timeout: 2 * time.Second}).DialContext,
				TLSHandshakeTimeout: 2 * time.Second,
				TLSClientConfig:     tlsSkipVerifyLoopback(),
			},
			// authLogin.cgi 302(http:80 → https:8081)属正常引导,允许跟随
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 3 {
					return fmt.Errorf("qnapapi: 重定向过多")
				}
				// 重定向目标同样必须留在 loopback
				if !isLoopback(req.URL.String()) {
					return fmt.Errorf("qnapapi: 重定向出 loopback 拒绝: %s", req.URL)
				}
				return nil
			},
		},
	}, nil
}

// isLoopback 判定 URL 主机是否 loopback(127.0.0.0/8, ::1, localhost)。
func isLoopback(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	host := u.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// Identity QTS 会话身份(登录/校验共用)。
type Identity struct {
	Username string
	UID      string // QTS userid(本地用户 uid;SSO 外部身份键)
	IsAdmin  bool
	Sid      string // 会话凭据(仅内存持有,不落盘不记日志)
}

// authResp authLogin.cgi XML 响应的字段子集(真机实测字段名)。
type authResp struct {
	XMLName    xml.Name `xml:"QDocRoot"`
	AuthPassed string   `xml:"authPassed"`
	AuthSid    string   `xml:"authSid"`
	IsAdmin    string   `xml:"isAdmin"`
	Username   string   `xml:"username"`
	User       string   `xml:"user"`
	UserID     string   `xml:"userid"`
	UserType   string   `xml:"userType"`
	ErrorValue string   `xml:"errorValue"`
}

func (r *authResp) passed() bool { return r.AuthPassed == "1" }

// Probe 探测 QTS API 可达:GET authLogin.cgi(无参),返回 QDocRoot XML 即命中。
// 真机无参调用同样返回 XML(doQuick/is_booting/boot 状态段),不需认证。
func (c *Client) Probe(ctx context.Context) bool {
	body, err := c.get(ctx, "/cgi-bin/authLogin.cgi", nil)
	if err != nil {
		return false
	}
	return strings.Contains(body, "<QDocRoot")
}

// Login 用户名密码登录(非 SSO 场景的备用通道;SSO 走 CheckSid)。
// pwd 编码=base64(utf8(password)),即 QTS 5.2 ezEncode(utf16to8(pwd))。
func (c *Client) Login(ctx context.Context, username, password string) (*Identity, error) {
	q := url.Values{}
	q.Set("user", username)
	q.Set("pwd", base64.StdEncoding.EncodeToString([]byte(password)))
	body, err := c.get(ctx, "/cgi-bin/authLogin.cgi", q)
	if err != nil {
		return nil, err
	}
	var resp authResp
	if err := xml.Unmarshal([]byte(body), &resp); err != nil {
		return nil, fmt.Errorf("qnapapi login: 响应解析失败: %w", err)
	}
	if !resp.passed() {
		return nil, &AuthError{Reason: "QTS 账号或密码错误"}
	}
	return &Identity{
		Username: firstNonEmpty(resp.Username, resp.User),
		UID:      resp.UserID,
		IsAdmin:  resp.IsAdmin == "1",
		Sid:      resp.AuthSid,
	}, nil
}

// CheckSid 会话校验(SSO 信任锚):sid 有效 → 身份;无效/过期 → *AuthError。
func (c *Client) CheckSid(ctx context.Context, sid string) (*Identity, error) {
	if strings.TrimSpace(sid) == "" {
		return nil, &AuthError{Reason: "缺少 QTS 会话凭据"}
	}
	q := url.Values{}
	q.Set("sid", sid)
	body, err := c.get(ctx, "/cgi-bin/authLogin.cgi", q)
	if err != nil {
		return nil, err
	}
	var resp authResp
	if err := xml.Unmarshal([]byte(body), &resp); err != nil {
		return nil, fmt.Errorf("qnapapi check_sid: 响应解析失败: %w", err)
	}
	if !resp.passed() {
		return nil, &AuthError{Reason: "QTS 会话无效或已过期"}
	}
	uid := resp.UserID
	if uid == "" {
		return nil, &AuthError{Reason: "QTS 会话缺少用户标识"}
	}
	return &Identity{
		Username: firstNonEmpty(resp.Username, resp.User),
		UID:      uid,
		IsAdmin:  resp.IsAdmin == "1",
		Sid:      sid,
	}, nil
}

// SystemInfo 系统信息(型号/固件版本),用于 /api/qnap/system 展示宿主环境。
type SystemInfo struct {
	ModelName    string `json:"modelName"`
	FirmwareVer  string `json:"firmwareVersion"`
	Hostname     string `json:"hostname"`
}

type sysResp struct {
	XMLName  xml.Name `xml:"QDocRoot"`
	Model    struct {
		ModelName string `xml:"modelName"`
	} `xml:"model"`
	Firmware struct {
		Version string `xml:"version"`
	} `xml:"firmware"`
	Hostname string `xml:"hostname"`
}

// SystemInfo 查询 QTS 系统信息(需要有效 sid)。
func (c *Client) SystemInfo(ctx context.Context, sid string) (*SystemInfo, error) {
	q := url.Values{}
	q.Set("func", "get_system_info")
	q.Set("sid", sid)
	body, err := c.get(ctx, "/cgi-bin/sys/sysRequest.cgi", q)
	if err != nil {
		return nil, err
	}
	var resp sysResp
	if err := xml.Unmarshal([]byte(body), &resp); err != nil {
		return nil, fmt.Errorf("qnapapi system_info: 响应解析失败: %w", err)
	}
	return &SystemInfo{
		ModelName:   resp.Model.ModelName,
		FirmwareVer: resp.Firmware.Version,
		Hostname:    resp.Hostname,
	}, nil
}

// AuthError 认证类失败(凭据错/会话过期),与网络/XML 故障区分——
// 调用方对 AuthError 走 401 语义,其余走 5xx。
type AuthError struct {
	Reason string
}

func (e *AuthError) Error() string { return "qnapapi: " + e.Reason }

// get 统一请求入口(仅 GET,CGI 参数走 query)。响应体上限 1MB(防御异常响应)。
func (c *Client) get(ctx context.Context, path string, q url.Values) (string, error) {
	u := c.baseURL + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", fmt.Errorf("qnapapi: 构造请求失败: %w", err)
	}
	// 阻断 QTS 前端 JS 的 Referer/XSRF 防护误伤(部分 CGI 校验来源)
	req.Header.Set("Referer", c.baseURL+"/")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("qnapapi: 请求失败: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("qnapapi: 读取响应失败: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("qnapapi: HTTP %d", resp.StatusCode)
	}
	return string(body), nil
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
