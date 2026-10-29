package be.cinaf.eventide

import android.content.Intent
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * AudioServiceActivity shares audio_service's cached FlutterEngine between the UI and the
 * media service, so the UI and the AudioHandler live in the same Dart isolate.
 */
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativeBridgePlugin.attachTo(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before audio_service's service can start: the media card always knows what to open.
        MediaSessionLaunch.ensureActivityClassName(this)
        super.onCreate(savedInstanceState)
        handleLaunchIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        MediaSessionLaunch.install(this)
    }

    override fun onStop() {
        // Leaving for the lock screen or another app: the media card must open the app again.
        MediaSessionLaunch.install(this)
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLaunchIntent(intent)
    }

    /** « Lancer » on the fallback notification: record a fresh pending start for Dart. */
    private fun handleLaunchIntent(intent: Intent?) {
        if (intent == null || intent.action != Notifications.ACTION_LAUNCH_SCHEDULE) return
        val scheduleId = intent.getStringExtra(Notifications.EXTRA_SCHEDULE_ID) ?: return
        ScheduleStore.setPendingStart(applicationContext, scheduleId, System.currentTimeMillis())
        Notifications.cancelFallback(applicationContext)
        // Consume the action so that a configuration change does not start it twice.
        intent.action = Intent.ACTION_MAIN
        NativeBridgePlugin.instance?.notifyLaunchSchedule(scheduleId)
    }
}
