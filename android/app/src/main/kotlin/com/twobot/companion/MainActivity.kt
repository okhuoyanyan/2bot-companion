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
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
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

    private var locationManager: LocationManager? = null
    private var lastLocation: Location? = null

    private var currentWifiSsid: String? = null
    private var wifiNetworkCallback: ConnectivityManager.NetworkCallback? = null

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            lastLocation = location
        }
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        stepSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
        locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        registerWifiNetworkCallback()
    }

    override fun onResume() {
        super.onResume()
        stepSensor?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        registerLocationUpdates()
        registerWifiNetworkCallback()
    }

    override fun onPause() {
        super.onPause()
        unregisterLocationUpdates()
        unregisterWifiNetworkCallback()
    }

    override fun onDestroy() {
        unregisterWifiNetworkCallback()
        super.onDestroy()
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
                "getLocation" -> {
                    try {
                        result.success(collectLocation())
                    } catch (e: Exception) {
                        result.error("LOCATION_ERROR", e.localizedMessage, null)
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

        // 4. Next Alarm (仅采纳系统官方时钟/闹钟应用，严格排除日历、第三方后台保活心跳)
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        val nextAlarmClock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && alarmManager != null) {
            alarmManager.nextAlarmClock
        } else {
            null
        }

        val nextAlarm: Map<String, Any?>? = if (nextAlarmClock != null) {
            val triggerTime = nextAlarmClock.triggerTime
            val now = System.currentTimeMillis()

            // 提取设置此闹钟的 App 包名
            val creatorPackage = nextAlarmClock.showIntent?.creatorPackage ?: ""
            val lowerPkg = creatorPackage.lowercase(Locale.ROOT)

            // 解析系统默认时钟应用
            val defaultClockPkg = try {
                val clockIntent = Intent(android.provider.AlarmClock.ACTION_SHOW_ALARMS)
                packageManager.resolveActivity(clockIntent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName ?: ""
            } catch (_: Exception) { "" }

            val setAlarmPkg = try {
                val setIntent = Intent(android.provider.AlarmClock.ACTION_SET_ALARM)
                packageManager.resolveActivity(setIntent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName ?: ""
            } catch (_: Exception) { "" }

            // 严格黑名单排除：日历、日程、社交、备忘录、天气、后台推送心跳
            val isExcluded = lowerPkg.contains("calendar") ||
                    lowerPkg.contains("schedule") ||
                    lowerPkg.contains("tencent") ||
                    lowerPkg.contains("wechat") ||
                    lowerPkg.contains("dingtalk") ||
                    lowerPkg.contains("weather") ||
                    lowerPkg.contains("reminder") ||
                    lowerPkg.contains("memo") ||
                    lowerPkg.contains("notes")

            // 严格白名单判定：系统默认时钟应用或已知主流厂商官方时钟应用
            val isSystemClock = !isExcluded && (
                    (creatorPackage.isNotEmpty() && (creatorPackage == defaultClockPkg || creatorPackage == setAlarmPkg)) ||
                    lowerPkg.contains("deskclock") ||
                    lowerPkg.contains("alarmclock") ||
                    lowerPkg.contains("clockpackage") ||
                    lowerPkg.endsWith(".clock")
            )

            // 若不是系统时钟，或者时间已过期，直接丢弃
            if (!isSystemClock || triggerTime <= now) {
                null
            } else {
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
                mapOf(
                    "triggerTime" to triggerTime,
                    "formatted" to formatted,
                    "package" to creatorPackage
                )
            }
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

        // 7. Location (GPS / Network)
        map["location"] = collectLocation()

        // 8. Native WiFi SSID (Bypasses Flutter plugin limitations on Chinese ROMs)
        map["nativeWifiSsid"] = collectNativeWifiSsid()

        return map
    }

    private fun registerLocationUpdates() {
        val lm = locationManager ?: return
        val hasFine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) return

        try {
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 10000L, 10f, locationListener)
            }
            if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 10000L, 10f, locationListener)
            }
            val gpsLoc = try { lm.getLastKnownLocation(LocationManager.GPS_PROVIDER) } catch (_: Exception) { null }
            val netLoc = try { lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER) } catch (_: Exception) { null }
            val passiveLoc = try { lm.getLastKnownLocation(LocationManager.PASSIVE_PROVIDER) } catch (_: Exception) { null }

            val best = listOfNotNull(lastLocation, gpsLoc, netLoc, passiveLoc).maxByOrNull { it.time }
            if (best != null) {
                lastLocation = best
            }
        } catch (_: Exception) {}
    }

    private fun unregisterLocationUpdates() {
        try {
            locationManager?.removeUpdates(locationListener)
        } catch (_: Exception) {}
    }

    private fun collectLocation(): Map<String, Any?>? {
        val lm = locationManager ?: return null
        val hasFine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) return null

        try {
            val gpsLoc = try { lm.getLastKnownLocation(LocationManager.GPS_PROVIDER) } catch (_: Exception) { null }
            val netLoc = try { lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER) } catch (_: Exception) { null }
            val passiveLoc = try { lm.getLastKnownLocation(LocationManager.PASSIVE_PROVIDER) } catch (_: Exception) { null }

            val candidates = listOfNotNull(lastLocation, gpsLoc, netLoc, passiveLoc)
            if (candidates.isEmpty()) return null

            val best = candidates.maxByOrNull { it.time } ?: return null

            return mapOf(
                "latitude" to best.latitude,
                "longitude" to best.longitude,
                "accuracy" to best.accuracy.toDouble(),
                "altitude" to best.altitude,
                "speed" to best.speed.toDouble(),
                "bearing" to best.bearing.toDouble(),
                "provider" to (best.provider ?: "unknown"),
                "time" to best.time
            )
        } catch (_: Exception) {
            return null
        }
    }

    private fun registerWifiNetworkCallback() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val hasFine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val hasCoarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) return

        try {
            // Immediately probe current connection
            val activeNetwork = cm.activeNetwork
            if (activeNetwork != null) {
                val caps = cm.getNetworkCapabilities(activeNetwork)
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    val wifiInfo = caps.transportInfo as? WifiInfo
                    extractSsid(wifiInfo)?.let { currentWifiSsid = it }
                }
            }
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            extractSsid(wm?.connectionInfo)?.let { currentWifiSsid = it }

            // Register asynchronous NetworkCallback
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                try {
                    wifiNetworkCallback = object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
                        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                            val wifiInfo = caps.transportInfo as? WifiInfo
                            extractSsid(wifiInfo)?.let { currentWifiSsid = it }
                        }
                        override fun onLost(network: Network) {
                            currentWifiSsid = null
                        }
                    }
                    cm.registerNetworkCallback(request, wifiNetworkCallback!!)
                    return
                } catch (_: Exception) {}
            }

            wifiNetworkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    val wifiInfo = caps.transportInfo as? WifiInfo
                    extractSsid(wifiInfo)?.let { currentWifiSsid = it }
                }
                override fun onLost(network: Network) {
                    currentWifiSsid = null
                }
            }
            cm.registerNetworkCallback(request, wifiNetworkCallback!!)
        } catch (_: Exception) {}
    }

    private fun unregisterWifiNetworkCallback() {
        try {
            wifiNetworkCallback?.let {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                cm?.unregisterNetworkCallback(it)
            }
        } catch (_: Exception) {}
        wifiNetworkCallback = null
    }

    private fun extractSsid(wifiInfo: WifiInfo?): String? {
        if (wifiInfo == null) return null
        var ssid = wifiInfo.ssid ?: return null
        if (ssid.startsWith("\"") && ssid.endsWith("\"") && ssid.length >= 2) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        return if (ssid.isNotEmpty() && ssid != "<unknown ssid>" && ssid != "0x") ssid else null
    }

    private fun collectNativeWifiSsid(): String? {
        if (!currentWifiSsid.isNullOrEmpty()) {
            return currentWifiSsid
        }

        try {
            val connManager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val activeNetwork = connManager?.activeNetwork
            if (activeNetwork != null) {
                val caps = connManager.getNetworkCapabilities(activeNetwork)
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    val wifiInfo = caps.transportInfo as? WifiInfo
                    extractSsid(wifiInfo)?.let {
                        currentWifiSsid = it
                        return it
                    }
                }
            }

            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            val info = wifiManager?.connectionInfo
            extractSsid(info)?.let {
                currentWifiSsid = it
                return it
            }
        } catch (_: Exception) {}

        return currentWifiSsid
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
