package be.cinaf.eventide

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.support.v4.media.session.MediaSessionCompat
import android.util.Log
import com.ryanheise.audioservice.AudioService

/**
 * What a tap on the media card opens (lock screen, Now Bar, notification shade, Always On
 * Display): the app, after One UI has asked to unlock (docs/app/architecture.md § 15.3).
 *
 * audio_service 0.18.19 gives the session a launch intent only inside enterPlayingState(), right
 * AFTER mediaSession.setActive(true) (AudioService.java:705-711), so a system controller that
 * reads MediaController.getSessionActivity() when the session appears gets null (there is no
 * callback for a later change). That intent is also built only when config.activityClassName
 * is known (AudioService.java:396-409), which a headless start (scheduled start booting the
 * engine without any activity) cannot provide on a fresh install; it has no
 * FLAG_ACTIVITY_NEW_TASK and, on Android 14+, no creator opt-in to start an activity from the
 * background.
 *
 * Here: the activity class is always recorded in audio_service's preferences before its service
 * can start, and our own PendingIntent is put on the session as soon as the service exists
 * (before its first activation), and in audio_service's static content intent, so that every
 * later enterPlayingState() and every notification it builds carry it.
 */
object MediaSessionLaunch {
    private const val TAG = "EventideMediaCard"

    /** Distinct from audio_service's own request code (1000) and from Notifications (4301, 4302). */
    private const val REQUEST_OPEN_FROM_MEDIA = 4303

    /** audio_service's AudioServiceConfig preferences (stable in 0.18.x). */
    private const val AUDIO_SERVICE_PREFS = "audio_service_preferences"
    private const val KEY_ACTIVITY_CLASS_NAME = "activityClassName"

    /** Records MainActivity as the activity to open, before any start of audio_service's service. */
    fun ensureActivityClassName(context: Context) {
        try {
            val prefs = context.applicationContext.getSharedPreferences(AUDIO_SERVICE_PREFS, Context.MODE_PRIVATE)
            val name = MainActivity::class.java.name
            if (prefs.getString(KEY_ACTIVITY_CLASS_NAME, null) != name) {
                prefs.edit().putString(KEY_ACTIVITY_CLASS_NAME, name).apply()
            }
        } catch (e: Exception) {
            Log.w(TAG, "activity class not recorded: $e")
        }
    }

    /** Opens (or brings back) the app's task, like the launcher icon. */
    fun launchIntent(context: Context): Intent =
        Intent(context, MainActivity::class.java)
            .setAction(AudioService.NOTIFICATION_CLICK_ACTION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    fun pendingIntent(context: Context): PendingIntent {
        val app = context.applicationContext
        return PendingIntent.getActivity(
            app,
            REQUEST_OPEN_FROM_MEDIA,
            launchIntent(app),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            creatorOptions(),
        )
    }

    /**
     * Android 14+: the creator lends its right to start an activity to whoever sends the
     * PendingIntent (System UI, after the unlock); Android 15+ no longer does it by default for
     * apps targeting API 35 and above.
     */
    @Suppress("DEPRECATION") // MODE_BACKGROUND_ACTIVITY_START_ALLOWED: deprecated in API 36, still honoured.
    private fun creatorOptions(): Bundle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        return ActivityOptions.makeBasic()
            .setPendingIntentCreatorBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
            .toBundle()
    }

    /**
     * Puts our launch intent on audio_service's media session and in its static content
     * intent. Returns false when the service does not exist yet (called again later: app start
     * after AudioService.init, activity resumed or stopped). Main thread only.
     */
    fun install(context: Context): Boolean {
        val service = audioService() ?: return false
        val pending = pendingIntent(context)
        var installed = false
        try {
            val field = AudioService::class.java.getDeclaredField("contentIntent")
            field.isAccessible = true
            field.set(null, pending)
            installed = true
        } catch (e: Exception) {
            Log.w(TAG, "audio_service content intent not replaced: $e")
        }
        try {
            val field = AudioService::class.java.getDeclaredField("mediaSession")
            field.isAccessible = true
            val session = field.get(service) as? MediaSessionCompat
            if (session != null) {
                session.setSessionActivity(pending)
                installed = true
            }
        } catch (e: Exception) {
            Log.w(TAG, "session activity not set: $e")
        }
        Log.i(TAG, "media card opens the app: installed=$installed")
        return installed
    }

    private fun audioService(): AudioService? =
        try {
            val field = AudioService::class.java.getDeclaredField("instance")
            field.isAccessible = true
            field.get(null) as? AudioService
        } catch (e: Exception) {
            Log.w(TAG, "audio_service instance not found: $e")
            null
        }
}
