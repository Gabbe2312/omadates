# iCalendar

The Omarchy clock, with your calendar in it.

Days that have something on them carry a dot in the calendar popup, coloured
by which calendar it belongs to. Today's events sit under the month grid, and
clicking one opens it up: when it ends, where it is, and whatever notes came
with the invitation. The popup grows a line per event rather than scrolling a
fixed box.

Works with **iCloud**, any **CalDAV** server (Fastmail, Nextcloud, Radicale),
and **webcal subscriptions** — the holiday and timetable feeds your phone
carries but iCloud never stores.

![Screenshot](preview.png)

## Install

```bash
omarchy pkg add python-caldav python-icalendar python-recurring-ical-events python-httpx libsecret
omarchy plugin add https://github.com/Gabbe2312/omarchy-icalendar.git --enable
```

The packages are separate because a plugin cannot install system packages for
you. If you skip them, the panel tells you exactly which line to run.

Then replace the stock clock with this one:

```bash
omarchy bar remove omarchy.clock
omarchy bar move io.github.gabbe2312.calendar --section center
```

## Signing in

Open the clock in the bar and fill in the two fields.

You need an **app-specific password**, not your normal Apple password. Apple
offers no browser sign-in for calendar access, and CalDAV has nowhere to type
a two-factor code, so this is the supported way in. Create one at
**account.apple.com → Sign-In and Security → App-Specific Passwords**. You can
revoke it there at any time without touching anything else.

The password goes into your login keyring via `secret-tool`. It is never
written to a config file, never passed as a command-line argument, and reaches
the sync helper on stdin.

## Subscribed calendars

iCloud does not store `webcal://` subscriptions — your phone keeps only the
URL and fetches the feed itself — so they have to be added here too. Press the
`+` at the end of the calendar row and paste the URL.

Find it on iPhone under **Settings → Apps → Calendar → Accounts → Subscribed
Calendars**, or on a Mac in Calendar under **File → Get Info**.

## Using it

| | |
|---|---|
| Click a day | Show that day's events |
| Click an event | Open its details |
| Click a calendar | Hide or show it |
| Right-click a calendar | Rename it, or pick its colour |
| `+` | Subscribe to a feed |
| Scroll / `[` `]` | Previous and next month |
| `{` `}` | Previous and next year |
| `t` | Back to today |
| `w` | Switch which day the week starts on |

Renaming and recolouring are display choices, stored next to the widget in
`shell.json`. A sync never overwrites them, and the calendar's original name
stays its identity underneath.

Everything the stock Omarchy clock does — the label formats on right-click,
the year bar, the timezone picker, memento mori — is still there.

## How it syncs

The shell never touches the network. A helper writes
`~/.cache/omarchy/icalendar/events.json`, and the panel watches that one file
and redraws. So the popup opens instantly, and it still shows the last good
answer when you are offline.

The helper runs every 15 minutes from inside the shell, and again when you
open the panel if the cache has gone stale. No system timer to install.

## Configuration

`~/.config/omarchy/icalendar/config.json`:

| Key | Meaning |
|---|---|
| `url` | CalDAV endpoint. Defaults to iCloud; point it at any server. |
| `username` | Your account. Set by signing in. |
| `daysBack` / `daysAhead` | How much of the calendar to keep cached. |
| `calendars` | Only fetch these calendar names. Empty means all of them. |
| `subscriptions` | Feed URLs, managed by the `+` button. |

The helper is also a small CLI, if you would rather script it:

```bash
bin/icalendar-sync            # refresh now
bin/icalendar-sync check      # report missing packages
bin/icalendar-sync subscribe <url>
bin/icalendar-sync logout
```

## Removing it

```bash
omarchy plugin remove io.github.gabbe2312.calendar
rm -rf ~/.config/omarchy/icalendar ~/.cache/omarchy/icalendar
secret-tool clear service io.github.gabbe2312.calendar
```

## Credits

The clock, month grid and week numbering are Omarchy's own, MIT-licensed and
lightly reshaped to make room for events. See `LICENSE`.

Plugins run unsandboxed, as arbitrary code inside your shell process. Read
what you install — this one included.
