// 构建共享片段(别名/插件/define)。core 以 Release 源码 tgz 形态安装
// (@pigeonbox/frontend-core),构建时以源码形态编译(视图/样式/路由全部来自
// core,本仓 web/ 只注入平台适配器与入口)。
import { fileURLToPath } from 'node:url'
import vue from '@vitejs/plugin-vue'
import Components from 'unplugin-vue-components/vite'
import { ElementPlusResolver } from 'unplugin-vue-components/resolvers'
import { readFileSync } from 'node:fs'

/** core 包目录(node_modules 内的 tgz 解包) */
export const coreDir = fileURLToPath(new URL('./node_modules/@pigeonbox/frontend-core', import.meta.url))
export const coreSrc = `${coreDir}/src`

/** 壳构建版本注入首页/仪表盘版本页脚(对齐发布列车) */
export const appVersion = (JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf-8')) as { version: string }).version

export function sharedPlugins() {
  return [
    vue(),
    // Element Plus 按需引入:模板组件自动注册(组件目录=core) + 样式按组件引入
    Components({
      resolvers: [ElementPlusResolver()],
      dts: fileURLToPath(new URL('./src/components.d.ts', import.meta.url)),
      dirs: [`${coreSrc}/components`],
    }),
  ]
}

export const sharedAlias = {
  // 公共应用(core)以 @ 引用——壳内代码用 @shell 区分
  '@': coreSrc,
  '@shell': fileURLToPath(new URL('./src', import.meta.url)),
}

export const sharedDefine = {
  __APP_VERSION__: JSON.stringify(appVersion),
}
