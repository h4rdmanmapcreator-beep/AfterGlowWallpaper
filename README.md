# Afterglow

A live wallpaper for macOS that reacts to whatever your Mac is playing, and keeps a calm ambient animation going when there's no sound. Designed with OLED screens in mind.

## Features

- **Reacts to system audio** using Core Audio process taps (macOS 14.2+). No BlackHole or other virtual driver needed, and it works at any volume.
- **Ambient mode**: when the music stops it fades into a slower, dimmer version of the same style instead of freezing.
- **Eight styles**:
  - Halo: spectrum ring with beat shockwaves
  - Contours: stacked lines pushed up by the music
  - Starfield: multicolored stars on pure black
  - Equalizer: mirrored bars with falling peak caps
  - Oscilloscope: the live waveform as a thin glowing trace
  - Black Hole: a huge pure-black horizon wrapped in streaky lensed rings of orbiting gas,
    three sizes (small, medium, or huge and parked on the right edge so only its left side shows),
    stars circling it that streak only when they move fast, a dense rotating starfield bent by its lens, and
    colourless spacetime waves that warp everything on standout hits (up to five a second) (wider when the hit is held)
  - Gradients: soft colour fields drifting across black, each one swelling with its part of the spectrum
  - Neon Grid: retro-futuristic floor, slit sun and a skyline driven by the spectrum
- **Eight color themes**: Spectrum (cycling), Sunset, Cyberpunk, Nature, Ocean, Ice, Ember, Violet.
- Up to 144 fps, at full rate even when silent (optional 30 fps power saver). Every style renders a 2560×1440 frame in well under 7 ms on an M4.
- Lives in the menu bar; sits at desktop level under your icons and windows; clicks pass straight through.
- Works on every connected display.

## OLED care

- Background is true black (`0,0,0`), so unused pixels stay fully off.
- The whole image drifts slowly, colors cycle, and styles rotate every 8 minutes (optional), so nothing stays on the same pixels.
- Soft tone-mapping keeps colors saturated and never clips to white.
- Pause shows pure black, never a frozen frame.
- Stops rendering when the wallpaper is covered, the display sleeps or the Mac is locked.

## Build

Only the Xcode Command Line Tools are needed; shaders are compiled at launch.

```bash
./build.sh            # builds build/Afterglow.app
./build.sh install    # builds and copies it to /Applications
```

On first launch macOS asks for **System Audio Recording** permission. Without it, only the ambient animation runs.

Tip: set your regular macOS wallpaper to plain black so the screen stays dark before Afterglow starts.

## Preview

Render every style (ambient and with simulated music) to PNGs without touching the desktop:

```bash
./Tools/preview.sh              # writes build/preview/*.png
THEME=5 ./Tools/preview.sh      # same, in a specific color theme (ids in Sources/Settings.swift)
```

## Project layout

| Path | What it does |
| --- | --- |
| `Sources/AudioCapture.swift` | System audio tap + aggregate device |
| `Sources/AudioAnalyzer.swift` | FFT, 64 log bands, auto-gain, beat and silence detection |
| `Sources/Engine.swift` | Shared state: drift, color cycling, style transitions |
| `Sources/Renderer.swift` | Metal renderer and the desktop-level window |
| `Sources/AppDelegate.swift` | Menu bar, multi-display, sleep/lock/occlusion handling |
| `Resources/Shaders.metal` | All visual styles |

Requires macOS 14.2 or later on Apple silicon.
