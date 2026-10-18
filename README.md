# LiveWall

Use any video as your Mac's desktop wallpaper. Free and open source: one small Swift file, no dependencies.

macOS has no built-in way to use your own video as a live wallpaper, and the free apps I tried kept freezing. LiveWall does one thing: it loops a video behind your desktop icons, and stops completely whenever nobody can see it.

## Features

- Any `.mp4`, `.mov` or `.m4v`, chosen from the menu bar
- A different video on each display, or one video on all of them
- Fill the screen (crops the edges) or fit it (black bars)
- Sits behind your desktop icons on every Space and never gets in the way of clicks
- Stops playing, using no CPU, when:
  - windows or a full-screen app cover the desktop
  - the displays or the Mac go to sleep, or the screen locks
  - Low Power Mode is on, or the Mac is running hot
  - the Mac is on battery (optional)
- Starts at login (you can turn this off)
- No Dock icon, no settings window, no network access, no analytics

## Install

1. Download `LiveWall.zip` from the [latest release](../../releases/latest), unzip it, and drag **LiveWall** into Applications.
2. Open it. macOS will say it can't verify the developer, because LiveWall isn't signed with a paid Apple Developer ID. Click **Done**, then open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   Or in Terminal: `xattr -dr com.apple.quarantine /Applications/LiveWall.app`
3. Choose a video. LiveWall lives in the menu bar as a ▶︎ icon.

Requires macOS 13 Ventura or later, on Apple Silicon or Intel.

### Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

    git clone https://github.com/KevinXu-github/LiveWall.git
    cd LiveWall
    bash build.sh

This compiles `LiveWall.swift`, ad-hoc signs the app, installs it to `/Applications`, and launches it. If a `wallpaper.mp4` (or `.mov` / `.m4v`) is next to `build.sh`, it's bundled as the default video.

`bash build.sh --release` builds for both Apple Silicon and Intel and writes `dist/LiveWall.zip` instead of installing.

## Menu

| Item | What it does |
|---|---|
| Pause / Resume | Stops or restarts playback. The line under it says why it's paused, if it is. |
| Choose Video… | Sets the video for all displays. LiveWall remembers it, even if you move or rename the file. |
| *Display name* → Choose Video… | With more than one display, sets a video for just that display. |
| Scaling | Fill Screen or Fit to Screen. |
| Pause on Battery | Stops playback whenever the Mac is unplugged. |
| Start at Login | On by default after the first launch. |

## Battery and performance

About 2% CPU on an M4 MacBook Air while the desktop is visible, and about 0% when it's covered. Videos play on the Mac's hardware video decoder. Displays that show the same video share one player, so a second display costs almost nothing extra.

A video's size matters more than anything else: 1080p at 30 fps uses less power than 4K at 60 fps. HEVC (H.265) and H.264 are both decoded in hardware.

## Uninstall

Turn off **Start at Login** in the menu, quit LiveWall, and move it to the Trash. To also clear its settings:

    defaults delete io.github.kevinxu-github.livewall

## Limitations

- Desktop only. The lock screen, login window and Mission Control still show your regular wallpaper. Setting a still frame from your video as your regular wallpaper makes the switch less noticeable.
- No sound, on purpose.

## Contributing

Issues and pull requests are welcome. The project aims to stay one file with no dependencies, and to use no CPU when the wallpaper isn't visible.

## License

[MIT](LICENSE)
