package be.cinaf.eventide

import android.app.WallpaperManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.IOException

/** The landscape shown by the live wallpaper (docs/app/architecture.md « Fond d'écran vidéo »). */
data class WallpaperSelection(
    val landscapeId: String,
    val name: String,
    /** Looping video in the app's storage, or null (still picture only). */
    val videoPath: String?,
    /** Still picture (the loop's frame 0), or null (plain background). */
    val posterPath: String?,
    /** False once the plan no longer allows the landscape: still picture only. */
    val allowed: Boolean,
)

/**
 * The selection, as a small JSON file outside the media folder (`files/wallpaper_selection.json`):
 * written by the app's process, read by the wallpaper's own process (`:wallpaper`) each time the
 * wallpaper becomes visible. SharedPreferences are not shared between processes.
 */
object WallpaperStore {
    private const val TAG = "EventideWallpaper"
    private const val FILE_NAME = "wallpaper_selection.json"

    private fun file(context: Context) = File(context.filesDir, FILE_NAME)

    fun read(context: Context): WallpaperSelection? {
        val file = file(context)
        if (!file.isFile) return null
        return try {
            val json = JSONObject(file.readText())
            WallpaperSelection(
                landscapeId = json.getString("landscape_id"),
                name = json.optString("name", ""),
                videoPath = optPath(json, "video"),
                posterPath = optPath(json, "poster"),
                allowed = json.optBoolean("allowed", true),
            )
        } catch (e: Exception) {
            Log.w(TAG, "selection unreadable: $e")
            null
        }
    }

    private fun optPath(json: JSONObject, key: String): String? {
        if (!json.has(key) || json.isNull(key)) return null
        val value = json.optString(key, "")
        return value.ifEmpty { null }
    }

    fun write(context: Context, selection: WallpaperSelection) {
        val json = JSONObject()
            .put("landscape_id", selection.landscapeId)
            .put("name", selection.name)
            .put("video", selection.videoPath ?: JSONObject.NULL)
            .put("poster", selection.posterPath ?: JSONObject.NULL)
            .put("allowed", selection.allowed)
        val target = file(context)
        val tmp = File(target.parentFile, "$FILE_NAME.part")
        tmp.writeText(json.toString())
        if (!tmp.renameTo(target)) {
            target.writeText(json.toString())
            tmp.delete()
        }
    }

    fun setAllowed(context: Context, allowed: Boolean) {
        val current = read(context) ?: return
        if (current.allowed != allowed) write(context, current.copy(allowed = allowed))
    }

    fun clear(context: Context) {
        file(context).delete()
    }

    /** Only files of the app itself are ever played, drawn or copied. */
    fun isInsideAppData(context: Context, file: File): Boolean =
        try {
            val root = File(context.applicationInfo.dataDir).canonicalPath + File.separator
            file.canonicalPath.startsWith(root)
        } catch (e: IOException) {
            false
        }

    /** A readable file of the app, or null. */
    fun usableFile(context: Context, path: String?): File? {
        if (path.isNullOrEmpty()) return null
        val file = File(path)
        return if (file.isFile && file.length() > 0L && isInsideAppData(context, file)) file else null
    }
}

/** Opens Android's preview of our live wallpaper (the user confirms there). */
object LiveWallpaper {
    fun isSupported(context: Context): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_LIVE_WALLPAPER)

    /** "opened", "unsupported" or "failed". */
    fun select(context: Context, selection: WallpaperSelection): String {
        if (!isSupported(context)) return "unsupported"
        val safe = selection.copy(
            videoPath = WallpaperStore.usableFile(context, selection.videoPath)?.path,
            posterPath = WallpaperStore.usableFile(context, selection.posterPath)?.path,
        )
        if (safe.videoPath == null && safe.posterPath == null) return "failed"
        try {
            WallpaperStore.write(context, safe)
        } catch (e: Exception) {
            Log.w("EventideWallpaper", "selection not written: $e")
            return "failed"
        }
        val component = ComponentName(context, LandscapeWallpaperService::class.java)
        val preview = Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER)
            .putExtra(WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT, component)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (start(context, preview)) return "opened"
        // Some launchers only offer the list of live wallpapers.
        val chooser = Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return if (start(context, chooser)) "opened" else "unsupported"
    }

    private fun start(context: Context, intent: Intent): Boolean =
        try {
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            false
        }
}
