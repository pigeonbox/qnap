.PHONY: build test vet frontend native qpkg clean

# PigeonBox 威联通 QTS 原生应用(QPKG)
# 独立构建钉 go.mod 正式版本;在 hub 工作区内直接跑会拾取上层 go.work 联编本地
# core,GOWORK=off 强制钉版构建,两者皆可——见 README「本地开发」。

build:            ## 编译本机二进制(联调用;打包产物走 native 双架构)
	go build -o bin/pigeonbox ./cmd/pigeonbox

test:             ## Go 单测 + 服务脚本/安装钩子 mock 冒烟
	go test ./... -race
	./tests/run-tests.sh

vet:
	go vet ./...

frontend:         ## 构建前端 dist(优先工作区 frontend 仓)→ qpkg/shared/www
	./scripts/build-native.sh

native:           ## 双架构静态二进制 + 前端 → qpkg/(组包前置)
	./scripts/build-native.sh

qpkg:             ## 组装 QPKG(双架构;需 QDK: github.com/qnap-dev/QDK,先跑 make native)
	./scripts/build-qpkg.sh x86_64 "$$(cat VERSION)"
	./scripts/build-qpkg.sh arm_64 "$$(cat VERSION)"

clean:
	rm -rf bin/ dist/ build/ qpkg/x86_64/bin/ qpkg/arm_64/bin/ qpkg/shared/www/
