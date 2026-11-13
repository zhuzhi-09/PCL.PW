package io.github.zhuzhi09.pcl_pw

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageInstaller
import android.app.PendingIntent
import android.os.IBinder
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.zhuzhi09.pclpw.runtime.GameActivity
import io.github.zhuzhi09.pclpw.runtime.GameRuntime
import io.github.zhuzhi09.pclpw.runtime.JarService
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var runtimeChannel: MethodChannel? = null

    /** 正在运行的 jar（JarService 进程）；进程退出后自动解除绑定 */
    private var jarConnection: ServiceConnection? = null

    private fun processRunning(suffix: String): Boolean {
        val am = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
        return am.runningAppProcesses?.any { it.processName == "$packageName:$suffix" } == true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // 共享存储：游戏文件夹放在 /storage/emulated/0 下，卸载应用后仍然保留
        MethodChannel(messenger, "pclpw/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "externalRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                "hasAccess" -> result.success(hasAccess())
                "requestAccess" -> requestAccess(result)
                else -> result.notImplemented()
            }
        }
        // 标题栏显示的电量与网络（启动器全屏时系统状态栏被隐藏）
        MethodChannel(messenger, "pclpw/device").setMethodCallHandler { call, result ->
            if (call.method != "status") return@setMethodCallHandler result.notImplemented()
            val battery = getSystemService(BATTERY_SERVICE) as BatteryManager
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            val network = when {
                caps == null -> "none"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
            // 充电状态以系统的电池广播为准：部分机型插着电时 BatteryManager.isCharging 仍返回 false
            val sticky = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val status = sticky?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val plugged = (sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
            result.success(
                mapOf(
                    "battery" to battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                    "charging" to (status == BatteryManager.BATTERY_STATUS_CHARGING || battery.isCharging),
                    "full" to (status == BatteryManager.BATTERY_STATUS_FULL),
                    "plugged" to plugged,
                    "network" to network,
                ),
            )
        }
        // 启动器更新：用 PackageInstaller 安装下载好的 APK，系统会弹出确认
        MethodChannel(messenger, "pclpw/update").setMethodCallHandler { call, result ->
            if (call.method != "installApk") return@setMethodCallHandler result.notImplemented()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                return@setMethodCallHandler result.error("permission", "请在系统设置中允许 PCL.PW 安装应用，然后重试", null)
            }
            background(result) {
                installApk(File(call.argument<String>("path")!!))
                null
            }
        }
        // 游戏运行时（android/runtime 模块）
        val runtime = MethodChannel(messenger, "pclpw/runtime")
        runtimeChannel = runtime
        runtime.setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> background(result) {
                    // 用 SDL 的版本（26.x）需要 LWJGL 3.4.1
                    val lwjgl = if (call.argument<Boolean>("sdl") == true) GameRuntime.LWJGL_SDL_VERSION else GameRuntime.LWJGL_VERSION
                    mapOf(
                        "nativeLibDir" to applicationInfo.nativeLibraryDir,
                        "lwjglClasspath" to GameRuntime.lwjglClasspath(this, lwjgl),
                        "lwjglx" to GameRuntime.lwjglxJar(this),
                        "lwjglVersion" to lwjgl,
                    )
                }
                // 显卡信息，用于选择渲染器
                "gpu" -> background(result) { GameRuntime.gpuInfo(this) }
                "installJre" -> background(result) {
                    val archive = File(call.argument<String>("archive")!!)
                    val dest = File(call.argument<String>("dest")!!)
                    val destPath = dest.path
                    GameRuntime.installJre(this, archive, dest) { done, total ->
                        runOnUiThread {
                            runtimeChannel?.invokeMethod(
                                "jreProgress",
                                mapOf("dest" to destPath, "done" to done, "total" to total),
                            )
                        }
                    }
                    null
                }
                "launch" -> {
                    val intent = Intent(this, GameActivity::class.java)
                        .putExtra(GameActivity.EXTRA_JAVA_HOME, call.argument<String>("javaHome"))
                        .putExtra(GameActivity.EXTRA_GAME_DIR, call.argument<String>("gameDir"))
                        .putExtra(GameActivity.EXTRA_LOG_FILE, call.argument<String>("logFile"))
                        .putExtra(GameActivity.EXTRA_ARGS, call.argument<List<String>>("args")!!.toTypedArray())
                        .putExtra(GameActivity.EXTRA_SCALE, (call.argument<Double>("scale") ?: 1.0).toFloat())
                        .putExtra(GameActivity.EXTRA_INPUT_QUEUE, call.argument<Boolean>("inputQueue") ?: true)
                        .putExtra(GameActivity.EXTRA_FFP, call.argument<Boolean>("ffp") ?: false)
                        .putExtra(GameActivity.EXTRA_LWJGL, call.argument<String>("lwjgl") ?: GameRuntime.LWJGL_VERSION)
                        .putExtra(GameActivity.EXTRA_RENDERER, call.argument<String>("renderer") ?: GameRuntime.MOBILEGLUES)
                        .putExtra(GameActivity.EXTRA_TURNIP, call.argument<Boolean>("turnip") ?: false)
                        .putExtra(GameActivity.EXTRA_HUD, call.argument<Boolean>("hud") ?: true)
                        .putExtra(GameActivity.EXTRA_HUD_AI, call.argument<Boolean>("hudAi") ?: true)
                        .putExtra(GameActivity.EXTRA_HUD_AI_LOG, call.argument<Boolean>("hudAiLog") ?: true)
                        .putExtra(GameActivity.EXTRA_TOUCH_CONTROLLER, call.argument<Boolean>("touchController") ?: false)
                        .putExtra(GameActivity.EXTRA_INSTANCE, call.argument<String>("instance") ?: "")
                    GameRuntime.exitFile(this).delete()
                    startActivity(intent)
                    result.success(null)
                }
                // 回到正在运行的游戏（游戏界面是单独的任务）
                "resume" -> {
                    startActivity(Intent(this, GameActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                // 结束游戏进程（与启动器同一个用户，可以直接结束）
                "stop" -> {
                    val am = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
                    am.runningAppProcesses?.filter { it.processName == "$packageName:game" }?.forEach {
                        android.os.Process.killProcess(it.pid)
                    }
                    result.success(null)
                }
                "isRunning" -> {
                    val am = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
                    result.success(am.runningAppProcesses?.any { it.processName == "$packageName:game" } == true)
                }
                // 本应用（含游戏进程）自某个时间点以来的系统日志，用于排查游戏进程崩溃
                "logcat" -> background(result) {
                    val since = call.argument<Number>("since")!!.toLong()
                    val t = String.format(java.util.Locale.ROOT, "%d.%03d", since / 1000, since % 1000)
                    val p = ProcessBuilder("logcat", "-d", "-v", "threadtime", "-T", t).redirectErrorStream(true).start()
                    val text = p.inputStream.bufferedReader().readText()
                    p.waitFor()
                    if (text.length > 200_000) text.substring(text.length - 200_000) else text
                }
                // 无界面运行 jar（加载器安装器、OptiFine Patcher、用户选择的 jar）
                "runJar" -> {
                    if (jarConnection != null || processRunning("jar")) {
                        return@setMethodCallHandler result.error("runtime", "已有 jar 正在运行", null)
                    }
                    GameRuntime.jarExitFile(this).delete()
                    val intent = Intent(this, JarService::class.java)
                        .putExtra(JarService.EXTRA_JAVA_HOME, call.argument<String>("javaHome"))
                        .putExtra(JarService.EXTRA_WORK_DIR, call.argument<String>("workDir"))
                        .putExtra(JarService.EXTRA_LOG_FILE, call.argument<String>("logFile"))
                        .putExtra(JarService.EXTRA_ARGS, call.argument<List<String>>("args")!!.toTypedArray())
                    val conn = object : ServiceConnection {
                        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {}

                        override fun onServiceDisconnected(name: ComponentName?) {
                            // 进程已退出；解除绑定，避免系统重新创建服务再运行一次
                            unbindService(this)
                            if (jarConnection === this) jarConnection = null
                        }
                    }
                    if (!bindService(intent, conn, Context.BIND_AUTO_CREATE or Context.BIND_IMPORTANT)) {
                        return@setMethodCallHandler result.error("runtime", "无法启动 jar 运行进程", null)
                    }
                    jarConnection = conn
                    result.success(null)
                }
                "jarRunning" -> result.success(jarConnection != null || processRunning("jar"))
                "stopJar" -> {
                    val am = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
                    am.runningAppProcesses?.filter { it.processName == "$packageName:jar" }?.forEach {
                        android.os.Process.killProcess(it.pid)
                    }
                    result.success(null)
                }
                "jarExit" -> {
                    val f = GameRuntime.jarExitFile(this)
                    result.success(if (f.exists()) f.readText().also { f.delete() } else null)
                }
                "lastExit" -> {
                    val f = GameRuntime.exitFile(this)
                    result.success(if (f.exists()) f.readText().also { f.delete() } else null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installApk(apk: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("base.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val action = "$packageName.INSTALL_STATUS"
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                        // 需要用户在系统界面中确认安装
                        PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                            @Suppress("DEPRECATION")
                            val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                            if (confirm != null) startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        }
                        else -> runCatching { unregisterReceiver(this) }
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, IntentFilter(action), RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, IntentFilter(action))
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            val pending = PendingIntent.getBroadcast(this, id, Intent(action).setPackage(packageName), flags)
            session.commit(pending.intentSender)
        }
    }

    /** 在后台线程执行，完成后在主线程返回结果 */
    private fun background(result: MethodChannel.Result, job: () -> Any?) {
        thread {
            try {
                val value = job()
                runOnUiThread { result.success(value) }
            } catch (e: Throwable) {
                runOnUiThread { result.error("runtime", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun hasAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }

    private fun requestAccess(result: MethodChannel.Result) {
        if (hasAccess()) return result.success(true)
        pending?.success(false)
        pending = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11 起需要在系统设置里打开「所有文件访问权限」，回到应用时再检查
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQUEST_STORAGE,
            )
        }
    }

    override fun onResume() {
        super.onResume()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            pending?.success(hasAccess())
            pending = null
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_STORAGE) {
            pending?.success(hasAccess())
            pending = null
        }
    }

    companion object {
        private const val REQUEST_STORAGE = 1001
    }
}
