package dev.arco.planner

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject
import java.time.LocalDate

/** "Сегодня" home-screen widget. Data ("days" JSON, 7 days ahead) is written by lib/widget_bridge.dart. */
class TodayWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val today = LocalDate.now().toString()
        val day = runCatching { JSONObject(widgetData.getString("days", "{}")!!).optJSONObject(today) }.getOrNull()
        val items = day?.optJSONArray("items")

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            views.setTextViewText(R.id.date_label, day?.optString("label") ?: "открой Planner")
            views.setOnClickPendingIntent(
                R.id.header,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("planner://open")),
            )
            views.setOnClickPendingIntent(
                R.id.add,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("planner://add")),
            )

            val count = items?.length() ?: 0
            for (i in 0 until ROWS.size) {
                val (row, mark, title) = ROWS[i]
                if (i >= count) {
                    views.setViewVisibility(row, View.GONE)
                    continue
                }
                val it = items!!.getJSONObject(i)
                val isTask = it.optString("kind") == "task"
                val done = it.optBoolean("done")
                views.setViewVisibility(row, View.VISIBLE)
                views.setTextViewText(mark, if (isTask) (if (done) "☑" else "☐") else it.optString("time").ifEmpty { "день" })
                views.setTextViewText(title, it.optString("title"))
                views.setTextColor(title, if (done) 0xFFA08C87.toInt() else 0xFFF1DFDA.toInt())
                views.setOnClickPendingIntent(
                    row,
                    if (isTask) {
                        HomeWidgetBackgroundIntent.getBroadcast(
                            context,
                            Uri.parse("planner://toggle?id=" + Uri.encode(it.optString("id"))),
                        )
                    } else {
                        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("planner://open"))
                    },
                )
            }
            views.setViewVisibility(R.id.empty, if (count == 0) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.more, if (count > ROWS.size) View.VISIBLE else View.GONE)
            views.setTextViewText(R.id.more, "ещё ${count - ROWS.size}")
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    companion object {
        private val ROWS = listOf(
            Triple(R.id.row_0, R.id.mark_0, R.id.title_0),
            Triple(R.id.row_1, R.id.mark_1, R.id.title_1),
            Triple(R.id.row_2, R.id.mark_2, R.id.title_2),
            Triple(R.id.row_3, R.id.mark_3, R.id.title_3),
            Triple(R.id.row_4, R.id.mark_4, R.id.title_4),
            Triple(R.id.row_5, R.id.mark_5, R.id.title_5),
        )
    }
}
