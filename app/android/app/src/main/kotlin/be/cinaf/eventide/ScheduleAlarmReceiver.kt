package be.cinaf.eventide

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.KeyEvent
import androidx.core.content.ContextCompat

/**
 * Fired by AlarmManager at a scheduled start. Dart computes nothing here: this receiver records
 * the pending schedule, starts audio_service's foreground service with a MEDIA_PLAY key event
 * (this boots the Flutter engine headless if needed and calls the AudioHandler's click/play),
 * falls back to a « Lancer » notification when Android refuses the start, then re-arms the next
 * occurrence.
 */
class ScheduleAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ScheduleStore.ACTION_FIRE) return
        val app = context.applicationContext
        val now = System.currentTimeMillis()
        val armedAt = ScheduleStore.armedAtMillis(app)
        val scheduleId = ScheduleStore.armedScheduleId(app)
        Log.i(TAG, "alarm fired: schedule=$scheduleId late_ms=${if (armedAt > 0L) now - armedAt else -1L}")
        try {
            val schedule = scheduleId?.let { ScheduleStore.find(app, it) }
            if (schedule == null) {
                Log.i(TAG, "no stored schedule for this alarm, nothing to start")
                return
            }
            if (!schedule.active) {
                Log.i(TAG, "schedule ${schedule.id} is switched off, nothing to start")
                return
            }
            // Phone off or deep Doze for a long time: never start sound in the middle of the night.
            if (ScheduleStore.isTooLate(armedAt, now)) {
                Log.i(TAG, "alarm delivered more than an hour late, skipped")
                return
            }
            ScheduleStore.setPendingStart(app, schedule.id, now)
            if (ScheduleStore.requiresNetwork(app) && !NetworkStatus.isConnected(app)) {
                // Free tier needs a connection: notify instead of playing (dossier, screen 9).
                ScheduleStore.clearPendingStart(app)
                val posted = Notifications.showNoConnection(app)
                Log.i(TAG, "free plan without network: no-connection notification posted=$posted")
                return
            }
            if (startPlayback(app)) {
                Log.i(TAG, "foreground media service start requested for schedule ${schedule.id}")
            } else {
                // The pending start stays recorded: « Lancer » opens the app, which starts it.
                val posted = Notifications.showScheduleFallback(app, schedule)
                Log.i(TAG, "foreground service start refused: fallback « Lancer » notification posted=$posted")
            }
        } finally {
            ScheduleStore.rearmAfterFire(app, if (armedAt > 0L) armedAt else now)
        }
    }

    private fun startPlayback(context: Context): Boolean {
        // Headless start: no activity tells audio_service what its media card opens.
        MediaSessionLaunch.ensureActivityClassName(context)
        val keyEvent = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY)
        val serviceIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
            .setClassName(context, AUDIO_SERVICE_CLASS)
            .putExtra(Intent.EXTRA_KEY_EVENT, keyEvent)
        return try {
            ContextCompat.startForegroundService(context, serviceIntent)
            // Create (or reuse) audio_service's cached engine now, on the main thread, so that our
            // method channel is registered before Dart's main() calls consumePendingStart().
            NativeBridgePlugin.warmUpEngine(context)
            true
        } catch (e: IllegalStateException) {
            // Includes ForegroundServiceStartNotAllowedException (Android 12+), a subclass.
            Log.w(TAG, "startForegroundService refused: $e")
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "startForegroundService refused: $e")
            false
        }
    }

    companion object {
        const val AUDIO_SERVICE_CLASS = "com.ryanheise.audioservice.AudioService"

        /** Log tag of scheduled starts (also used by the Dart handler; read by the CI emulator check). */
        const val TAG = "EventideSchedule"
    }
}
