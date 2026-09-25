# NotMiss — AI Voice Guide

An AI-powered voice guide for walking tours. The app tracks your GPS location and automatically narrates stories about nearby points of interest through your headphones.

**Current destination:** Stryiskyi Park (Стрийський парк), Lviv, Ukraine

---

## Setup

### 1. Install Flutter

```bash
# macOS (Apple Silicon)
brew install --cask flutter

# Or download manually:
# https://docs.flutter.dev/get-started/install/macos
```

After installation, run `flutter doctor` and follow any prompts (accept Android licenses, install Xcode command-line tools, etc.).

### 2. Get a Gemini API Key

1. Go to [https://aistudio.google.com/apikey](https://aistudio.google.com/apikey)
2. Sign in with your Google account
3. Click **Create API key**
4. Copy the key

### 3. Configure the API Key

Create a `.env` file in the project root (next to `pubspec.yaml`):

```bash
# /Users/vladv/NotMiss/notmiss/.env
GEMINI_API_KEY=your_actual_key_here
```

> ⚠️ The `.env` file is gitignored — never commit your API key.

### 4. Install dependencies

```bash
cd /Users/vladv/NotMiss/notmiss
flutter pub get
```

### 5. iOS setup (if running on iPhone/iOS Simulator)

```bash
cd ios && pod install && cd ..
```

Also add location permissions to `ios/Runner/Info.plist` (already done in this project).

### 6. Run the app

```bash
# List available devices
flutter devices

# Run on a specific device (e.g. iPhone Simulator)
flutter run

# Run on a physical device
flutter run -d <device-id>
```

---

## Architecture

```
lib/
├── models/          # Pure data: Destination, POI
├── data/            # JSON assets (POI datasets)
├── services/
│   ├── location_service.dart      # GPS stream
│   ├── poi_engine.dart            # Distance calc + trigger logic
│   ├── content_service.dart       # Retrieve narration text
│   ├── ai_service.dart            # Gemini API: facts → narration
│   ├── tts_service.dart           # Gemini TTS: text → audio bytes
│   └── audio_player_service.dart  # Play/stop audio
└── ui/
    ├── screens/
    │   ├── home_screen.dart        # Map + Start Walk
    │   └── walk_screen.dart        # Active walk HUD
    └── widgets/
        └── poi_marker.dart         # Map POI dot
```

## Milestones

| # | Status | Feature |
|---|--------|---------|
| M1 | ✅ | Mobile shell: map, GPS, Start/Stop Walk |
| M2 | ✅ | POI detection: proximity, trigger, dedup |
| M3 | ✅ | Audio: TTS + playback |
| M4 | ✅ | AI narration from facts via Gemini |
| M5 | ⬜ | Conversational Q&A |
| M6 | ⬜ | Field test in Stryiskyi Park |
| M7 | ⬜ | Background location |

## Testing without GPS (Simulator)

In the iOS Simulator, use **Features → Location → Custom Location** to set a fake GPS coordinate inside Stryiskyi Park:

- Latitude: `49.8282`
- Longitude: `24.0218`

Then slowly change the location to approach a POI and verify the trigger fires.

## Adding a New Destination

1. Create `assets/data/your_destination.json` following the same schema as `stryiskyi_park.json`
2. Add it to `pubspec.yaml` assets
3. Load it in `main.dart` alongside Stryiskyi Park
