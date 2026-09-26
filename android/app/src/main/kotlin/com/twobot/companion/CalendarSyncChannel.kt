package com.twobot.companion

import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * WO-69 · 日历写入 MethodChannel（薄封装：业务判新旧全部下沉 Dart 台账，Kotlin 只做 CRUD）。
 *
 * 引擎挂载面（两处）：
 *  1. 主引擎：MainActivity.configureFlutterEngine → [attach]；
 *  2. 后台任务引擎：flutter_foreground_task 8.17 每次 task 启动新建 FlutterEngine
 *     （ForegroundTask.kt:49）并在执行 Dart 回调【之前】回调 onEngineCreate
 *     （ForegroundTask.kt:56）→ 经 [ensureTaskEngineListener] 注册的
 *     FlutterForegroundTaskLifecycleListener 把同一通道挂到后台引擎上，
 *     后台 isolate 的 MethodChannel 调用由此可达。
 *
 * 红线（规格 T3）：
 *  - 只读写自建本地日历（ACCOUNT_TYPE=2bot.local）；一切事件查询以 CALENDAR_ID=自建 收敛，
 *    结构性隔离用户其它日历；
 *  - 幂等键 = CUSTOM_APP_PACKAGE(本包) + CUSTOM_APP_URI(=ICS UID)（AOSP 实证普通应用可写）；
 *  - CANCELLED → 按 UID 删除该本地事件；
 *  - 权限校验失败一律 result.error，不崩溃、不触碰遥测。
 */
object CalendarSyncChannel : MethodChannel.MethodCallHandler {

    const val CHANNEL_NAME = "com.twobot.companion/calendar_sync"

    private const val ACCOUNT_NAME = "2bot"
    private const val ACCOUNT_TYPE = "2bot.local"
    private const val DISPLAY_NAME = "2BOT 日历"

    private var appContext: Context? = null
    private var worker: Handler? = null
    private var listenerRegistered = false
    private val main = Handler(Looper.getMainLooper())

    /** 挂到指定引擎（幂等：同一 handler 对象可服务多引擎） */
    fun attach(context: Context, engine: FlutterEngine) {
        if (thread == null) {
            thread = HandlerThread("wo69-calendar").also { it.start() }
            worker = Handler(thread!!.looper)
        }
        if (appContext == null) appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler(this)
        // WO-69/C3 实机验证观测点：主引擎与后台任务引擎各打一条——
        // logcat 过滤 `WO69.*attached` 出现两条即证明后台引擎通道挂载成功
        android.util.Log.d("WO69", "calendar_sync channel attached to a FlutterEngine")
    }

    private var thread: HandlerThread? = null

    /** 注册后台任务引擎生命周期监听（进程级一次；引擎每次重建都会触发 onEngineCreate） */
    fun ensureTaskEngineListener(context: Context) {
        if (listenerRegistered) return
        listenerRegistered = true
        appContext = context.applicationContext
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(
            object : FlutterForegroundTaskLifecycleListener {
                override fun onEngineCreate(flutterEngine: FlutterEngine?) {
                    flutterEngine?.let { attach(context, it) }
                }

                override fun onTaskStart(starter: FlutterForegroundTaskStarter) {}
                override fun onTaskRepeatEvent() {}
                override fun onTaskDestroy() {}
                override fun onEngineWillDestroy() {}
            }
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ping" -> {
                result.success(
                    mapOf(
                        "ok" to true,
                        "calendarPermission" to hasCalendarPermission(),
                        "engine" to "attached"
                    )
                )
            }
            "upsertEvents" -> {
                val args = call.arguments as? Map<*, *>
                val events = args?.get("events") as? List<*> ?: emptyList<Any>()
                val w = worker
                if (w == null) {
                    result.error("CALENDAR_ERROR", "worker 未初始化", null)
                    return
                }
                w.post {
                    try {
                        val summary = upsertAll(events)
                        main.post { result.success(summary) }
                    } catch (e: Exception) {
                        main.post {
                            result.error("CALENDAR_ERROR", safeMessage(e), null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------
    // 日历操作（全部运行在 worker 线程）
    // ------------------------------------------------------------------

    private fun hasCalendarPermission(): Boolean {
        val ctx = appContext ?: return false
        return ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.READ_CALENDAR) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.WRITE_CALENDAR) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    /** 定位（必要时创建）自建本地日历；返回 calendarId */
    private fun ensureCalendarId(resolver: ContentResolver): Long {
        val calendarsUri = CalendarContract.Calendars.CONTENT_URI
        val selection =
            "${CalendarContract.Calendars.ACCOUNT_NAME}=? AND ${CalendarContract.Calendars.ACCOUNT_TYPE}=?"
        resolver.query(
            calendarsUri,
            arrayOf(CalendarContract.Calendars._ID),
            selection,
            arrayOf(ACCOUNT_NAME, ACCOUNT_TYPE),
            null
        )?.use { c ->
            if (c.moveToFirst()) return c.getLong(0)
        }

        val values = ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, ACCOUNT_NAME)
            put(CalendarContract.Calendars.ACCOUNT_TYPE, ACCOUNT_TYPE)
            put(CalendarContract.Calendars.NAME, ACCOUNT_TYPE)
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, DISPLAY_NAME)
            put(CalendarContract.Calendars.CALENDAR_COLOR, 0xFF26C6DA.toInt())
            put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL, CalendarContract.Calendars.CAL_ACCESS_OWNER)
            put(CalendarContract.Calendars.OWNER_ACCOUNT, ACCOUNT_NAME)
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
        }
        // 本地日历标准插入形态：非 sync-adapter + 自有账号身份（不注册 AccountManager）
        val insertUri = calendarsUri.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "false")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, ACCOUNT_NAME)
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, ACCOUNT_TYPE)
            .build()
        val uri = resolver.insert(insertUri, values)
            ?: throw IllegalStateException("创建自建日历失败（provider 返回空）")
        return ContentUris.parseId(uri)
    }

    /** 批量幂等 upsert / 取消删除。返回摘要。 */
    private fun upsertAll(events: List<*>): Map<String, Any> {
        val ctx = appContext ?: throw IllegalStateException("context 未初始化")
        val resolver = ctx.contentResolver
        var applied = 0
        var skipped = 0
        var deleted = 0

        val calId = ensureCalendarId(resolver)
        val eventsUri = CalendarContract.Events.CONTENT_URI

        for (raw in events) {
            val e = raw as? Map<*, *> ?: continue
            val uid = e["uid"] as? String
            if (uid.isNullOrEmpty()) {
                skipped++
                continue
            }
            // 幂等键查询：只在本自建日历内，CUSTOM_APP_URI=ICS UID
            val selection =
                "${CalendarContract.Events.CALENDAR_ID}=? AND " +
                        "${CalendarContract.Events.CUSTOM_APP_PACKAGE}=? AND " +
                        "${CalendarContract.Events.CUSTOM_APP_URI}=?"
            val selectionArgs = arrayOf(calId.toString(), ctx.packageName, uid)
            val existingId = resolver.query(
                eventsUri,
                arrayOf(CalendarContract.Events._ID),
                selection,
                selectionArgs,
                null
            )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }

            val cancelled = e["cancelled"] as? Boolean ?: false
            if (cancelled) {
                if (existingId != null) {
                    resolver.delete(
                        ContentUris.withAppendedId(eventsUri, existingId), null, null
                    )
                    deleted++
                } else {
                    skipped++
                }
                continue
            }

            val dtstartMs = (e["dtstartMs"] as? Number)?.toLong()
            if (dtstartMs == null) {
                skipped++
                continue
            }
            val endMs = (e["endMs"] as? Number)?.toLong()
            val allDay = e["allDay"] as? Boolean ?: false
            val rrule = e["rrule"] as? String

            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calId)
                put(CalendarContract.Events.CUSTOM_APP_PACKAGE, ctx.packageName)
                put(CalendarContract.Events.CUSTOM_APP_URI, uid)
                put(CalendarContract.Events.TITLE, e["summary"] as? String ?: "(无标题)")
                val desc = e["description"] as? String
                if (desc == null) putNull(CalendarContract.Events.DESCRIPTION)
                else put(CalendarContract.Events.DESCRIPTION, desc)
                put(CalendarContract.Events.DTSTART, dtstartMs)
                // DTEND 与 DURATION 互斥（provider 强校验）：写一个必清另一个
                if (endMs != null) {
                    put(CalendarContract.Events.DTEND, endMs)
                    putNull(CalendarContract.Events.DURATION)
                } else {
                    putNull(CalendarContract.Events.DTEND)
                    put(CalendarContract.Events.DURATION, if (allDay) "P1D" else "PT1H")
                }
                if (allDay) {
                    put(CalendarContract.Events.ALL_DAY, 1)
                    // 全天事件的 DTSTART 按事件时区的墙钟解释：用设备本地时区才能对齐日期
                    put(CalendarContract.Events.EVENT_TIMEZONE, java.util.TimeZone.getDefault().id)
                } else {
                    put(CalendarContract.Events.ALL_DAY, 0)
                    put(CalendarContract.Events.EVENT_TIMEZONE, "UTC")
                }
                if (rrule.isNullOrEmpty()) putNull(CalendarContract.Events.RRULE)
                else put(CalendarContract.Events.RRULE, rrule)
                // 注：Events 的 sequence 列为 provider 自管（android.jar 无公开常量），
                // 新旧判定全部由 Dart 侧台账完成，Kotlin 保持薄封装
            }

            if (existingId != null) {
                resolver.update(
                    ContentUris.withAppendedId(eventsUri, existingId), values, null, null
                )
                applied++
            } else {
                resolver.insert(eventsUri, values)
                applied++
            }
        }
        return mapOf(
            "applied" to applied,
            "skipped" to skipped,
            "deleted" to deleted,
            "calendarId" to calId,
        )
    }

    private fun safeMessage(e: Exception): String =
        e.message ?: e.javaClass.simpleName
}
