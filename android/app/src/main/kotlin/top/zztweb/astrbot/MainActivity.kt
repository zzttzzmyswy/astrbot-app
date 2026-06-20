package top.zztweb.astrbot

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val installChannel = "top.zztweb.astrbot/install"
    private val deviceChannel = "top.zztweb.astrbot/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("invalid_arg", "缺少 path", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(path)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getOemInfo" -> result.success(getOemInfo())
                    "openAppLaunchSettings" -> result.success(openAppLaunchSettings())
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String) {
        val file = File(path)
        val authority = "${packageName}.fileprovider"
        val uri: Uri = FileProvider.getUriForFile(this, authority, file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /** 返回厂商信息(用于判定是否需要引导用户开启后台白名单)。 */
    private fun getOemInfo(): Map<String, Any> {
        val manufacturer = Build.MANUFACTURER ?: ""
        val brand = Build.BRAND ?: ""
        val pm = packageManager
        val hasPowerGenie = try {
            pm.getPackageInfo("com.hihonor.powergenie", 0); true
        } catch (e: Exception) {
            try {
                pm.getPackageInfo("com.huawei.powergenie", 0); true
            } catch (e2: Exception) { false }
        }
        return mapOf(
            "manufacturer" to manufacturer,
            "brand" to brand,
            "hasPowerGenie" to hasPowerGenie
        )
    }

    /**
     * 打开「应用启动管理 / 后台活动」设置,供用户为本应用开启后台白名单。
     * 优先尝试荣耀/华为的电源管理 Activity;失败回退到本应用的系统详情页(用户可
     * 从中进入 电池→应用启动管理)。
     * @return 是否成功打开了某个设置页。
     */
    private fun openAppLaunchSettings(): Boolean {
        val targets = listOf(
            // 荣耀 MagicOS:电源管理(应用启动管理)Activity
            ComponentName(
                "com.hihonor.powergenie",
                "com.hihonor.powergenie.ui.AppLaunchActivity"
            ),
            // 华为 EMUI:启动管理
            ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
            )
        )
        val pm = packageManager
        for (target in targets) {
            try {
                val intent = Intent().apply {
                    component = target
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                if (intent.resolveActivity(pm) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (e: Exception) {
                // 该机型无此 Activity,尝试下一个。
            }
        }
        // 回退:打开本应用系统详情页(用户可从「电池」进入应用启动管理)。
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
