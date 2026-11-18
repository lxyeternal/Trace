# Changelog

## Unreleased

- **Sessions notice when you leave**: forgetting to stop a session no longer spoils it. Away for under 15 minutes changes nothing; 15 minutes to 2 hours is left out and the session goes on; longer, or a Mac asleep for 30 minutes, ends the session at the moment you left. Trace says what it did and one click takes it back. Switch it off under Settings to let sessions run until you stop them.
- **Tag time afterwards**: forgot to start a session? Pick a period in the timeline and choose Count as…, or add a past session on the Focus page. Everything in that time counts as the tag.
- **Tags by app and site**: a new tag is set up by ticking apps installed on this Mac and typing sites, with a one-click pick for meeting apps and sites. Any tag, built-in or your own, can be renamed and given more apps and sites from its menu.
- **Menu bar**: starting a session unfolds inside the panel. The menu it used before closed by itself before a tag could be clicked.
- **Telegram**: time is shown per chat in Telegram for Mac. Switch it off under Settings › What is recorded. Thanks to David Ange.
- **Russian**: the whole app is available in Russian. Thanks to David Ange.

## 0.3.0

- **Faster**: switching between the timeline views no longer stalls. Tag rules are worked out once per record instead of on every redraw.
- **New look**: softer tag colours, lighter cards, quieter buttons and search fields, a translucent sidebar, and short animations when switching pages and views. The menu bar panel sits on the plain menu background.
- **Less small print**: the explanations next to section titles now show when the pointer rests on the title. Deleting a session asks first and says there what happens to its records.
- **Tags in the sidebar**: click a tag to open the timeline for that tag alone; click it again to show everything. The tag buttons now sit above every timeline view and include untagged time.
- **Guide**: five short pages after setup on what Trace does and where to look. Open it again from Help › Show the guide.
- **Chinese**: the lanes view is now called 轨迹.
- **License**: from this version Trace is released under GPL-3.0. Earlier versions remain under the MIT license.

## 0.2.1

- **All open apps**: besides the app in front, Trace now notes every app that is open while you are at the Mac and whether its window is on screen. The lanes view gets one lane per open app, solid while a window was on screen and faint while it was out of sight. It does not add to tracked time and can be switched off under Settings › What is recorded.
- **Menu bar panel**: redrawn to look like a system menu, on the translucent menu background with no frame around it. It now also lists what is on a call, playing sound, on screen and open out of sight, and says why when there is no current activity (Trace itself is in front, or no keyboard or mouse input).
- **Fixed**: clicking a button at the top of a page could nudge the window, because the buttons reached into the strip that drags the window. Pages now start below it.
- **Fixed**: with Trace's own window in front, the panel kept showing the previous app with a running clock although nothing was being recorded.

## 0.2.0

- **Lanes**: the day as a Gantt-style chart, one lane per tag or app, with sound, calls and each Mac underneath.
- **Sound and calls**: Trace notes which apps play sound or use the microphone, also in the background. While the app in front is making sound you are no longer counted as away.
- **Focus**: deep work time, app switches per hour and what interrupted you, on the overview. Each tag counts as focus, neutral or distraction.
- **Goals**: a daily target or limit per tag, shown as rings with streaks.
- **Sessions**: press Start and pick a tag; until you stop, everything counts as that tag. Open-ended or timed, from the new Focus page, the sidebar or the menu bar.
- **Being away**: a call, or sound from the app in front, keeps you counted as present; background sound can be made to count too. Away rows say what was playing.
- **Settings**: every installed app is listed with a switch to leave it out, most used first; the Sync pane shows clearly when the last sync finished and when the next is due.
- **Window and Dock**: closing the window leaves Trace recording in the menu bar without showing as running in the Dock; clicking the Dock icon or opening the app again always brings the window back. It quits only from the menu bar panel or with Command-Q.
- **Projects**: time per project, found from the folder each file is in.
- **Review**: a few sentences on each week and month compared with the one before.
- **Year calendar**: one square per day; click a day to open it.
- **Sync folder** (optional, off by default): keep several Macs in step, or keep a backup, through any folder that is synced for you, such as iCloud Drive. Each Mac writes its own records and reads the others'; tags and rules are shared. A menu in the sidebar shows all Macs together or one at a time. Macs can be named, reports show time per Mac, and simultaneous use on two Macs is drawn side by side.
- **Wider built-in tags**: about 180 more common apps and sites are recognised out of the box, including QQ, WeCom, DingTalk, Feishu, Tencent Meeting, NetEase Cloud Music, JetBrains IDEs, Zotero, Obsidian, Notion and Adobe apps. Existing installs receive the additions once.

## 0.1.0

First public release.

- **Automatic recording** of the frontmost app, window title, document path and page address, every two seconds, merged into one record per stay. Time away from the keyboard and mouse is left out.
- **Overview** of the day: total time, share by tag, time per hour, a two-lane timeline and the most used apps.
- **Timeline** that expands tag › app › file or site › page, with the day laid out top to bottom. Click a session or drag across a period to sum up only that part of the day.
- **Records** view that lists every stay, grouped into sessions, with an inspector for the selected record.
- **Tags**: eight built-in tags that work without setup, custom tags, rules on app, app category, file path, URL or window title, and tagging single records by hand.
- **Reports** by week, month and year, with active hours, top sites and top files, and CSV export.
- **Privacy controls**: turn off window titles, file paths or web addresses, exclude apps, pause recording, erase all records. All data stays in a local SQLite file.
- Light and dark appearance, English and Simplified Chinese, a menu bar panel, launch at login.
- Universal build for Apple silicon and Intel, signed with Developer ID and notarized by Apple. Requires macOS 14 or later.
