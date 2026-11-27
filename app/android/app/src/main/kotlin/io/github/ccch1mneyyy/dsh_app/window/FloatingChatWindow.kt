package io.github.ccch1mneyyy.dsh_app.window

import android.app.ActivityOptions
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Parcel
import android.os.Parcelable
import android.util.Log
import android.view.WindowInsets
import android.view.WindowManager

/** 复用主 Activity 和已有 FlutterEngine；不另开一套会话状态。 */
object FloatingChatWindow {
    const val EXTRA_REQUEST = "dsh_floating_chat"
    private const val TAG = "FloatingChatWindow"
    private const val WINDOWING_MODE = "android.activity.windowingMode"
    private const val FREEFORM = 5

    fun start(context: Context, intent: Intent, launchOptions: Bundle? = options(context)) {
        try {
            context.startActivity(intent, launchOptions)
        } catch (e: RuntimeException) {
            if (launchOptions == null) throw e
            // 部分 ROM 声明支持 freeform，却拒绝第三方传入窗口参数；仍允许正常打开。
            Log.w(TAG, "Freeform launch rejected; opening normally", e)
            context.startActivity(intent)
        }
    }

    fun options(context: Context): Bundle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            !context.packageManager.hasSystemFeature(PackageManager.FEATURE_FREEFORM_WINDOW_MANAGEMENT)) return null
        val metrics = context.getSystemService(WindowManager::class.java).maximumWindowMetrics
        val area = Rect(metrics.bounds)
        area.inset(metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()))
        val margin = (12 * context.resources.displayMetrics.density).toInt()
        val placement = FloatingChatPlacement.inArea(area.width(), area.height(), margin)
        val bounds = Rect(placement.left, placement.top, placement.right, placement.bottom)
        bounds.offset(area.left, area.top)
        return ActivityOptions.makeBasic().setLaunchBounds(bounds).toBundle().apply {
            // Android 只公开了窗口位置，没有公开窗口模式 setter。此键来自系统 ActivityOptions，
            // 仅在声明支持 freeform 的设备上传递；系统忽略它时自然以全屏打开。
            putInt(WINDOWING_MODE, FREEFORM)
            configureMiuiFreeform(this)
        }
    }

    @Suppress("DEPRECATION")
    private fun configureMiuiFreeform(options: Bundle) {
        val key = "miui:activity.options.injector"
        val injector = options.getParcelable<Parcelable>(key) ?: return
        if (injector.javaClass.name != "android.app.ActivityOptions\$ActivityOptionsInjector") return
        // 与小米 MiuiMultiWindowUtils.getActivityOptions 一致：显式小窗启动标记为 2，
        // 与默认标记 1 合并。仅窗口模式和 bounds 不构成完整的 OEM 小窗请求。
        val config = "key_miui_config_flag"
        options.putInt(config, options.getInt(config, 1) or 2)
        val parcel = Parcel.obtain()
        try {
            // 小米会在 launchBounds 外再缩放一次，导致窗口偏离右下角、实际尺寸缩水。
            // 该 OEM Parcelable 的首字段是 scale（默认 -1）；保留其余字段，只固定为 1。
            // 通过系统自己的 CREATOR 还原，不解除整个进程的隐藏 API 限制。
            parcel.writeParcelable(injector, 0)
            parcel.setDataPosition(0)
            parcel.readString()
            parcel.writeFloat(1f)
            parcel.setDataPosition(0)
            options.putParcelable(key, parcel.readParcelable<Parcelable>(injector.javaClass.classLoader))
        } catch (e: RuntimeException) {
            // 其他版本若改变此扩展的序列化格式，保留系统默认缩放，不影响打开对话。
            Log.w(TAG, "OEM scale unavailable; retaining system scale", e)
        } finally {
            parcel.recycle()
        }
    }
}

internal data class FloatingChatPlacement(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    companion object {
        fun inArea(width: Int, height: Int, margin: Int): FloatingChatPlacement {
            val gap = margin.coerceIn(0, minOf(width, height) / 4)
            val right = width - gap
            val bottom = height - gap
            val windowWidth = (width * 0.75f).toInt().coerceAtMost(width - 2 * gap)
            val windowHeight = (height * 0.60f).toInt().coerceAtMost(height - 2 * gap)
            return FloatingChatPlacement(right - windowWidth, bottom - windowHeight, right, bottom)
        }
    }
}
