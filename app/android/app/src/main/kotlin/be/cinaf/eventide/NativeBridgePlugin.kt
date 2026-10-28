package be.cinaf.eventide

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Method channel be.cinaf.eventide/native, shared by the UI and the audio handler.
 *
 * It is registered on audio_service's cached FlutterEngine both by MainActivity (app opened by
 * the user) and by ScheduleAlarmReceiver (engine booted headless for a scheduled start), because
 * an engine created by the service never goes through MainActivity.configureFlutterEngine.
 */
class NativeBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        Notifications.ensureChannels(binding.applicationContext)
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
        instance = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        if (instance === this) instance = null
    }

    /** Tells Dart that the user tapped « Lancer » (app already running). */
    fun notifyLaunchSchedule(scheduleId: String) {
        channel?.invokeMethod("launchSchedule", scheduleId)
    }

    @SuppressLint("HardwareIds")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("detached", "Plugin is not attached", null)
            return
        }
        try {
            when (call.method) {
                "syncSchedules" -> {
                    val json = call.arguments as? String ?: "{}"
                    ScheduleStore.savePayload(ctx, json)
                    result.success(ScheduleStore.arm(ctx))
                }
                "canScheduleExactAlarms" -> result.success(ScheduleStore.canScheduleExactAlarms(ctx))
                "openExactAlarmSettings" -> result.success(openExactAlarmSettings(ctx))
                "consumePendingStart" ->
                    result.success(ScheduleStore.consumePendingStart(ctx, System.currentTimeMillis()))
                "androidId" -> result.success(
                    Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID) ?: "",
                )
                "requestIntegrityToken" -> requestIntegrityToken(ctx, call, result)
                "showNoConnectionNotification" -> result.success(Notifications.showNoConnection(ctx))
                "openBatteryOptimizationGuide" -> result.success(openAppDetails(ctx))
                "networkStatus" -> result.success(
                    mapOf(
                        "connected" to NetworkStatus.isConnected(ctx),
                        "unmetered" to NetworkStatus.isUnmetered(ctx),
                    ),
                )
                "cancelFallbackNotification" -> {
                    Notifications.cancelFallback(ctx)
                    result.success(null)
                }
                "isDemoBuild" -> result.success(BuildFlags.isDemoBuild(ctx))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message, null)
        }
    }

    private fun openExactAlarmSettings(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:" + ctx.packageName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            true
        } catch (e: Exception) {
            openAppDetails(ctx)
        }
    }

    /** Battery guide: Android has no standard screen for vendor killers, app details is the closest. */
    private fun openAppDetails(ctx: Context): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Play Integrity token bound to [nonce] (the request_hash of POST /installations).
     * With a cloud project number: standard request (`requestDetails.requestHash`, what the API
     * checks). Without one: classic request (`requestDetails.nonce`), for builds not yet linked.
     */
    private fun requestIntegrityToken(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        val nonce = call.argument<String>("nonce")
        if (nonce.isNullOrEmpty()) {
            result.error("invalid_nonce", "Missing nonce", null)
            return
        }
        val projectNumber = call.argument<String>("cloudProjectNumber")?.toLongOrNull()
        if (projectNumber != null) {
            IntegrityManagerFactory.createStandard(ctx)
                .prepareIntegrityToken(
                    PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(projectNumber).build(),
                )
                .addOnSuccessListener { provider ->
                    provider.request(StandardIntegrityTokenRequest.builder().setRequestHash(nonce).build())
                        .addOnSuccessListener { token -> result.success(token.token()) }
                        .addOnFailureListener { e -> result.error("integrity_unavailable", e.message, null) }
                }
                .addOnFailureListener { e -> result.error("integrity_unavailable", e.message, null) }
            return
        }
        IntegrityManagerFactory.create(ctx)
            .requestIntegrityToken(IntegrityTokenRequest.builder().setNonce(nonce).build())
            .addOnSuccessListener { response -> result.success(response.token()) }
            .addOnFailureListener { e -> result.error("integrity_unavailable", e.message, null) }
    }

    companion object {
        const val CHANNEL = "be.cinaf.eventide/native"

        /** The plugin attached to the running engine (set by onAttachedToEngine). */
        @Volatile
        var instance: NativeBridgePlugin? = null

        fun attachTo(engine: FlutterEngine) {
            if (!engine.plugins.has(NativeBridgePlugin::class.java)) {
                engine.plugins.add(NativeBridgePlugin())
            }
        }

        /** Creates (or reuses) audio_service's cached engine and registers this plugin on it. */
        fun warmUpEngine(context: Context) {
            try {
                attachTo(AudioServicePlugin.getFlutterEngine(context.applicationContext))
            } catch (e: Exception) {
                // The service will create the engine itself; Dart then falls back to a plain play().
            }
        }
    }
}
