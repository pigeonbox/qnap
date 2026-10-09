// QNAP(QTS)宿主适配器——qnap 仓 web/ 的平台实现(2026-10-09 前端拆仓:
// 平台适配器归各平台仓,与 fnos 仓 web/ 同构平行)。
//
// 接入模型(QTS 原生 API,契约经 QTS 5.2.10 真机实测):
//   - SSO 免登录:浏览器对同 host(:12345)请求自动携带 QTS 会话 cookie NAS_SID,
//     后端 /api/qnap/login 转交本机 authLogin.cgi 校验签发本系统会话;
//     伪造/过期 sid 在 QTS 侧即被拒(authPassed=0),无注入伪造面
//   - 后端能力探测:/api/qnap/capabilities(qnap 适配层,任何环境可探测)
//   - 非本平台部署(裸跑/Docker):探测失败,全部方法静默——能力按默认关闭上报
//
// 与 fnos 适配器的差异:QNAP 无宿主 JS SDK/iframe 桥接(应用开在独立浏览器
// 窗口),故 fileActions/appSettings/主题语言跟随等宿主桥接能力诚实缺席。
import type { HostAdapter, HostCapabilities, HostDirItem, HostFollowHandlers } from '@/host'
import type { user as userContract } from '@pigeonbox/contracts'
import { request } from '@/utils/request'

// ---- 后端能力探测(一次缓存) ----

interface QnapCapabilities {
  sso: boolean
  system: boolean
  qtsBase: string
  disabled: boolean
  reason: string
}

let capsPromise: Promise<QnapCapabilities | null> | null = null

function getQnapCapabilities(force = false): Promise<QnapCapabilities | null> {
  if (force || !capsPromise) {
    capsPromise = request<{ code: number; data: QnapCapabilities }>({
      url: '/api/qnap/capabilities',
      method: 'GET',
      timeout: 5000,
    })
      .then(
        (res: { code: number; data: QnapCapabilities } | null) =>
          res && res.code === 200 ? res.data : null
      )
      .catch(() => null)
  }
  return capsPromise
}

// ---- 适配器 ----

const capabilities: HostCapabilities = {
  sso: false,
  sharedDirs: false,
  fileActions: false,
  appSettings: false,
}

export const qnapHostAdapter: HostAdapter = {
  name: '威联通',
  capabilities,

  async init() {
    const caps = await getQnapCapabilities(true)
    Object.assign(capabilities, {
      sso: !!caps?.sso,
      // QTS 5.2 无可用的授权目录/文件动作/应用设置公开 API(诚实缺席)
      sharedDirs: false,
      fileActions: false,
      appSettings: false,
    } satisfies HostCapabilities)
  },

  // QNAP 无主题/语言跟随 API(独立浏览器窗口,无宿主桥接)
  initFollow(_handlers: HostFollowHandlers): Promise<void> {
    return Promise.resolve()
  },

  // 无宿主窗口标题桥接
  setTitle(_title: string): Promise<void> {
    return Promise.resolve()
  },

  async ssoLogin(): Promise<userContract.UserData | null> {
    const caps = await getQnapCapabilities()
    if (!caps?.sso) return null
    try {
      // NAS_SID cookie 浏览器自动携带(同 host 不同端口共享 cookie);
      // 后端转交本机 QTS authLogin.cgi 实时校验,失败 401 → null(密码登录兜底)
      const res = await request<{
        code: number
        message: string
        data: { token: string; user: userContract.UserData }
      }>({
        url: '/api/qnap/login',
        method: 'POST',
        timeout: 8000,
      })
      return res.code === 200 ? res.data.user : null
    } catch {
      return null
    }
  },

  listAuthorizedDirs(): Promise<HostDirItem[] | null> {
    return Promise.resolve(null)
  },

  pickAuthorizedDir(): Promise<string[] | null> {
    return Promise.resolve(null)
  },

  openFile(_path: string): Promise<boolean> {
    return Promise.resolve(false)
  },

  openDir(_path: string): Promise<boolean> {
    return Promise.resolve(false)
  },

  showFileDetails(_paths: string[]): Promise<boolean> {
    return Promise.resolve(false)
  },

  openAppSettings(): Promise<boolean> {
    return Promise.resolve(false)
  },

  openExternal(url: string, target = '_blank'): Promise<boolean> {
    try {
      window.open(url, target)
      return Promise.resolve(true)
    } catch {
      return Promise.resolve(false)
    }
  },
}
