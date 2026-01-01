# Squeeze!

_A reliable way to **shrink large videos** on your phone._  
Select one or more **video albums**, or simply **select all**, then let Squeeze! run in the background. Pause or resume anytime. See clear progress per album.

- **Space saver**: re-encodes videos using efficient codecs to free up GBs.
- **Album-based selection**: choose exactly which video albums to compress — selecting all albums is treated as “compress everything”.
- **Safe by design**: you decide whether to **keep originals** (with a suffix) or **replace** them to reclaim space.

---

## Why would I want this?

Phones fill up quickly — especially with 4K or high–frame-rate videos. Squeeze! converts those videos into smaller sizes while keeping good visual quality, so you can free up storage without manually hunting through your gallery.

For very large videos, compression can take **many hours or even days**. That’s expected. Squeeze! is built to work reliably in the background and resume if interrupted.

---

## Install / Build

This is a Flutter app targeting **Android**.

**Prerequisites**
- Flutter SDK (3.5+)
- Android SDK + Android Studio
- Java 17 (recommended)
- A real Android device or emulator

**Run in debug**
```bash
flutter pub get
flutter run
```

---

## Quick Start (2 minutes)

1) **Choose albums**
   - Select one or more video albums.
   - Use **Select all albums** to compress everything on your device.

2) **Set options**
   - **Keep original files**  
     - ON → compressed copies are saved with a suffix (e.g. `_compressed`)
     - OFF → originals are replaced after compression (to save space)

3) **Grant permissions**
   - Allow access to your videos when prompted.
   - Allow notifications so progress can be shown while running.

4) **Start**
   - Tap **Start compression**.
   - You can **Pause** or **Resume** at any time from the Status tab.

If your phone stops background work to save power, simply **open the app again** — progress is saved.

---

## Core concepts

### Album-based workflow
Squeeze! uses Android’s media system to discover video albums. This is more reliable and privacy-friendly than raw filesystem scanning.

### Two safe workflows
- **Keep originals**  
  Compressed files are saved with a suffix; originals remain untouched.
- **Replace originals**  
  Originals are replaced only after successful compression. Old files can be cleared later from inside the app.

### Background-friendly
Compression runs under a foreground notification. If the system pauses the app, reopening it continues where it left off.

---

## Everyday workflows

### Free space everywhere
- Tap **Select all albums**
- Disable **Keep original files**
- Start compression and leave the phone plugged in

### Free space in a specific album
- Select only the album (e.g. Camera)
- Disable **Keep original files** for maximum space savings

### Play it safe first
- Enable **Keep original files**
- Set a suffix like `_small`
- Compare results, then clear old files later if you’re satisfied

---

## Permissions (Android)

- **Media access**: required to read and write videos through Android’s media library
- **Notifications**: used to show progress and status while compressing

---

## Important notes

- **Time**: Large or very many videos can take many hours or days — this is normal.
- **Battery & heat**: Video encoding is intensive. Plugging in your phone is recommended; slight warmth is expected..
- **Background limits**: some devices kill long-running work on low battery or strict power modes. If work stops, **reopen the app** to resume.
- **Free space**: keep extra storage available for temporary files during conversion.
- **Local only**: Videos never leave your device.

---

## Troubleshooting

- **Start button disabled**
  - Select at least one album
  - If keeping originals, set a suffix

- **Compression stopped**
  - Reopen the app to resume
  - Check battery optimization settings

- **Low storage warning**
  - Clear old files from the Status tab

---

## Contributing

Issues and pull requests are welcome. Please include:
- Device model
- Android version
- Steps to reproduce
- Logs if available

---

## Privacy

Squeeze! processes videos **only on your device**. No analytics or uploads by default. See the [`Privacy Policy`](./privacy.md) in this repo.

---

## License

GPLv3 — see [`LICENSE`](./LICENSE).
