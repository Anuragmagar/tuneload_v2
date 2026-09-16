package com.tuneload.app.widget

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import com.ryanheise.audioservice.MediaButtonReceiver

class MusicWidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            MusicWidgetProvider.ACTION_PREVIOUS -> {
                dispatchMediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            }

            MusicWidgetProvider.ACTION_NEXT -> {
                dispatchMediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT)
            }

            MusicWidgetProvider.ACTION_PLAY_PAUSE -> {
                val prefs = context.getSharedPreferences("music_widget_prefs", Context.MODE_PRIVATE)
                val isPlaying = prefs.getBoolean("is_playing", false)
                dispatchMediaButton(
                    context,
                    if (isPlaying) KeyEvent.KEYCODE_MEDIA_PAUSE else KeyEvent.KEYCODE_MEDIA_PLAY
                )
            }
        }

        MusicWidgetProvider.updateAllWidgets(context)
    }

    private fun dispatchMediaButton(context: Context, keyCode: Int) {
        sendMediaButton(context, KeyEvent.ACTION_DOWN, keyCode)
        sendMediaButton(context, KeyEvent.ACTION_UP, keyCode)
    }

    private fun sendMediaButton(context: Context, action: Int, keyCode: Int) {
        val keyEvent = KeyEvent(action, keyCode)
        val mediaIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            component = ComponentName(context, MediaButtonReceiver::class.java)
            putExtra(Intent.EXTRA_KEY_EVENT, keyEvent)
        }
        context.sendBroadcast(mediaIntent)
    }
}
