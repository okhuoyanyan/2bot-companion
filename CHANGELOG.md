# 2BOT 伴侣端 (`2bot-companion`) 版本更新日志

本文档记录 2BOT 官方 Android 专属轻量伴侣端的所有重要版本迭代与更新细节。

## [v1.3.1] - 2026-09-12

### 📶 突破 Android 12+ / TargetSdk 35 脱敏限制，实现真实 WiFi SSID 毫秒级捕获

- **Kotlin 底层引入 `FLAG_INCLUDE_LOCATION_INFO` 网络监听器**：
  - 针对 TargetSdk 35（Android 15）及 Android 12+ 对同步查询 `getNetworkCapabilities()` 与 `getConnectionInfo()` 的硬脱敏（默认强制返回 `<unknown ssid>`）机制，全面重构底层网络感知架构；
  - 挂载官方 `ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO)` 监听器，并在应用启动与前台活跃时主动探测，系统底层放行未脱敏的真实 WiFi SSID；
  - 建立原子级内存缓存，一旦网络连通即刻解析并持久驻留，彻底根治国内各厂商定制系统下 SSID 被掩盖置空的问题。
- **重构 Flutter 层网络感知通道**：
  - 彻底移除对 `Permission.location.isGranted` 的过度防御拦截，避免 Android 11+“仅在使用中允许”权限被 Flutter 误判为未授权的问题；
  - 强化双轨兜底逻辑：若原生监听捕获到有效 SSID，无条件同步校正 WiFi 连接状态，杜绝界面与服务端状态断层。

---

## [v1.3.0] - 2026-09-12

### 📍 GPS 经纬度感知与双轨 WiFi SSID 突破

- **纯原生 GPS 与基站经纬度感知**：
  - 基于 Android 官方原生 `LocationManager` 机制，在应用进入前台活跃（`onResume`）时动态挂载低功耗 `LocationListener`；
  - 动态调度 `GPS_PROVIDER`、`NETWORK_PROVIDER` 与 `PASSIVE_PROVIDER`，综合提取最优位置快照；
  - 标准上报模型拓展 `location` 对象，包含：`latitude`（纬度）、`longitude`（经度）、`accuracy`（精度米数）、`altitude`（海拔）、`speed`（速度）、`bearing`（方位角）、`provider`（来源）与时间戳。
- **双轨原生 WiFi SSID 强力兜底**：
  - 攻克小米 HyperOS、华为 HarmonyOS 等国内定制 ROM 对第三方 Flutter 插件的沙盒权限限制；
  - 新增 Kotlin 底层原生直采双通道：优先通过 Android 10+ `ConnectivityManager.getNetworkCapabilities().transportInfo` 读取，向下兼容通过 `WifiManager.connectionInfo` 提取；
  - 自动剥离外层引号与 `<unknown ssid>` 异常标识；若 Flutter 插件层采集结果为空，无感触发原生双轨兜底。
- **实时感知看板全新升级**：
  - 实时感知看板新增 **GPS 定位坐标**展示胶囊条，直观呈现坐标（保留 6 位小数）、定位来源标签与误差精度（如 `±15m`）；
  - 优化权限引导文案，明确提示获取 GPS 与 WiFi SSID 均依赖位置权限。
- **一致性签名继承**：
  - 沿用官方专属 Release Keystore，支持直接覆盖安装，无须卸载旧版。

---

## [v1.2.0] - 2026-09-11

### ⏱️ 亮屏使用时长感知、保活指引与异常预警加固

- **今日屏幕使用总时长感知**：
  - 引入 Android `UsageStatsManager` 原生接口，统计今日累计前台亮屏分钟数，辅助 2BOT 掌握用户日间作息与活跃状态；
  - 增加使用情况访问权限（Usage Access Settings）一键直达系统授权引导。
- **低电量关怀预警**：
  - 增加设备电池电量监测横幅：当手机电量 ≤ 20% 且未插电时，看板以醒目红色警告提示及时补电，防止伴侣端因断电失联。
- **国产主流 ROM 后台防杀保活指引**：
  - 内置主流国产定制系统专属后台保活弹窗指南：覆盖小米 (HyperOS/MIUI)、华为 (HarmonyOS)、OPPO (ColorOS)、vivo (OriginOS) 四大品牌自启动、省电策略与多任务锁定的图文配置指引。
- **权限与环境健康度自检**：
  - 新增通知权限（Android 13+ 前台常驻必需）与系统电池优化白名单检测提示条，一键直达系统加白。
- **稳定性修复**：
  - 修复 `DeviceTelemetry` 内部 `batteryLevel` 与 `isCharging` getter 封装，保证数据管道零空指针异常。

---

## [v1.1.0] - 2026-09-11

### 🚶 深度原生感知与起居生命体征升级

- **健康计步传感器对接**：
  - 对接 Android 原生硬件计步器（`Sensor.TYPE_STEP_COUNTER`），每日零点自动差值清零，精准统计并上报今日累计步数；
  - 新增 Android 10+ 健身运动活动识别权限（`ACTIVITY_RECOGNITION`）动态申请支持。
- **音频与外设连接感知**：
  - 实时监测手机系统媒体音乐播放状态（`isMusicActive`）；
  - 智能感知音频输出设备：区分识别扬声器、3.5mm/Type-C 有线耳机以及蓝牙 A2DP/BLE 耳机连接状态。
- **起居与闹钟智能同步**：
  - 通过 `AlarmManager.nextAlarmClock` 感知系统下一个闹钟触发时间，智能格式化输出（如“明天 07:30”），为 2BOT 提供早起与就寝状态推断依据。
- **免打扰与响铃模式识别**：
  - 实时读取系统响铃模式（正常、振动、静音）及 DND 免打扰状态，避免在用户休息时误触打扰。
- **官方统一专属发布签名**：
  - 引入专属持久化 Release Keystore 证书，确保后续所有发布版本签名 100% 一致，永久解决安装签名冲突问题。

---

## [v1.0.0] - 2026-09-11

### 📱 创世首发：纯血开源、超低功耗设备感知客户端

- **官方专属 Android 伴侣端首发**：
  - 为 2BOT-NEW 双智能体管家系统量身打造的超轻量设备端感知客户端。
- **纯血开源、极致省电**：
  - 0 商业广告、0 商业追踪 SDK、0 冗余依赖；整包仅约 25MB，后台常驻占用极低内存。
- **双驱动即时与保底上报**：
  - 充放电插拔状态即时监听触发；
  - 网络连通（WiFi / 蜂窝网络）切换即时监听触发；
  - 前台常驻通知保活服务支持自定义定时周期保底上报。
- **端到端隐私中继**：
  - 直连用户私有部署的 Vercel 中继网关，采用 Bearer Token 安全认证，数据全程加密，绝不流经任何公有三方服务器。
- **CI/CD 自动化流水线**：
  - 配置基于 GitHub Actions 的自动化编译与 GitHub Release 持续交付流水线。
