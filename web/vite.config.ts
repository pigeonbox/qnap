// QNAP(QTS) 内嵌前端构建(QPKG 的 shared/www 产物来源)。
// 结构=壳入口(注入 QTS 宿主适配器)+公共应用 core(tgz 源码形态编译)。
// 与 fnos 仓的 web 目录同构平行(2026-10-09 前端拆仓:平台适配器归各平台仓)。
import { defineConfig } from 'vite'
import { appVersion, coreDir, sharedAlias, sharedPlugins } from './vite.shared'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  root: fileURLToPath(new URL('.', import.meta.url)),
  base: './',
  plugins: sharedPlugins(),
  define: {
    // 版本注入:构建环境 APP_VERSION 优先(打包脚本传 frontend-core 钉版号),
    // 缺省取本包 version——页脚「前端版本」显示的是 web 应用真实版本
    __APP_VERSION__: JSON.stringify(process.env.APP_VERSION || appVersion),
  },
  resolve: {
    alias: sharedAlias,
  },
  // 静态资源(favicon/theme-init)单一真相源=core public
  publicDir: `${coreDir}/public`,
  optimizeDeps: {
    // core 以源码形态参与构建,禁预打包
    exclude: ['@pigeonbox/frontend-core'],
  },
  build: {
    outDir: fileURLToPath(new URL('./dist', import.meta.url)),
    emptyOutDir: true,
  },
})
