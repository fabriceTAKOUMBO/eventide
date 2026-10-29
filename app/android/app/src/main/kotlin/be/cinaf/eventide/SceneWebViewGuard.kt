package be.cinaf.eventide

import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Build
import android.os.Message
import android.util.Log
import android.view.KeyEvent
import android.view.ViewGroup
import android.webkit.ClientCertRequest
import android.webkit.HttpAuthHandler
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

/**
 * Renderer guard of the WebView that runs the 3D scenes of « Imaginaire »
 * (lib/ui/landscape/imaginaire_surface.dart, docs/app/architecture.md § 19).
 *
 * webview_flutter_android's WebViewClient does not override onRenderProcessGone: when the
 * WebView's renderer process crashes, or Android kills it to reclaim memory, Android then kills
 * the whole app. This wraps the plugin's client in [GuardedClient], which forwards every callback
 * the plugin implements (so webview_flutter's NavigationDelegate keeps working) and answers
 * onRenderProcessGone with true: the app lives on, the dead WebView is taken out of the view
 * hierarchy and destroyed (it must never be used again), and Dart is told (it shows the scene's
 * poster).
 *
 * Android 8+ only (WebView.getWebViewClient, onRenderProcessGone): on Android 7 the scene stays
 * a poster (Dart is answered false).
 */
object SceneWebViewGuard {
    private const val TAG = "EventideScene"

    /** Wraps the client of the WebView [identifier]; false when it cannot be guarded. */
    fun install(binding: FlutterPlugin.FlutterPluginBinding, identifier: Long, onGone: (Boolean) -> Unit): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return installO(binding, identifier, onGone)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun installO(binding: FlutterPlugin.FlutterPluginBinding, identifier: Long, onGone: (Boolean) -> Unit): Boolean {
        val webView = WebViewFlutterAndroidExternalApi.getWebView(binding, identifier) ?: return false
        val inner = webView.webViewClient
        if (inner is GuardedClient) return true
        webView.webViewClient = GuardedClient(inner, onGone)
        return true
    }

    /** Forwards to [inner]; handles the loss of the renderer instead of letting the app die. */
    private class GuardedClient(
        private val inner: WebViewClient,
        private val onGone: (Boolean) -> Unit,
    ) : WebViewClient() {
        @RequiresApi(Build.VERSION_CODES.O)
        override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
            val crashed = detail?.didCrash() ?: true
            Log.w(TAG, "scene renderer gone: crashed=$crashed")
            try {
                (view?.parent as? ViewGroup)?.removeView(view)
                view?.destroy()
            } catch (e: Exception) {
                Log.w(TAG, "dead WebView not released cleanly: ${e.message}")
            }
            onGone(crashed)
            return true
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) =
            inner.onPageStarted(view, url, favicon)

        override fun onPageFinished(view: WebView?, url: String?) = inner.onPageFinished(view, url)

        override fun onReceivedHttpError(view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?) =
            inner.onReceivedHttpError(view, request, errorResponse)

        override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) =
            inner.onReceivedError(view, request, error)

        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean =
            inner.shouldOverrideUrlLoading(view, request)

        override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) =
            inner.doUpdateVisitedHistory(view, url, isReload)

        override fun onReceivedHttpAuthRequest(view: WebView?, handler: HttpAuthHandler?, host: String?, realm: String?) =
            inner.onReceivedHttpAuthRequest(view, handler, host, realm)

        override fun onFormResubmission(view: WebView?, dontResend: Message?, resend: Message?) =
            inner.onFormResubmission(view, dontResend, resend)

        override fun onLoadResource(view: WebView?, url: String?) = inner.onLoadResource(view, url)

        override fun onPageCommitVisible(view: WebView?, url: String?) = inner.onPageCommitVisible(view, url)

        override fun onReceivedClientCertRequest(view: WebView?, request: ClientCertRequest?) =
            inner.onReceivedClientCertRequest(view, request)

        override fun onReceivedLoginRequest(view: WebView?, realm: String?, account: String?, args: String?) =
            inner.onReceivedLoginRequest(view, realm, account, args)

        override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) =
            inner.onReceivedSslError(view, handler, error)

        override fun onScaleChanged(view: WebView?, oldScale: Float, newScale: Float) =
            inner.onScaleChanged(view, oldScale, newScale)

        override fun onUnhandledKeyEvent(view: WebView?, event: KeyEvent?) = inner.onUnhandledKeyEvent(view, event)
    }
}
