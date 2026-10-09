// Package sso 实现 QNAP SSO 免登录(2026-10-09 真实现,QTS 5.2 契约实测)。
//
// 官方模型(QTS 原生 authLogin.cgi):
// 用户登录 QTS 桌面后,浏览器持有会话 cookie NAS_SID(JS 写入,Path=/,
// 不隔离端口——http://nas:12345 的请求同样携带)。应用后端拿该 sid 调本机
// authLogin.cgi?sid= 校验,QTS 返回 authPassed=1 + username/userid/isAdmin。
//
// 与 fnos 网关模式的差异:fnos 的信任锚是网关注入的可信头(须 nonce 防伪造);
// QNAP 无网关注入,信任锚是「QTS 本体对 sid 的实时校验」——伪造 sid 必然
// authPassed=0,不存在可注入的伪造面,故无需 nonce。
//
// 身份映射(镜像 core OIDC 域范式,与 fnos sso 同构):
//   1. 按 qnap:<userid> 精确匹配(users.oidc_sub 外部身份键,前缀隔离值域)
//   2. 未命中 → 以 "qnap-<username>" 去重建号(role=user,无密码)
//   3. 签发本系统 JWT + HttpOnly 会话 Cookie,前端零改动进入登录态
//
// 安全:QTS 管理员(isAdmin)不映射为 PigeonBox 管理员——两套权限语义不同,
// 提权一律走密码登录;sid 仅用于本次校验,不落盘不记日志不回显。
package sso

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/cloudwego/hertz/pkg/route"
	"go.uber.org/zap"
	"gorm.io/gorm"

	usermodel "github.com/pigeonbox/contracts/gen/user"
	"github.com/pigeonbox/core/pkg/auth"
	"github.com/pigeonbox/core/pkg/logger"
	"github.com/pigeonbox/core/pkg/middleware"
	"github.com/pigeonbox/core/repo/db/dao"
	"github.com/pigeonbox/core/repo/db/model"

	"github.com/pigeonbox/qnap/adapter/internal/qnapapi"
)

// SessionCookieName QTS 会话 cookie 名(真机 QTS 5.2 login-m.js setCookie 确认)。
const SessionCookieName = "NAS_SID"

// zapIdentity 日志字段:QTS 身份(不含 sid——会话凭据不进日志)。
func zapIdentity(id qnapapi.Identity) zap.Field {
	return zap.String("qnap_user", id.Username+"#"+id.UID)
}

// Mount 在 QNAP 路由组上挂载 SSO 子路由。client=nil(QTS API 不可用)时端点降级 503。
func Mount(g *route.RouterGroup, client *qnapapi.Client, disabledReason string) {
	g.POST("/login", func(ctx context.Context, c *app.RequestContext) {
		if client == nil {
			c.JSON(consts.StatusServiceUnavailable, map[string]any{
				"code":    503,
				"message": "QNAP 联动不可用:" + disabledReason + ",请使用账号密码登录",
			})
			return
		}

		// 会话凭据来源:浏览器自动携带的 NAS_SID cookie(同 host 不同端口共享);
		// 兼容显式传参(无 cookie 的 API 客户端/未来宿主桥接)。
		sid := string(c.Cookie(SessionCookieName))
		if strings.TrimSpace(sid) == "" {
			var body struct {
				Sid string `json:"sid"`
			}
			if raw, err := c.Body(); err == nil {
				_ = json.Unmarshal(raw, &body)
			}
			sid = body.Sid
		}
		sid = strings.TrimSpace(sid)
		if sid == "" {
			c.JSON(consts.StatusUnauthorized, map[string]any{
				"code":    401,
				"message": "未检测到 QTS 登录态,请先登录 NAS 或使用账号密码登录",
			})
			return
		}

		identity, err := client.CheckSid(ctx, sid)
		if err != nil {
			var authErr *qnapapi.AuthError
			if errors.As(err, &authErr) {
				c.JSON(consts.StatusUnauthorized, map[string]any{
					"code":    401,
					"message": authErr.Reason + ",请重新登录 NAS 或使用账号密码登录",
				})
				return
			}
			logger.Error("QTS 会话校验失败", zap.Error(err))
			c.JSON(consts.StatusBadGateway, map[string]any{
				"code":    502,
				"message": "QTS 会话校验失败:" + err.Error(),
			})
			return
		}

		user, created, err := findOrCreate(ctx, *identity)
		if err != nil {
			logger.Error("SSO 用户映射失败", zapIdentity(*identity), zap.Error(err))
			c.JSON(consts.StatusInternalServerError, map[string]any{
				"code":    500,
				"message": "QNAP 账号映射失败:" + err.Error(),
			})
			return
		}
		if user.Status != "active" {
			c.JSON(consts.StatusForbidden, map[string]any{
				"code":    403,
				"message": "账号已被禁用",
			})
			return
		}

		token, err := auth.GenerateToken(user.ID, user.Username, user.Role)
		if err != nil {
			logger.Error("SSO 签发会话失败", zapIdentity(*identity), zap.Error(err))
			c.JSON(consts.StatusInternalServerError, map[string]any{
				"code":    500,
				"message": "签发会话失败",
			})
			return
		}
		// 与 /user/login 同形态:HttpOnly 会话 Cookie + 响应体 token(兼容 Bearer)。
		middleware.SetSessionCookie(c, token, int(auth.SessionExpiry().Seconds()))
		logger.Info("QNAP SSO 登录成功",
			zapIdentity(*identity),
			zap.Uint("local_uid", user.ID),
			zap.String("local_username", user.Username),
			zap.Bool("created", created))

		c.JSON(consts.StatusOK, &usermodel.LoginResp{
			Code:    200,
			Message: "登录成功",
			Data: &usermodel.LoginData{
				Token: token,
				User: &usermodel.UserData{
					ID:        int64(user.ID),
					Username:  user.Username,
					Email:     user.Email,
					Nickname:  user.Nickname,
					Avatar:    user.Avatar,
					Status:    1,
					CreatedAt: user.CreatedAt.Format("2006-01-02 15:04:05"),
				},
			},
		})
	})
}

// externalSub 外部身份键:复用 users.oidc_sub(外部身份 subject 语义),
// "qnap:" 前缀与真实 OIDC sub 值域隔离,互不冲突。
func externalSub(id qnapapi.Identity) string { return "qnap:" + id.UID }

// findOrCreate 按外部身份查/建本地用户(范式对齐 core OIDC 域 / fnos sso)。
func findOrCreate(ctx context.Context, id qnapapi.Identity) (*model.User, bool, error) {
	repo := dao.NewUserRepository()

	if u, err := repo.GetByOIDCSub(ctx, externalSub(id)); err == nil && u != nil {
		return u, false, nil
	} else if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, false, fmt.Errorf("查询 QNAP 身份绑定失败: %w", err)
	}

	// 建号:用户名去重(本地同名时追加序号)。
	base := "qnap-" + sanitizeUsername(id.Username)
	if base == "qnap-" {
		base = "qnap-uid-" + id.UID
	}
	username := base
	for i := 1; ; i++ {
		_, err := repo.GetByUsername(ctx, username)
		if errors.Is(err, gorm.ErrRecordNotFound) {
			break
		}
		if err != nil {
			return nil, false, fmt.Errorf("查询用户名占用失败: %w", err)
		}
		username = fmt.Sprintf("%s-%d", base, i)
	}

	// 不落密码(users 表允许空):登录唯一入口是 QTS 会话,随机密码徒增泄露面。
	email := fmt.Sprintf("qnap-%s@qnap.local", id.UID)
	user := &model.User{
		Username: username,
		Email:    email,
		Nickname: id.Username,
		Role:     "user",
		Status:   "active",
		OidcSub:  externalSub(id),
	}
	if err := repo.Create(ctx, user); err != nil {
		return nil, false, fmt.Errorf("创建 QNAP 映射用户失败: %w", err)
	}
	return user, true, nil
}

// sanitizeUsername 用户名只保留安全字符(建号落库用),其余折叠为下划线。
func sanitizeUsername(name string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		default:
			return '_'
		}
	}, strings.TrimSpace(name))
}
