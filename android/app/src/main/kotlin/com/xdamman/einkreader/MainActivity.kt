package com.xdamman.einkreader

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Delivers text shared to the app ("Share → einkreader") to Dart. A cold
    // start is pulled by Dart via getInitialSharedText; a share into the
    // already-running app (onNewIntent, launchMode=singleTop) is pushed.
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "einkreader/share"
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialSharedText" -> {
                        result.success(sharedTextFrom(intent))
                        // Consume it so recents relaunches don't re-share.
                        intent?.removeExtra(Intent.EXTRA_TEXT)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val text = sharedTextFrom(intent) ?: return
        channel?.invokeMethod("sharedText", text)
    }

    private fun sharedTextFrom(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/") != true) return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)
    }
}
