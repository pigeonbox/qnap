// PigeonBox 前端壳(QNAP/QTS flavor)入口:注入平台适配器 → 拉起公共应用(core)。
import { installHost } from '@/host'
import { qnapHostAdapter } from './host/impl/qnap'

installHost(qnapHostAdapter)
// 动态导入:保证适配器(含异步能力探测的启动)先装配,core main 再执行——
// core main 是副作用模块(创建 app/pinia/router/i18n 并挂载)
void import('@/main')
