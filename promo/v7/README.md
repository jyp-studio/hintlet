# Hintlet promo music, version 7

This folder holds the soundtrack for the 44-second Hintlet demo video, and the code that makes it. The track runs at 120 BPM in D major, so each bar lasts exactly 2 seconds. Every scene change in the video lands on a bar line, at 4, 8, 10, 12, 14, 22, 28, 34 and 40 seconds, which meant the picture didn't need any changes.

All of the sound is generated from scratch in Python with numpy, in `music-v7.py`. The instruments are a soft felt piano, a marimba, glass bells, a sub bass, a warm pad and an "ooh" choir, plus drums built from sine sweeps and filtered noise. No samples, loops, recordings or existing songs are used.

## How the music follows the app

Hintlet moves notes out of your way and puts them back when you need them. The music does the same thing. When the video switches to another app, the music sounds muffled, as if it were in the next room. When someone types near a note, the band gets thinner and quieter so the typing stays in front. When the note returns, the music returns on the same beat.

A short three-note theme (A, D, F#) plays only three times: at the start, when the note comes back at 12 seconds, and at the end. Keeping it rare gives the last one more weight.

## Cue sheet

Times are in seconds. Music and interface sounds are listed separately because they are delivered as separate tracks.

| Time | On screen | Music | Interface sounds |
| --- | --- | --- | --- |
| 0 to 4 | Logo and name | A low piano note and a pad from the first frame. The piano plays the theme, and its last note lands as the tagline appears at 1.0 | |
| 4.0 | First desktop | The band comes in | |
| 5.0 | ⌘⌥N opens a note | A single bell | |
| 5.35 to 6.85 | Typing into the note | | Key clicks |
| 8.0 to 9.5 | The window is dragged | | A soft whoosh |
| 10.0 to 12.0 | Finder in front, note hidden | The band is muffled (low-passed at 320 Hz) and only the kick keeps time | A whoosh, then a click at 11.92 |
| 12.0 | The note comes back | The full band returns with the theme | |
| 14 to 20.2 | Typing in TextEdit | A slow piano line, one note per second (D, B, C#, A, B, G) | Key clicks, and a low thud for the Return key at 19.0 |
| 15.42 | The note fades to 12% | The band gets thinner and quieter, and the piano line stays clear | |
| 19.85 to 20.17 | The note fades back in | A reversed bell chord swells, and the band comes back with it | |
| 22.0 | Four kinds of places for notes | The first chorus, with the melody from 24.0 | |
| 28.0 | A Claude conversation | A lighter groove | Key clicks at 29.6 |
| 31.0 to 31.42 | The label on the note is held down | The drums stop | A click and a short rising tone |
| 32.5 | ✨ is tapped | A swell leads in, then the choir and bells that circle from side to side | |
| 34.0 | The AI summary appears | The final chorus, with the melody an octave higher | |
| 40.0, 40.25, 40.5 | Logo, tagline, closing line | The theme again, one note for each, then a long Dmaj9 chord that fades out by 44.0 | |

## Files

| File | Contents |
| --- | --- |
| `Hintlet-v7.mp4` | The demo video with this soundtrack. The picture is copied unchanged and the audio is AAC at 256 kb/s |
| `Hintlet-v7.mp3` | The full mix, mastered to -14 LUFS with true peaks at -1.5 dBTP or lower |
| `Hintlet-v7.mid` | Every note as General MIDI, one track per instrument (piano, marimba, celesta, bass, pad, choir, drums), at 120 BPM from bar 1 |
| `poster.jpg` | A still from the video, used on the main README |

`build.sh` also writes three WAV files. They are left out of git because they are large and easy to rebuild:

- `Hintlet-v7.wav`, the full mix
- `Hintlet-v7-music.wav`, the music on its own
- `Hintlet-v7-sfx.wav`, the interface sounds on their own (clicks, keys and whooshes)

The music and SFX files add up to the full mix sample for sample, so an editor can turn either one up, down or off.

## Using real instruments

The synthesized instruments sound clean, but they can't match recorded ones. To get a richer sound, open `Hintlet-v7.mid` in Logic Pro or GarageBand and assign sampled piano, marimba and celesta sounds to the tracks. The melody and the timing stay exactly as they are.

Two effects live in the mix rather than in the notes, so you'll need to add them back by hand. Put a low-pass filter on the music from 10.0 to 12.15 seconds for the muffled section, and from 15.42 to 20.17 seconds for the quieter typing section.

## Rebuilding

You need Python 3 with numpy, and FFmpeg.

```sh
./build.sh
```

This writes the MP3, the MIDI file and the three WAV files. To also rebuild the video, pass the silent 44-second cut from the video handoff:

```sh
./build.sh path/to/Hintlet-silent.mp4
```

An earlier take played a marimba note for every keystroke in the TextEdit scene. To build that version instead, add `every-key` after the video path. With no video, pass an empty string first:

```sh
./build.sh "" every-key
```
