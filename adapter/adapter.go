// Package adapter 装配 QNAP(QTS)深度集成。
//
// 2026-10-09 按 QTS 原生 CGI API 真实现(契约经 QTS 5.2.10 真机实测钉死):
//   SSO 免登录 sso  — NAS_SID 会话 cookie → authLogin.cgi?sid= 校验 →
//                     本地用户映射 + 会话签发(POST /api/qnap/login);
//   系统信息        — sysRequest.cgi get_system_info(GET /api/qnap/system);
//   后端 API client — internal/qnapapi(loopback QTS CGI,会话凭据不出本机)。
//
// 诚实缺席(不造假开关):
//   授权目录  — QTS 5.2 的 File Station 旧面(entry.cgi)已不可用,
//               utilRequest.cgi 语义与官方文档漂移,待官方 API 稳定后接入;
//   通知中心  — QTS 无面向 QPKG 的通知推送公开 API(log_tool 仅系统日志)。
//
// 降级语义:非 QNAP 环境(Docker/裸进程,本机无 QTS)一切自动关闭,
// /api/qnap/capabilities 如实回报;PigeonBox 业务不受任何影响。
package adapter

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/cloudwego/hertz/pkg/route"
	"go.uber.org/zap"

	"github.com/pigeonbox/core/pkg/logger"
	"github.com/pigeonbox/core/pkg/middleware"

	"github.com/pigeonbox/qnap/adapter/internal/qnapapi"
	"github.com/pigeonbox/qnap/adapter/internal/qnapconfig"
	"github.com/pigeonbox/qnap/adapter/sso"
)

// Config 重导出(保持调用方 main.go 接口稳定,定义在 internal/qnapconfig)。
type Config = qnapconfig.Config

// LoadConfig 加载 QNAP 适配配置(带 QTS API 探测;转发至 qnapconfig)。
func LoadConfig() Config {
	return qnapconfig.LoadConfig(func(base string) bool {
		c, err := qnapapi.New(base)
		if err != nil {
			return false
		}
		ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
		defer cancel()
		return c.Probe(ctx)
	})
}

// probeTimeout 单候选基址探测超时(启动期同步执行,候选 5 个须总时长可控)。
const probeTimeout = 3 * time.Second

// Mount 在已启动的 PigeonBox Hertz server 上挂载 QNAP 集成。
func Mount(h *server.Hertz, cfg Config) {
	group := h.Group("/api/qnap")

	// 探测端点:前端据此渲染 QNAP 联动 UI(任何环境都可用,不鉴权)。
	group.GET("/capabilities", func(ctx context.Context, c *app.RequestContext) {
		c.JSON(consts.StatusOK, map[string]any{
			"code": 200,
			"data": map[string]any{
				"sso":      cfg.Enabled,
				"system":   cfg.Enabled,
				"qtsBase":  cfg.QTSBase,
				"disabled": !cfg.Enabled,
				"reason":   cfg.DisabledReason,
			},
		})
	})

	if !cfg.Enabled {
		logger.Warn("QNAP 深度集成未启用(非 QNAP 原生环境):业务全功能,联动关闭",
			zap.String("reason", cfg.DisabledReason))
		// SSO 端点仍挂载(503 降级响应,前端可读到原因文案)
		sso.Mount(group, nil, cfg.DisabledReason)
		return
	}

	client, err := qnapapi.New(cfg.QTSBase)
	if err != nil {
		// isLoopback 把关已在探测前生效,此处属防御性兜底
		logger.Error("QNAP API client 构造失败,联动降级", zap.Error(err))
		sso.Mount(group, nil, err.Error())
		return
	}

	sso.Mount(group, client, "")
	mountSystem(group, client)
	logger.Info("QNAP 深度集成已启用:SSO / 系统信息",
		zap.String("qtsBase", cfg.QTSBase))
}

// systemInfoResp /api/qnap/system 响应。
type systemInfoResp struct {
	ModelName       string `json:"modelName"`
	FirmwareVersion string `json:"firmwareVersion"`
	Hostname        string `json:"hostname"`
}

// mountSystem 系统信息端点(需登录:含 hostname,不进匿名面)。
// sid 与 SSO 登录同机制:浏览器对同 host 请求自动携带 NAS_SID cookie,
// 后端转交 QTS 校验后查询;API 客户端可显式传 X-QNAP-Sid 头。
func mountSystem(g *route.RouterGroup, client *qnapapi.Client) {
	g.GET("/system", middleware.UserOrAPIKey(), func(ctx context.Context, c *app.RequestContext) {
		sid := strings.TrimSpace(string(c.Cookie(sso.SessionCookieName)))
		if sid == "" {
			sid = strings.TrimSpace(string(c.GetHeader("X-QNAP-Sid")))
		}
		if sid == "" {
			c.JSON(consts.StatusUnauthorized, map[string]any{
				"code":    401,
				"message": "缺少 QTS 会话凭据(NAS_SID)",
			})
			return
		}
		info, err := client.SystemInfo(ctx, sid)
		if err != nil {
			var authErr *qnapapi.AuthError
			if errors.As(err, &authErr) {
				c.JSON(consts.StatusUnauthorized, map[string]any{
					"code":    401,
					"message": authErr.Reason,
				})
				return
			}
			logger.Warn("查询 QTS 系统信息失败", zap.Error(err))
			c.JSON(consts.StatusBadGateway, map[string]any{
				"code":    502,
				"message": "查询系统信息失败:" + err.Error(),
			})
			return
		}
		c.JSON(consts.StatusOK, map[string]any{
			"code": 200,
			"data": systemInfoResp{
				ModelName:       info.ModelName,
				FirmwareVersion: info.FirmwareVer,
				Hostname:        info.Hostname,
			},
		})
	})
}
