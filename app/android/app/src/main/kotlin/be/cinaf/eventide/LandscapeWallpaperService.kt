package be.cinaf.eventide

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.util.Log
import android.view.SurfaceHolder
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import java.io.File
import kotlin.math.max

/**
 * Live wallpaper (docs/app/architecture.md « Fond d'écran vidéo »): the chosen landscape's
 * looping video, muted (no audio track is even decoded), looping without a gap
 * (REPEAT_MODE_ALL), centre-cropped to the screen by the decoder. Battery: paused as soon as the
 * wallpaper is not visible (an app on top, screen off), its decoder released after
 * [RELEASE_HIDDEN_MS] hidden, everything released when the surface goes.
 *
 * Still picture (the loop's frame 0, centre-cropped) when the video file is missing, cannot be
 * decoded, or the plan no longer allows the landscape. A surface drawn with a Canvas cannot take
 * a video decoder any more (Android keeps it connected to the CPU): the video comes back with the
 * next surface (Android's preview, a restart, or the wallpaper set again).
 *
 * Runs in its own process (`:wallpaper`): it lives as long as the wallpaper is set, without the
 * app and without its Flutter engine; a fault here never stops the sound.
 */
@SuppressLint("UnsafeOptInUsageError") // media3 setVideoScalingMode: stable in practice.
class LandscapeWallpaperService : WallpaperService() {
    override fun onCreateEngine(): Engine = LandscapeEngine()

    private inner class LandscapeEngine : Engine() {
        private val handler = Handler(Looper.getMainLooper())
        private var player: ExoPlayer? = null
        private var playerPath: String? = null
        private var selection: WallpaperSelection? = null
        private var visible = false
        private var surfaceReady = false
        private var drawnWithCanvas = false
        private var videoFailed = false
        private var resumeAtMs = 0L
        private var stillRetries = 0
        private val releaseWhenHidden = Runnable { releasePlayer(keepPosition = true) }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            setTouchEventsEnabled(false)
        }

        override fun onSurfaceCreated(holder: SurfaceHolder) {
            super.onSurfaceCreated(holder)
            surfaceReady = true
            drawnWithCanvas = false
            videoFailed = false
            resumeAtMs = 0L
            refresh()
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            super.onSurfaceChanged(holder, format, width, height)
            // The decoder crops to the new size itself; a still picture is drawn again.
            if (player == null) refresh()
        }

        override fun onVisibilityChanged(visible: Boolean) {
            super.onVisibilityChanged(visible)
            this.visible = visible
            handler.removeCallbacks(releaseWhenHidden)
            if (visible) {
                refresh()
            } else {
                player?.pause()
                handler.postDelayed(releaseWhenHidden, RELEASE_HIDDEN_MS)
            }
        }

        override fun onSurfaceDestroyed(holder: SurfaceHolder) {
            surfaceReady = false
            handler.removeCallbacksAndMessages(null)
            releasePlayer(keepPosition = false)
            super.onSurfaceDestroyed(holder)
        }

        override fun onDestroy() {
            handler.removeCallbacksAndMessages(null)
            releasePlayer(keepPosition = false)
            super.onDestroy()
        }

        /** Shows what the selection asks for: the video (playing only when visible) or the still picture. */
        private fun refresh() {
            if (!surfaceReady) return
            val latest = WallpaperStore.read(applicationContext)
            if (latest != selection) {
                selection = latest
                videoFailed = false
                stillRetries = 0
            }
            val current = selection
            val video = if (current != null && current.allowed) {
                WallpaperStore.usableFile(applicationContext, current.videoPath)
            } else {
                null
            }
            if (video != null && !drawnWithCanvas && !videoFailed) {
                val p = player?.takeIf { playerPath == video.path } ?: createPlayer(video)
                if (visible) p.play() else p.pause()
            } else {
                releasePlayer(keepPosition = false)
                drawStill()
            }
        }

        private fun createPlayer(video: File): ExoPlayer {
            releasePlayer(keepPosition = false)
            val p = ExoPlayer.Builder(applicationContext).build()
            p.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING)
            p.trackSelectionParameters = p.trackSelectionParameters
                .buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
                .build()
            p.volume = 0f
            p.repeatMode = Player.REPEAT_MODE_ALL
            p.addListener(
                object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) {
                        Log.w(TAG, "video cannot play: ${error.errorCodeName}")
                        videoFailed = true
                        handler.post {
                            releasePlayer(keepPosition = false)
                            drawStill()
                        }
                    }
                },
            )
            p.setVideoSurface(surfaceHolder.surface)
            p.setMediaItem(MediaItem.fromUri(Uri.fromFile(video)))
            if (resumeAtMs > 0L) p.seekTo(resumeAtMs)
            p.prepare()
            player = p
            playerPath = video.path
            return p
        }

        private fun releasePlayer(keepPosition: Boolean) {
            val p = player ?: return
            resumeAtMs = if (keepPosition) p.currentPosition else 0L
            player = null
            playerPath = null
            try {
                p.release()
            } catch (e: Exception) {
                Log.w(TAG, "release failed: $e")
            }
        }

        /** The still picture, centre-cropped, on the app's dark background. */
        private fun drawStill() {
            if (!surfaceReady) return
            val holder = surfaceHolder
            val canvas: Canvas? = try {
                holder.lockCanvas()
            } catch (e: Exception) {
                null
            }
            if (canvas == null) {
                // The decoder may still hold the surface for a moment after its release.
                if (stillRetries++ < 3) handler.postDelayed({ if (player == null) drawStill() }, 300L)
                return
            }
            drawnWithCanvas = true
            try {
                canvas.drawColor(BACKGROUND)
                val bitmap = loadStill(canvas.width, canvas.height)
                if (bitmap != null) {
                    drawCentreCrop(canvas, bitmap)
                    bitmap.recycle()
                }
            } catch (e: Exception) {
                Log.w(TAG, "still picture not drawn: $e")
            } finally {
                try {
                    holder.unlockCanvasAndPost(canvas)
                } catch (e: Exception) {
                    Log.w(TAG, "unlockCanvasAndPost failed: $e")
                }
            }
        }

        private fun loadStill(width: Int, height: Int): Bitmap? {
            val file = WallpaperStore.usableFile(applicationContext, selection?.posterPath) ?: return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= width && bounds.outHeight / (sample * 2) >= height) sample *= 2
            return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
        }

        private fun drawCentreCrop(canvas: Canvas, bitmap: Bitmap) {
            val scale = max(canvas.width / bitmap.width.toFloat(), canvas.height / bitmap.height.toFloat())
            val w = canvas.width / scale
            val h = canvas.height / scale
            val left = (bitmap.width - w) / 2f
            val top = (bitmap.height - h) / 2f
            val src = Rect(left.toInt(), top.toInt(), (left + w).toInt(), (top + h).toInt())
            canvas.drawBitmap(bitmap, src, Rect(0, 0, canvas.width, canvas.height), Paint(Paint.FILTER_BITMAP_FLAG))
        }
    }

    companion object {
        private const val TAG = "EventideWallpaper"

        /** Hidden this long: the decoder is released (it comes back, at the same point, when visible). */
        private const val RELEASE_HIDDEN_MS = 15_000L

        /** VitreColors.ink, the app's own background. */
        private val BACKGROUND = Color.rgb(0x0A, 0x0F, 0x0D)
    }
}
