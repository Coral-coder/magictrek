package com.lightwave.openmtg

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The in-app updater: version info and launching the package installer for a
        // downloaded APK (see lib/app/updater.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "magictrek/updater").setMethodCallHandler { call, result ->
            when (call.method) {
                // Which runtime permissions Bluetooth needs depends on the Android version.
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "version" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                    result.success(mapOf("name" to (info.versionName ?: ""), "code" to code))
                }
                // Whether an APK on disk is signed with the same key as the installed app: Android
                // refuses to install an update signed differently.
                "sameSigner" -> {
                    val path = call.argument<String>("path")
                    if (path == null) { result.error("args", "path missing", null); return@setMethodCallHandler }
                    try {
                        result.success(signers(path) == signers(null))
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) { result.error("args", "path missing", null); return@setMethodCallHandler }
                    try {
                        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The signing certificates of an APK file, or of this app when [path] is null. */
    private fun signers(path: String?): List<String> {
        val pm = packageManager
        val certs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val flags = PackageManager.GET_SIGNING_CERTIFICATES
            val info = if (path == null) pm.getPackageInfo(packageName, flags) else pm.getPackageArchiveInfo(path, flags)
            info?.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory }
        } else {
            @Suppress("DEPRECATION")
            val flags = PackageManager.GET_SIGNATURES
            @Suppress("DEPRECATION")
            val info = if (path == null) pm.getPackageInfo(packageName, flags) else pm.getPackageArchiveInfo(path, flags)
            @Suppress("DEPRECATION")
            info?.signatures
        }
        return (certs ?: emptyArray()).map { it.toCharsString() }.sorted()
    }
}
