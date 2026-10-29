package be.cinaf.eventide

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Method channel be.cinaf.eventide/device (lib/services/diagnostics.dart,
 * lib/services/wallpaper_service.dart): problem report (process exits recorded by Android,
 * phone model), the media card's launch intent, and the landscape wallpaper. Registered with
 * NativeBridgePlugin on the shared engine (app opened by the user or booted by a scheduled
 * start).
 */
class DevicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private var io: ExecutorService? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        io = Executors.newSingleThreadExecutor()
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        io?.shutdown()
        io = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("detached", "Plugin is not attached", null)
            return
        }
        try {
            when (call.method) {
                "takeExitReasons" -> inBackground(result) { ExitReports.takeNew(ctx) }
                "deviceDetails" -> result.success(ExitReports.deviceDetails(ctx))
                "installMediaSessionActivity" -> result.success(MediaSessionLaunch.install(ctx))
                "wallpaperSupport" -> result.success(
                    mapOf(
                        "live" to LiveWallpaper.isSupported(ctx),
                        "gallery" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
                    ),
                )
                "wallpaperSelection" -> result.success(WallpaperStore.read(ctx)?.landscapeId)
                "setLiveWallpaper" -> {
                    val id = call.argument<String>("landscape_id")
                    if (id.isNullOrEmpty()) {
                        result.error("invalid_landscape", "Missing landscape id", null)
                        return
                    }
                    val selection = WallpaperSelection(
                        landscapeId = id,
                        name = call.argument<String>("name") ?: "",
                        videoPath = call.argument<String>("video"),
                        posterPath = call.argument<String>("poster"),
                        allowed = call.argument<Boolean>("allowed") ?: true,
                    )
                    result.success(LiveWallpaper.select(ctx, selection))
                }
                "setWallpaperAllowed" -> {
                    WallpaperStore.setAllowed(ctx, call.arguments == true)
                    result.success(true)
                }
                "saveVideoToGallery" -> {
                    val path = call.argument<String>("path")
                    val title = call.argument<String>("title") ?: "Eventide"
                    if (path.isNullOrEmpty()) {
                        result.success(false)
                        return
                    }
                    inBackground(result) { GallerySaver.saveVideo(ctx, path, title) }
                }
                "clearWallpaper" -> {
                    WallpaperStore.clear(ctx)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message, null)
        }
    }

    /** File and MediaStore work off the main thread; the answer goes back on it. */
    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        val executor = io
        if (executor == null) {
            result.error("detached", "Plugin is not attached", null)
            return
        }
        try {
            executor.execute {
                var value: Any? = null
                var failure: Exception? = null
                try {
                    value = work()
                } catch (e: Exception) {
                    failure = e
                }
                main.post {
                    val error = failure
                    if (error == null) result.success(value) else result.error("native_error", error.message, null)
                }
            }
        } catch (e: RejectedExecutionException) {
            result.error("detached", "Plugin is not attached", null)
        }
    }

    companion object {
        const val CHANNEL = "be.cinaf.eventide/device"
    }
}
