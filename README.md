# 📱 2BOT Companion (2BOT 官方 Flutter 伴侣端)

[![Flutter](https://img.shields.io/badge/Flutter-3.29+-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?style=for-the-badge&logo=dart&logoColor=white)](https://dart.dev)
[![Android](https://img.shields.io/badge/Platform-Android_21+-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://android.com)
[![CI/CD](https://img.shields.io/badge/CI%2FCD-GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white)](https://github.com/okhuoyanyan/2bot-companion/actions)
[![License](https://img.shields.io/badge/License-MIT-emerald?style=for-the-badge)](LICENSE)

> 🚀 **100% 纯血开源 • 0 商业广告 • 0 商业 SDK • 0 任何跟踪代码 • 极致轻量省电**  
> 专为 **2BOT** 多智能体系统打造的 Android 专属移动端伴侣应用，彻底终结用户使用带商业广告流氓宏软件（如 MacroDroid）的糟糕体验。

---

## 💡 为什么需要 2BOT 伴侣端？

在 2BOT 智能生态系统中，BOT 具备独特的起居规律推演与时空感知底座。  
为了让系统能够**无感获知主人的起居状态、空间网络环境（如家庭 WiFi）与设备电量**，需要手机端定期且低功耗地上报设备状态快照。

- **拒绝流氓商业宏**：彻底摆脱第三方商业宏软件动辄强制观看开屏广告、激励视频等侵扰；
- **双驱动高效省电**：
  - **事件驱动**：插拔充电器、WiFi 连入/断开时毫秒级即刻上报；
  - **定时保底**：按设定间隔（默认 10 分钟）静默心跳上报一次，有效杜绝数据超过 60 分钟引发失鲜超时熔断；
- **原生暗黑科技风**：精心雕琢的 Material 3 `#0F172A` 暗黑界面，视觉高级且在 OLED 屏幕上极致省电；
- **前台服务保活**：基于 Android 原生 `dataSync` 前台常驻通知，稳健抗击国产深度定制 Android 系统的激进后台查杀。

---

## 📡 通信协议与数据契约 (SSOT)

本应用支持**双信道**上报：**邮箱信道（mail，推荐主力）** 与 **HTTP 中继信道（relay，兼容保留）**。
两者上报同一份遥测 Payload，可在 App 设置中一键切换；切换即切换链路，**无需改代码、可随时回滚**。

### 信道 A · 邮箱信道（mail · 推荐）

链路：手机 `SMTP 465（隐式 TLS）` 发信 → 邮箱收件箱 → NAS 端 `IMAP 993（隐式 TLS）` 拉取。
适用于国内网络环境下 HTTP 中继不可达的场景，且邮箱天然是一份**可回溯的时间线**。

#### 主题格式

```
X-2BOT-TEL-{毫秒时间戳}
```

前缀 `X-2BOT-TEL` 可在 App 设置中修改，**须与 NAS 端配置保持一致**。
服务端按**严格 `{前缀}-{纯数字}` 形态**判定归属，仅"包含前缀子串"不算命中——避免误伤邮箱里的第三方邮件。

#### 正文格式（ENC1 加密信封）

加密默认开启。正文为单行信封：

```
ENC1:{iv_b64}:{tag_b64}:{ct_b64}
```

| 字段 | 规格 |
|---|---|
| 算法 | AES-256-GCM，无 AAD |
| `key` | 32 字节，配置为 **64 个十六进制字符** |
| `iv` | 12 字节随机，每封新生成 |
| `tag` | 16 字节认证标签 |
| `ct` | 密文 |
| 字段序 | 固定 `ENC1 : iv : tag : ct`，分隔符两侧无空格 |

- **加密默认开启；加密失败即放弃该封，系统绝不降级为明文发送。**
- 加密关闭时正文为遥测 JSON 单行 UTF-8（明文模式仅供调试，不建议在公网邮箱中使用）。
- 该信封格式有**跨语言一致性测试（KAT）**：固定 key + 固定 iv 下的产出逐字节锁定，NAS 端可无损解密，
  两端任一口径偏移都会在 CI 直接失败。加密密钥必须与 NAS 端**完全一致**。

### 信道 B · HTTP 中继（relay · 兼容保留）

原中继链路完整保留，配置与行为未变。当邮箱链路不可用时可直接切回。

- **请求方法**：`POST`
- **请求地址**：`https://your-relay-service.vercel.app/push`（支持在 App 设置中自由修改）
- **请求头**：
  ```http
  Content-Type: application/json; charset=utf-8
  x-device-token: YOUR_DEVICE_TOKEN
  ```

### 标准上报 Payload (JSON)

两条信道上报同一份 Payload：

```json
{
  "battery": {
    "level": 92,          // 当前电量百分比 (0~100)
    "isCharging": true    // 是否正在充电 (true/false)
  },
  "wifi": {
    "connected": true,    // 是否连接 WiFi (true/false)
    "ssid": "My_Home_WiFi" // 当前 WiFi 名称 (未连接或未授权时为空字符串)
  },
  "screenLocked": true,   // 是否息屏/锁屏 (true/false)
  "foregroundApp": "None",// 当前前台应用名称 (默认 None 或自身)
  "timestamp": 1789123337335
}
```

### 服务端回执（仅 relay 信道）

```json
{
  "ok": true,
  "message": "Telemetry updated successfully",
  "received_at": "2026-09-11T10:42:17.333Z"
}
```

### ⚙️ 邮箱信道配置指引

1. **邮箱账号**：填收发同源的单邮箱账号（例如 `your-account@qq.com`）。
2. **邮箱授权码**：**不是**邮箱登录密码。QQ 邮箱网页版 →「设置 → 账号」→ 开启 `IMAP/SMTP 服务`，
   按提示生成**授权码**，填入 App。授权码仅保存在手机系统安全存储（Android Keystore）中。
3. **收件地址**：留空即等于发信账号（单邮箱自发自收）。
4. **加密密钥**：64 个十六进制字符（32 字节）。生成方式可任选一种可信工具，填写后**与 NAS 端配置逐字一致**。
5. **切换位置**：App 首页「传输信道与上报设置」→ 传输模式选择 `邮箱信道 (mail)` 或 `云端中继 (relay)`。

> 🔒 **凭据安全**：授权码与加密密钥一律存入 `flutter_secure_storage`（Android Keystore 加密），
> 不写入明文偏好设置，也不会出现在任何日志中。

### ℹ️ 关于邮箱服务端的两点须知

不同邮箱服务商的 IMAP 实现能力存在差异，本应用已针对主流国内邮箱（QQ 邮箱）的实测行为做过适配，
使用者无需关心细节，但了解以下两点有助于理解行为：

- **增量机制**：服务端若不支持按标志位筛选已读邮件，应用侧改用 **UID 水位线**逐轮拉取增量，
  不会重复处理历史邮件。
- **过期清理**：对超过保留期（默认 7 天）的本系统邮件，服务端采用**移入删除箱**处理——
  这是**可恢复**的语义，并非永久删除。因此实际可回溯窗口 = 保留天数 + 邮箱删除箱的服务端保留期。

> 📌 本文档为公开文档，示例中的邮箱账号、授权码、加密密钥、中继地址**全部为占位符**，
> 请自行替换为您自己的配置，切勿将真实凭据提交到任何公开位置。

---

## 🏗️ 模块化工程架构

```text
2bot-companion/
├── .github/workflows/
│   └── build_apk.yml                 # GitHub Actions 云端全自动 Release APK 构建出包流水线
├── android/
│   ├── app/
│   │   ├── src/main/
│   │   │   ├── AndroidManifest.xml   # 完备权限声明 (网络、WiFi、定位、前台服务)
│   │   │   └── kotlin/.../MainActivity.kt
│   │   └── build.gradle              # Android 构建配置 (Java 17, SDK 34)
│   ├── build.gradle
│   └── settings.gradle
├── lib/
│   ├── models/
│   │   ├── device_telemetry.dart     # 设备状态数据模型 (SSOT)
│   │   └── app_settings.dart         # 用户配置模型
│   ├── services/
│   │   ├── storage_service.dart      # SharedPreferences 配置持久化
│   │   ├── telemetry_collector_service.dart # 电池/WiFi/锁屏状态硬件采集器
│   │   ├── telemetry_uploader_service.dart  # 云端 HTTP POST 上传服务
│   │   └── background_task_service.dart     # flutter_foreground_task 常驻保活
│   ├── utils/
│   │   ├── constants.dart            # 全局配置常量
│   │   └── theme.dart                # Material 3 暗黑科技设计系统
│   ├── views/
│   │   ├── widgets/
│   │   │   ├── status_card.dart      # 实时物理状态看板卡片
│   │   │   ├── config_card.dart      # 云端中继与频率设置卡片
│   │   │   └── quick_actions.dart    # 立即测试与常驻开关组件
│   │   └── home_screen.dart          # 伴侣端主界面
│   └── main.dart                     # 应用程序入口
├── pubspec.yaml                      # 纯血开源依赖清单
└── README.md
```

---

## 🚀 云端自动出包 (零本地 Flutter 环境)

本项目已集成完整的 **GitHub Actions CI/CD 流水线**，您无需在本地电脑配置繁琐的 Flutter 或 Android SDK 环境：

1. **推送代码至 GitHub**：
   ```bash
   git add .
   git commit -m "feat: complete 2bot-companion v1.0.0"
   git push origin main
   ```
2. **自动构建 APK**：
   - 打开 GitHub 仓库的 **「Actions」** 标签页；
   - 看到 `🚀 Build Release APK` 自动被触发并运行；
   - 构建完成后，点击该次运行记录，在下方 **Artifacts** 处直接下载 **`2bot-companion-apk`**（解压即得到 `app-release.apk`）；
3. **版本发布 (Release)**：
   - 若打上版本标签推送（例如 `git tag v1.0.0 && git push --tags`），GitHub Actions 将全自动在 Releases 页面发布成品 APK 文件，手机点开链接一键下载安装！

---

## 🛠️ 本地开发者编译指南 (可选)

如果您本地已安装 Flutter SDK：

```bash
# 1. 检查 Flutter 环境
flutter doctor

# 2. 获取依赖包
flutter pub get

# 3. 运行调试
flutter run

# 4. 本地编译正式版 APK
flutter build apk --release
# 生成路径: build/app/outputs/flutter-apk/app-release.apk
```

---

## 📲 Android 手机端使用与保活指南

安装 APK 后，为了保证起居与位置状态能够在锁屏休眠下准确无感上报，建议进行以下一次性配置：

1. **授予定位权限**：
   - Android 10+ 规范要求应用必须拥有**系统定位权限**（精确位置）方可读取已连接的 WiFi SSID；打开手机 GPS 开关即可准确识别是否连接了家庭 WiFi。
2. **加入电池优化白名单**：
   - 打开手机 **「设置」** ➔ **「应用管理」** ➔ **「2BOT 伴侣」** ➔ **「省电策略 / 电池优化」** ➔ 设为 **「无限制 / 不优化」**。
3. **允许后台自启动**：
   - 开启 **「自启动」** 与 **「关联启动」** 权限，并在多任务后台将 2BOT 伴侣卡片**加锁**，防止系统清后台杀除。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 协议纯血开源，永久免费、零广告、零商业追踪。
