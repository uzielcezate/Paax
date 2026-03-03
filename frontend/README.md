# Beaty 🎵

A premium, open-source music streaming application built with Flutter. Beaty offers a polished, dark-themed UI with a focus on aesthetics and user experience, powered by the Deezer API.

## ✨ Features

- **Beautiful UI/UX**: Round aesthetics, glassmorphism, and dynamic gradients.
- **Discover Music**: Browse trending charts, top albums, and search for any track, album, or artist.
- **Smart Player**: 
  - Mini-player for seamless navigation.
  - Full-screen immersive player with dynamic background blur.
  - Audio playback with `just_audio`.
- **Local Library**: 
  - Save your favorite songs (Liked Tracks).
  - Create and manage custom Playlists.
  - Save Albums for quick access.
  - All data persisted locally using **Hive**.
- **Search**: Powerful search with category filters (Tracks, Albums, Artists).
- **Onboarding**: Smooth introduction flow.
- **Authentication**: Mock auth system with persistence.

## 📱 Screenshots

| Home | Player | Library |
|------|--------|---------|
| ![Home](screenshot_home.png) | ![Player](screenshot_player.png) | ![Library](screenshot_library.png) |

## 🛠 Tech Stack & Architecture

- **Framework**: Flutter (Dart)
- **State Management**: `Provider` (ChangeNotifiers for Logic separation).
- **Architecture**: Clean Architecture (Core, Data, Domain, Presentation).
- **Networking**: `http` + **Deezer Public API**.
- **Persistence**: `Hive` (NoSQL local database).
- **Audio**: `just_audio`.
- **UI**: Custom widgets, `GoogleFonts` (Outfit), `CachedNetworkImage`.

### Folder Structure
```
lib/
├── core/            # Theme, Constants, Utils
├── data/            # API Clients, Models, Repositories, Local Storage
├── domain/          # Entities
└── presentation/    # Screens, Widgets, State Controllers
```

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (3.x+)
- Dart (3.x+)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/beaty.git
   cd beaty
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Generate Hive Adapters** (if modifying models)
   ```bash
   flutter pub run build_runner build
   ```

4. **Run the app**
   ```bash
   flutter run
   ```

## ⚠️ Note
This application uses the **Deezer Public API** which provides 30-second audio previews for tracks. Full playback requires Deezer OAuth/SDK which is not included in this MVP version to keep it token-free.

## 📝 License
MIT License.
