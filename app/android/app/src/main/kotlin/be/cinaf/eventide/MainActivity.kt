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
        super.onCreate(savedInstanceState)
        handleLaunchIntent(intent)
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
