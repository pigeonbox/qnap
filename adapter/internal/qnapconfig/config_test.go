package qnapconfig

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestLoadConfigProbeHit 探测命中首个候选即启用。
func TestLoadConfigProbeHit(t *testing.T) {
	t.Setenv("PB_QNAP_QTS_BASE", "")
	t.Setenv("PB_QNAP_DISABLED", "")

	var probed []string
	cfg := LoadConfig(func(base string) bool {
		probed = append(probed, base)
		return base == DefaultQTSBaseCandidates[1]
	})
	assert.True(t, cfg.Enabled)
	assert.Equal(t, DefaultQTSBaseCandidates[1], cfg.QTSBase)
	assert.Equal(t, DefaultQTSBaseCandidates[:2], probed)
	assert.Empty(t, cfg.DisabledReason)
}

// TestLoadConfigProbeMiss 全部候选不可达 → 降级并带原因。
func TestLoadConfigProbeMiss(t *testing.T) {
	t.Setenv("PB_QNAP_QTS_BASE", "")
	t.Setenv("PB_QNAP_DISABLED", "")

	cfg := LoadConfig(func(base string) bool { return false })
	assert.False(t, cfg.Enabled)
	assert.NotEmpty(t, cfg.DisabledReason)
}

// TestLoadConfigExplicitBase 显式指定:跳过探测候选,失败如实降级。
func TestLoadConfigExplicitBase(t *testing.T) {
	t.Setenv("PB_QNAP_DISABLED", "")
	t.Setenv("PB_QNAP_QTS_BASE", "https://127.0.0.1:5001/")

	var probed []string
	cfg := LoadConfig(func(base string) bool {
		probed = append(probed, base)
		return true
	})
	assert.True(t, cfg.Enabled)
	// 尾斜杠剥离
	assert.Equal(t, "https://127.0.0.1:5001", cfg.QTSBase)
	assert.Equal(t, []string{"https://127.0.0.1:5001"}, probed)

	cfg = LoadConfig(func(base string) bool { return false })
	assert.False(t, cfg.Enabled)
	assert.Contains(t, cfg.DisabledReason, "PB_QNAP_QTS_BASE")
}

// TestLoadConfigDisabled 强制关闭开关。
func TestLoadConfigDisabled(t *testing.T) {
	t.Setenv("PB_QNAP_DISABLED", "1")

	cfg := LoadConfig(func(base string) bool {
		t.Fatal("强制关闭时不应探测")
		return false
	})
	assert.False(t, cfg.Enabled)
	assert.Contains(t, cfg.DisabledReason, "PB_QNAP_DISABLED")
}

// TestLoadConfigNilProbe 无探测器(纯配置读取场景)不 panic。
func TestLoadConfigNilProbe(t *testing.T) {
	t.Setenv("PB_QNAP_QTS_BASE", "")
	t.Setenv("PB_QNAP_DISABLED", "")

	cfg := LoadConfig(nil)
	assert.False(t, cfg.Enabled)
	assert.NotEmpty(t, cfg.DisabledReason)
}
