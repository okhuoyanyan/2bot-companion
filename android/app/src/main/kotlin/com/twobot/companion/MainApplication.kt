package com.twobot.companion

import android.app.Application

/**
 * WO-69 追补整改（急件⑤②退化方案）：进程启动即注册任务引擎生命周期监听。
 *
 * 原注册点在 MainActivity.configureFlutterEngine——仅 App 打开时运行；
 * 开机自启（autoRunOnBoot）路径直接拉起前台服务、MainActivity 从未运行 →
 * 监听未注册 → 后台任务引擎创建时 onEngineCreate 无人接 → 日历通道缺失 →
 * 后台 isolate 全部写入 MissingPluginException。
 * Application.onCreate 覆盖所有进程启动路径（冷启/自启/任务拉起），通道必挂。
 */
class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        CalendarSyncChannel.ensureTaskEngineListener(this)
    }
}
