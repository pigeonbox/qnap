// Package qnapconfig 定义 QNAP 适配层的配置类型与加载逻辑。
//
// 独立为子包以打破循环依赖:adapter 父包与 sso 等子模块都引用本包的 Config,
// 而本包不依赖任何 adapter 子包,从而无环(范式对齐 fnos/adapter/internal/fnosconfig)。
//
// 2026-10-09 真机契约( QTS 5.2.10 实测,详见 internal/qnapapi ):
//   - QTS 原生 CGI 面在 Web 服务端口(真机 5001/https, 80 会 302 到 8081);
//   - SSO 信任锚 = authLogin.cgi 会话校验(伪造 sid 必然 authPassed=0),
//     无需 fnos 式网关 nonce——校验由 QTS 本体完成,不存在可注入的可信头;
//   - 启用探测 = loopback QTS API 可达(authLogin.cgi 返回 QDocRoot XML)。
package qnapconfig

import (
	"os"
	"strings"
)

// DefaultQTSBaseCandidates QTS Web API 基址探测顺序(loopback 优先)。
// 真机实测:https:5001 直达;http:80 会 302 到 https:8081(client 自动跟随);
// 8080 在 QTS 5.2 未监听。用户改过 Web 端口时用 PB_QNAP_QTS_BASE 显式指定。
var DefaultQTSBaseCandidates = []string{
	"https://127.0.0.1:5001",
	"http://127.0.0.1:80",
	"https://127.0.0.1:8081",
	"https://127.0.0.1:443",
	"http://127.0.0.1:8080",
}

// Config 是 QNAP 适配层的配置。
type Config struct {
	// Enabled QTS 原生 API 可达(探测命中或显式指定成功)。非 QNAP 环境
	// (Docker/裸进程,本机无 QTS)为 false,一切联动降级、业务不受影响。
	Enabled bool
	// QTSBase QTS Web API 基址(如 https://127.0.0.1:5001),用于 authLogin.cgi 等。
	QTSBase string
	// DisabledReason 降级原因(供日志与 /api/qnap/capabilities 输出)。
	DisabledReason string
}

// LoadConfig 从运行环境加载 QNAP 适配配置。
//
// 环境变量:
//   - PB_QNAP_QTS_BASE  QTS Web API 基址覆盖(如 https://127.0.0.1:5001);
//     显式指定时跳过探测,探测失败如实降级。
//   - PB_QNAP_DISABLED  非空 = 强制关闭联动(排障用)。
//
// 探测是同步阻塞的,仅发生在启动期一次;候选基址各自带短超时。
func LoadConfig(probe func(baseURL string) bool) Config {
	cfg := Config{}

	if os.Getenv("PB_QNAP_DISABLED") != "" {
		cfg.DisabledReason = "PB_QNAP_DISABLED 已设置:QNAP 联动强制关闭"
		return cfg
	}

	if base := strings.TrimSpace(os.Getenv("PB_QNAP_QTS_BASE")); base != "" {
		cfg.QTSBase = strings.TrimRight(base, "/")
		if probe != nil && probe(cfg.QTSBase) {
			cfg.Enabled = true
		} else {
			cfg.DisabledReason = "PB_QNAP_QTS_BASE 指定的 QTS API 不可达(" + cfg.QTSBase + "):QNAP 联动关闭"
		}
		return cfg
	}

	for _, base := range DefaultQTSBaseCandidates {
		if probe != nil && probe(base) {
			cfg.Enabled = true
			cfg.QTSBase = base
			return cfg
		}
	}
	cfg.DisabledReason = "未探测到本机 QTS API(非 QNAP 环境):QNAP 联动关闭,业务全功能"
	return cfg
}
