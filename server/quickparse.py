"""Russian quick-add parser: free text -> Planner item.

    "завтра 18:00 занятие"             event tomorrow at 18:00
    "в пятницу с 10 до 11:30 созвон"   event on the next Friday, 10:00-11:30
    "25.09 в 9 стоматолог"             event on 25 Sep at 09:00
    "18:00 2 недели занятие"           weekly series, 2 occurrences
    "купить хлеб"                      task on the default day
    "18:00 занятие // взять тетрадь"   everything after // becomes the description

Time: "18:00", "в 18", "в 18:30", "с 10 до 11", "10:00-11:30"; "18.00" only at the very
start (dots elsewhere are dates). Date: сегодня / завтра / послезавтра, weekday names
("в пт", "во вторник"; the same weekday means next week), "через N дней/недель",
"25.09", "25.09.2027", "25 сентября". A time makes it an event, otherwise a task.
"""

import re
from datetime import date, timedelta

WEEKDAYS = {
    0: ("пн", "понедельник", "понедельника"),
    1: ("вт", "вторник", "вторника"),
    2: ("ср", "среда", "среду", "среды"),
    3: ("чт", "четверг", "четверга"),
    4: ("пт", "пятница", "пятницу", "пятницы"),
    5: ("сб", "суббота", "субботу", "субботы"),
    6: ("вс", "воскресенье", "воскресенья"),
}
MONTHS = ("январ", "феврал", "март", "апрел", "ма", "июн", "июл", "август", "сентябр", "октябр", "ноябр", "декабр")

H = r"([01]?\d|2[0-3])"
M = r"([0-5]\d)"
B = r"(?<![\w:.])"  # left word boundary that also rejects "1" inside "12:30"
E = r"(?![\w:])"


def _cut(text, match):
    return (text[:match.start()] + " " + text[match.end():]).strip()


def _hm(h, m):
    return "%02d:%s" % (int(h), m or "00")


def parse(text, default_date=None, today=None):
    """Returns {"kind", "title", "date", "start_time", "end_time", "repeat"} (None fields omitted)."""
    today = today or date.today()
    day = date.fromisoformat(default_date) if default_date else today
    text, _, body = text.partition("//")
    body = body.strip()
    t = " " + " ".join(text.split()) + " "
    start = end = None
    repeat = None

    # --- time -----------------------------------------------------------------
    m = re.search(B + r"(с\s+)?" + H + r"(?::" + M + r")?\s*(?:-|–|до)\s*" + H + r"(?::" + M + r")?" + E, t, re.I)
    # "2-3 яблока" is not a time range: require minutes somewhere or a leading "с".
    if m and (m.group(1) or m.group(3) or m.group(5)):
        start, end = _hm(m.group(2), m.group(3)), _hm(m.group(4), m.group(5))
        t = " " + _cut(t, m) + " "
    else:
        m = re.search(B + H + ":" + M + E, t) or re.search(r"^\s*" + H + r"\." + M + E, t)
        if m:
            start = _hm(m.group(1), m.group(2))
            t = " " + _cut(t, m) + " "
        else:
            m = re.search(r"(?:^|\s)(?:в|к)\s+" + H + r"(?:\s*ч(?:ас(?:а|ов)?)?\.?)?" + E, t, re.I)
            if m:
                start = _hm(m.group(1), None)
                t = " " + _cut(t, m) + " "

    # --- repeat: "2 недели", "3 месяца" ------------------------------------------
    # "через 2 недели" is a date, not a repeat
    m = re.search(r"(?:^|(?<!через)\s)(\d{1,2})\s*(недел[яиьюe]?|нед\.?|месяц(?:а|ев)?|мес\.?)(?=\s|$)", t, re.I)
    if m and int(m.group(1)) > 1:
        repeat = {"unit": "week" if m.group(2).lower().startswith("нед") else "month", "count": int(m.group(1))}
        t = " " + _cut(t, m) + " "

    # --- date -----------------------------------------------------------------
    words = {"сегодня": 0, "завтра": 1, "послезавтра": 2}
    m = re.search(r"(?:^|\s)(сегодня|послезавтра|завтра)(?=\s|$)", t, re.I)
    if m:
        day = today + timedelta(days=words[m.group(1).lower()])
        t = " " + _cut(t, m) + " "
    else:
        m = re.search(r"(?:^|\s)через\s+(\d{1,3}\s+)?(день|дня|дней|неделю|недели|недель)(?=\s|$)", t, re.I)
        if m:
            n = int(m.group(1)) if m.group(1) else 1
            day = today + timedelta(days=n * (7 if m.group(2).lower().startswith("недел") else 1))
            t = " " + _cut(t, m) + " "
        else:
            m = re.search(r"(?<![\w.])(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?(?![\w.:])", t)
            if m and 1 <= int(m.group(2)) <= 12 and 1 <= int(m.group(1)) <= 31:
                year = int(m.group(3)) if m.group(3) else today.year
                year += 2000 if year < 100 else 0
                try:
                    day = date(year, int(m.group(2)), int(m.group(1)))
                    if not m.group(3) and day < today:
                        day = day.replace(year=year + 1)
                    t = " " + _cut(t, m) + " "
                except ValueError:
                    pass
            else:
                m = re.search(r"(?:^|\s)(\d{1,2})\s+(" + "|".join(MONTHS) + r")[а-я]*(?=\s|$)", t, re.I)
                if m:
                    month = next(i + 1 for i, p in enumerate(MONTHS) if m.group(2).lower().startswith(p))
                    try:
                        day = date(today.year, month, int(m.group(1)))
                        if day < today:
                            day = day.replace(year=today.year + 1)
                        t = " " + _cut(t, m) + " "
                    except ValueError:
                        pass
                else:
                    for wd, names in WEEKDAYS.items():
                        m = re.search(r"(?:^|\s)(?:во?\s+)?(" + "|".join(sorted(names, key=len, reverse=True)) + r")\.?(?=\s|$)", t, re.I)
                        if m:
                            ahead = (wd - today.weekday()) % 7 or 7
                            day = today + timedelta(days=ahead)
                            t = " " + _cut(t, m) + " "
                            break

    title = " ".join(t.split())
    title = re.sub(r"^(в|во|на|с)\s+(?=\S)", "", title, flags=re.I) if len(title.split()) > 1 else title
    title = re.sub(r"\s+(в|во|на|с)$", "", title, flags=re.I)
    title = title[:1].upper() + title[1:] if title else title

    item = {"kind": "event" if start else "task", "title": title, "date": day.isoformat()}
    if body:
        item["body"] = body
    if start:
        item["start_time"] = start
        if end and end > start:
            item["end_time"] = end
        item["remind"] = 15
    if repeat and start:
        item["repeat"] = repeat
    return item


def describe(item):
    """Short human summary: "пт 18 сент · 18:00–19:30 · Занятие · 2 недели"."""
    d = date.fromisoformat(item["date"])
    wd = ("пн", "вт", "ср", "чт", "пт", "сб", "вс")[d.weekday()]
    mon = ("янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сент", "окт", "нояб", "дек")[d.month - 1]
    parts = ["%s %d %s" % (wd, d.day, mon)]
    if item.get("start_time"):
        parts.append(item["start_time"] + ("–" + item["end_time"] if item.get("end_time") else ""))
    parts.append(item["title"] or "—")
    if item.get("body"):
        parts.append("+ пояснение")
    rep = item.get("repeat")
    if rep:
        parts.append("%d %s" % (rep["count"], "нед." if rep["unit"] == "week" else "мес."))
    return " · ".join(parts)
