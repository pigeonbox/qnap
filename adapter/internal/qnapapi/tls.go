package qnapapi

import "crypto/tls"

// tlsSkipVerifyLoopback QTS Web 默认自签证书(真机 https:5001 实测)。
// 仅当目标已通过 isLoopback 把关时才可用 New 构造 client,故跳过证书校验
// 不扩大信任面(loopback 链路无 MITM 位置);重定向后目标同样逐跳校验 loopback。
func tlsSkipVerifyLoopback() *tls.Config {
	return &tls.Config{InsecureSkipVerify: true} // #nosec G402 — 仅 loopback 自签 QTS
}
