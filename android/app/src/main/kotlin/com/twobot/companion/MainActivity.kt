package com.twobot.companion

import android.Manifest
import android.app.AlarmManager
import android.app.AppOpsManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity(), SensorEventListener {

    private val channelName = "com.twobot.companion/native_sensors"
    private var sensorManager: SensorManager? = null
    private var stepSensor: Sensor? = null
    private var currentTotalSteps: Int? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        stepSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
    }

    override fun onResume() {
        super.onResume()
        stepSensor?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeSensors" -> {
                    try {
                        result.success(collectNativeSensors())
                    } catch (e: Exception) {
                        result.error("NATIVE_SENSOR_ERROR", e.localizedMessage, null)
                    }
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        requestIgnoreBatteryOptimizations()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BATTERY_OPT_ERROR", e.localizedMessage, null)
                    }
                }
                "openUsageSettings" -> {
                    try {
                        openUsageSettings()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("USAGE_SETTINGS_ERROR", e.localizedMessage, null)
                    }
                }
                "hasUsagePermission" -> {
                    try {
                        result.success(checkUsagePermission())
                    } catch (e: Exception) {
                        result.error("USAGE_PERM_ERROR", e.localizedMessage, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type == Sensor.TYPE_STEP_COUNTER && event.values.isNotEmpty()) {
            val totalSteps = event.values[0].toInt()
            currentTotalSteps = totalSteps
            saveStepRecord(totalSteps)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun saveStepRecord(steps: Int) {
        val prefs = getSharedPreferences("native_sensor_prefs", Context.MODE_PRIVATE)
        val todayStr = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        val savedDate = prefs.getString("step_date", null)
        val savedBase = prefs.getInt("step_base", -1)

        val editor = prefs.edit().putInt("last_total_step", steps)
        if (savedDate != todayStr || savedBase < 0 || steps < savedBase) {
            editor.putString("step_date", todayStr)
            editor.putInt("step_base", steps)
        }
        editor.apply()
    }

    private fun getTodaySteps(): Int? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION)
                != PackageManager.PERMISSION_GRANTED) {
                return null
            }
        }
        if (stepSensor == null) {
            return null
        }

        val prefs = getSharedPreferences("native_sensor_prefs", Context.MODE_PRIVATE)
        val todayStr = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
        val savedDate = prefs.getString("step_date", null)
        var savedBase = prefs.getInt("step_base", -1)

        val steps = currentTotalSteps ?: run {
            val lastTotal = prefs.getInt("last_total_step", -1)
            if (lastTotal >= 0) lastTotal else null
        } ?: return null

        if (savedDate != todayStr || savedBase < 0 || steps < savedBase) {
            savedBase = steps
            prefs.edit()
                .putString("step_date", todayStr)
                .putInt("step_base", savedBase)
                .putInt("last_total_step", steps)
                .apply()
            return 0
        }

        prefs.edit().putInt("last_total_step", steps).apply()
        val delta = steps - savedBase
        return if (delta >= 0) delta else 0
    }

    private fun collectNativeSensors(): Map<String, Any?> {
        val map = HashMap<String, Any?>()

        // 1. stepsToday
        val stepsToday = getTodaySteps()
        map["stepsToday"] = stepsToday

        // 2. Audio & Headset
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val isMusicActive = audioManager?.isMusicActive ?: false
        val isBluetoothAudio: Boolean = if (audioManager != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                devices.any {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                        (it.type == AudioDeviceInfo.TYPE_BLE_HEADSET || it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER))
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.isBluetoothA2dpOn
            }
        } else {
            false
        }

        val isWiredHeadset: Boolean = if (audioManager != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                devices.any {
                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && it.type == AudioDeviceInfo.TYPE_USB_HEADSET)
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.isWiredHeadsetOn
            }
        } else {
            false
        }

        map["isMusicActive"] = isMusicActive
        map["isBluetoothAudio"] = isBluetoothAudio
        map["isWiredHeadset"] = isWiredHeadset
        map["audio"] = mapOf(
            "isMusicActive" to isMusicActive,
            "isBluetoothAudio" to isBluetoothAudio,
            "isWiredHeadset" to isWiredHeadset
        )

        // 3. Ringer & DND
        val ringerModeStr = when (audioManager?.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> "silent"
            AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
            AudioManager.RINGER_MODE_NORMAL -> "normal"
            else -> "normal"
        }
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val isDnd = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && notificationManager != null) {
            val filter = notificationManager.currentInterruptionFilter
            filter != NotificationManager.INTERRUPTION_FILTER_ALL && filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        } else {
            false
        }

        map["ringerMode"] = ringerModeStr
        map["isDnd"] = isDnd
        map["ringer"] = mapOf(
            "ringerMode" to ringerModeStr,
            "isDnd" to isDnd
        )

        // 4. Next Alarm
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        val nextAlarmClock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && alarmManager != null) {
            alarmManager.nextAlarmClock
        } else {
            null
        }

        val nextAlarm: Map<String, Any?>? = if (nextAlarmClock != null) {
            val triggerTime = nextAlarmClock.triggerTime
            val now = System.currentTimeMillis()
            val triggerCal = Calendar.getInstance().apply { timeInMillis = triggerTime }
            val nowCal = Calendar.getInstance().apply { timeInMillis = now }

            val isTomorrow = (triggerCal.get(Calendar.YEAR) == nowCal.get(Calendar.YEAR) &&
                    triggerCal.get(Calendar.DAY_OF_YEAR) == nowCal.get(Calendar.DAY_OF_YEAR) + 1)
            val isToday = (triggerCal.get(Calendar.YEAR) == nowCal.get(Calendar.YEAR) &&
                    triggerCal.get(Calendar.DAY_OF_YEAR) == nowCal.get(Calendar.DAY_OF_YEAR))

            val timeFormat = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(triggerTime))
            val formatted = when {
                isToday -> timeFormat
                isTomorrow -> "明天 $timeFormat"
                else -> SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(triggerTime))
            }
            mapOf("triggerTime" to triggerTime, "formatted" to formatted)
        } else {
            null
        }
        map["nextAlarm"] = nextAlarm

        // 5. Battery Optimization Whitelist
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val isIgnoringBatteryOptimizations = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && powerManager != null) {
            powerManager.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }
        map["isIgnoringBatteryOptimizations"] = isIgnoringBatteryOptimizations

        // 6. Screen Time Minutes & Usage Permission
        val hasUsagePermission = checkUsagePermission()
        map["hasUsagePermission"] = hasUsagePermission

        val screenTimeMinutes: Int? = if (hasUsagePermission && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                if (usageStatsManager != null) {
                    val calendar = Calendar.getInstance().apply {
                        set(Calendar.HOUR_OF_DAY, 0)
                        set(Calendar.MINUTE, 0)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }
                    val startTime = calendar.timeInMillis
                    val endTime = System.currentTimeMillis()
                    val stats = usageStatsManager.queryUsageStats(
                        UsageStatsManager.INTERVAL_DAILY,
                        startTime,
                        endTime
                    )
                    if (stats != null) {
                        var totalTimeMs = 0L
                        for (usage in stats) {
                            totalTimeMs += usage.totalTimeInForeground
                        }
                        (totalTimeMs / (1000 * 60)).toInt()
                    } else {
                        null
                    }
                } else {
                    null
                }
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
        map["screenTimeMinutes"] = screenTimeMinutes

        return map
    }

    private fun checkUsagePermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager ?: return false
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (powerManager?.isIgnoringBatteryOptimizations(packageName) == false) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(intent)
                } catch (_: Exception) {
                    try {
                        val fallbackIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(fallbackIntent)
                    } catch (_: Exception) {}
                }
            }
        }
    }

    private fun openUsageSettings() {
        try {
            val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
        } catch (_: Exception) {}
    }
}
