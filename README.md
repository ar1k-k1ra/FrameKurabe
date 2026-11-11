# FrameKurabe

FrameKurabe is a Windows PowerShell tool for comparing selected frames from multiple video files. It exports **16-bit RGB TIFF** and **16-bit RGB PNG** images, uses FFmpeg for extraction, and opens the first selected video in AvsPmod with an AviSynth frame-number overlay so you can identify frame indices.

## Files and requirements

- `Run_FrameKurabe.bat` — double-click this launcher to start the tool.
- `FrameKurabe.ps1` — interactive workflow and FFmpeg commands.
- `tools\` — bundled dependencies; the exporter does not use the sibling `DoVi.Scripts` folder:
  - `ffmpeg.exe`
  - `AvsPmod\AvsPmod.exe`
  - `FFMS2\ffms2.dll`
  - `AviSynth\` runtime files
- Optional frame-delay alignment uses these bundled tools:
  - `MPV\mpv.exe`
  - `scenedetect\scenedetect.exe`
- Optional slow.pics upload uses the bundled browser drivers to automate a visible private-browsing window:
  - `geckodriver\geckodriver.exe`
  - `chromedriver\chromedriver.exe` — also bundled for Chrome users

Keep the folder contents together if moving the tool to another location. The script checks for FFmpeg, AvsPmod, and the FFMS2 plugin at startup. Firefox or Google Chrome is required only if slow.pics upload is selected; Firefox is preferred when installed, otherwise Chrome is used in Incognito mode. The browser itself must be installed, but users do not need to install a WebDriver separately. A ChromeDriver matching the installed Chrome build is selected from the bundled driver or downloaded automatically from Google's official Chrome for Testing service and cached under the current user's LocalAppData. Internet access is needed only when neither the bundled nor cached driver matches Chrome. The launcher runs PowerShell with `-NoProfile` and `-ExecutionPolicy Bypass`; no system-wide execution-policy change is needed.

## Usage

1. Double-click `Run_FrameKurabe.bat`.
2. Enter an output directory, or press Enter to use the current user's Pictures folder. The directory is created if it does not exist. Paths can be quoted or dragged into the console.
3. Enter the number of video files to compare. The minimum is two.
4. Drag and drop each video into the console, pressing Enter after each path. Quoted paths are accepted. Each selected file must be distinct.
5. The script opens **only the first video** in AvsPmod. Its frame-number overlay displays **zero-based** indices: the first frame is `0`, the next is `1`, and so on.
6. The preview opens independently. You can leave it running while you enter frame numbers in the console; the script does not wait for it to close.
7. Enter how many frame indices to export, then enter each index. Indices must be non-negative whole numbers and cannot be duplicated in the list.
8. The script exports each chosen index from every selected video in both formats.
9. After export, choose whether to upload the TIFFs to slow.pics. If uploading, enter a comparison title and an optional custom column title for each video (press Enter to use that video's filename).

If an index is outside a video's available frames, FFmpeg will not produce the expected image and the script reports an export error. The index must be valid for every selected video.

## Aligning videos with frame delays

After you enter all video paths, answer whether there are frame delays to correct.

- If you answer **N**, all videos export the same entered frame numbers, as before.
- If you answer **Y**, PySceneDetect's adaptive detector scans the first (source) video and lists up to five evenly spaced scene-cut frame numbers. These are suggested places to compare recognizable content; if fewer than five cuts are detected, it lists all of them.
- For each later video, the script opens two separate MPV windows side by side: the source on the left and that comparison video on the right. Both start paused at the beginning, with audio disabled and the zero-based frame number displayed persistently in MPV's OSD status line.
- The MPV player processes are launched without attaching a console, so closing the preview windows should return to the PowerShell prompts rather than interrupting the batch launcher.
- In either MPV window, press **g** (lowercase), type a zero-based frame number, then press **Enter** to seek. Press **Esc** to cancel a jump, **Backspace** to edit the number, **.** to step forward one frame, and **,** to step backward one frame. Use the displayed frame number and the scene-cut suggestions to find matching content.
- Close both windows when you have found a matching pair. Enter the matching source frame number and comparison-video frame number in the console. The script records the fixed offset `comparison frame - source frame`, then proceeds to the next comparison.
- Finally, enter the source frame numbers to export. The source exports those exact indices; each comparison video exports the corresponding index after applying its recorded offset. Output filenames use the actual frame index exported from each video.

This alignment mode assumes a **constant frame-index offset** for each source/comparison pair. One matched pair cannot correct edits that add/remove frames at different points or ongoing frame-rate drift. MPV frame-number jumps estimate time using the video's frame rate; for variable-frame-rate videos, use the displayed frame number and single-frame stepping to fine-tune the position. Scene-cut suggestions are based on the source video only and do not automatically determine the matching frame in another video.

## Output

Images are saved in the chosen output directory (Pictures by default). Each input gets two separate output folders, named after the complete input filename with the image extension appended:

```text
Pictures\
  Example.mkv.tiff\
    Example_00000042.tiff
  Example.mkv.png\
    Example_00000042.png
```

The image filename pattern is:

```text
<FileName>_<framenumber>.<extension>
```

- `<FileName>` is the source filename without its video extension.
- `<framenumber>` is the selected zero-based frame index, padded to at least eight digits.
- `<extension>` is `tiff` or `png`.

Filenames contain no timestamp. The extension-specific output folders keep the two image formats separated. Exporting the same frames again produces the same names and asks before overwriting existing images.

## Uploading to slow.pics

After a successful export, you can optionally upload the TIFFs to slow.pics. FrameKurabe opens Firefox in private-browsing mode when Firefox is installed; otherwise it opens Chrome in Incognito mode. It automates the visible comparison form. Each selected source frame becomes a row, each input video becomes a column, and the column titles are editable. Aligned videos use their mapped TIFF frame while the row label remains the selected source frame number.

The upload sets visibility to **Only by link**, enables image optimization, selects **WEBP**, and clicks slow.pics' **Save** control for each changed dropdown. It then verifies the title, row labels, column labels, settings, and selected TIFF count before submitting. FrameKurabe uses the browser's normal page and form interactions; it does not extract browser tokens or call slow.pics upload endpoints directly. If a browser security check appears, complete it in Firefox; the script waits for the comparison form and resumes automatically. After submission, it detects the comparison URL from slow.pics' `/c/<id>` page and prints it. Local TIFF and PNG exports remain in the selected output directory; temporary TIFF staging files are removed only after the browser confirms upload completion.

The staged files are named and ordered so slow.pics' Batch upload can build the intended grid. If the browser rejects a request, the upload stalls, or the form changes, FrameKurabe reports the failure and keeps the staging folder for troubleshooting; original exports are never removed.

## Image formats and FFmpeg behavior

Both exports are encoded as 16-bit-per-channel RGB:

- **TIFF:** FFmpeg `tiff` encoder, `rgb48le` pixel format, LZW compression.
- **PNG:** FFmpeg `png` encoder, `rgb48be` pixel format, compression level 6.

For each video, FFmpeg reads the first video stream (`0:v:0`) once, selects all requested zero-based decoded frame indices in a single filter pass, then splits those frames into TIFF and PNG encoders. The script stages the images temporarily and names them using the original source-frame index—not the ordinal position within the list of selected frames. Audio and other streams are not exported.

FFmpeg generally has to decode video frames sequentially from a preceding keyframe to reach an exact frame index. This single-pass approach avoids starting a new decode for every selected frame and avoids decoding the same frames separately for TIFF and PNG. The export can still take time for long, high-resolution, or computationally intensive videos, especially when selected frames are far apart.

The script does not perform HDR-to-SDR tone mapping or grading. It is intended for ordinary SDR video and exports decoded frames as RGB; source color characteristics and conversion behavior depend on FFmpeg and the input's metadata.

## Bundled tools and update links

The versions below are the Windows x64 builds currently included in `tools`. AvsPmod, AviSynth+, FFMS2, and FFmpeg are required for normal preview/export. MPV and PySceneDetect are only needed when frame-delay alignment is enabled.

| Tool | Bundled version | Purpose | Project / release information | Windows download |
|---|---:|---|---|---|
| FFmpeg | 9.0.2 essentials | Frame extraction and TIFF/PNG encoding; bundled as `tools\ffmpeg.exe` | [FFmpeg project](https://ffmpeg.org/) · [official download page](https://ffmpeg.org/download.html#build-windows) | [Gyan.dev Windows builds](https://www.gyan.dev/ffmpeg/builds/) — third-party binaries linked by FFmpeg; choose the **release essentials** build |
| AvsPmod (GPo) | 2.7.9.7 | Opens the first video for frame inspection | [GPo releases](https://github.com/gispos/AvsPmod/releases) | [Windows x64 release archive](https://github.com/gispos/AvsPmod/releases/download/2.7.9.7/AvsPmod_v2.7.9.7_.Windows_x86-64.zip) |
| AviSynth+ | 3.7.6 | Scriptable video frames for AvsPmod preview | [AviSynth+ releases](https://github.com/AviSynth/AviSynthPlus/releases) | [Files-only archive](https://github.com/AviSynth/AviSynthPlus/releases/download/v3.7.6/AviSynthPlus_3.7.6_20261025-filesonly.7z) — use the `x64` runtime |
| FFMS2 | 5.0 | Frame-accurate video source plugin used by AviSynth+ | [FFMS2 releases](https://github.com/FFMS/ffms2/releases) | [MSVC archive](https://github.com/FFMS/ffms2/releases/download/5.0/ffms2-5.0-msvc.7z) — use the `x64` files |
| MPV | 0.42.0 | Side-by-side manual frame alignment | [MPV releases](https://github.com/mpv-player/mpv/releases) | [Windows x64 full build](https://github.com/mpv-player/mpv/releases/download/v0.42.0/mpv-v0.42.0-x86_64-w64-mingw32-full.zip) |
| PySceneDetect | 0.7.3 | Suggests scene-cut frame numbers for alignment | [PySceneDetect releases](https://github.com/Breakthrough/PySceneDetect/releases) | [Windows x64 bundle](https://github.com/Breakthrough/PySceneDetect/releases/download/v0.7.3/PySceneDetect-0.7.3-win64.zip) |
| Mozilla geckodriver | 0.37.1 | Drives the visible Firefox UI for optional slow.pics uploads | [geckodriver releases](https://github.com/mozilla/geckodriver/releases) | [Windows x64 archive](https://github.com/mozilla/geckodriver/releases/download/v0.37.1/geckodriver-v0.37.1-win64.zip) |
| ChromeDriver | 157.0.8103.50 | Drives the visible Chrome UI for optional slow.pics uploads; matching versions are downloaded automatically when needed | [Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/) | [Windows x64 archive](https://storage.googleapis.com/chrome-for-testing-public/157.0.8103.50/win64/chromedriver-win64.zip) |

### Updating the bundled tools

1. Check the project's release page above for the newest compatible Windows x64 release. For FFmpeg, use the official FFmpeg download page to find Windows builds; the Gyan.dev link above is a third-party build provider, not the FFmpeg project itself.
2. Download from the release link, and verify any checksum published by the project or build provider before extracting.
3. Keep the existing folder layout and executable names because the script resolves everything relative to itself:
   - `tools\ffmpeg.exe`
   - `tools\AvsPmod\AvsPmod.exe`
   - `tools\AviSynth\AviSynth.dll` and its runtime files
   - `tools\FFMS2\ffms2.dll`
   - `tools\MPV\mpv.exe`
   - `tools\scenedetect\scenedetect.exe` and its bundled `_internal` dependencies
   - `tools\geckodriver\geckodriver.exe` (slow.pics browser upload)
   - `tools\chromedriver\chromedriver.exe` (slow.pics upload in Chrome; automatic matching download is used for other Chrome builds)
4. Use matching x64 builds. Update dependent packages together when a release changes compatibility requirements (especially AviSynth+/FFMS2 and PySceneDetect's bundled runtime).
5. Preserve the package license notices. The current notices are `tools\AvsPmod\copying.txt`, `tools\AviSynth\LICENSE.html`, `tools\FFMS2\COPYING.GPLv3`, `tools\MPV\LICENSE.GPL`, `tools\scenedetect\LICENSE`, `tools\geckodriver\LICENSE`, `tools\chromedriver\LICENSE`, and `tools\ffmpeg-LICENSE`.
6. Smoke-test preview loading, MPV's frame-number OSD, scene detection, and a TIFF/PNG export before replacing the previous working tools. Keep a backup until those checks pass.

## Troubleshooting

- **Missing FFmpeg:** Confirm `tools\ffmpeg.exe` is present.
- **Missing preview components:** Confirm the local `tools` directory contains the required AvsPmod, AviSynth, and FFMS2 files. The expected layout is documented above.
- **Scene detection fails:** Confirm `scenedetect\scenedetect.exe` can open the first video. The exporter now displays PySceneDetect's captured error output to help diagnose unsupported or damaged inputs.
- **Preview fails to load a video:** Check that FFMS2/AviSynth can decode the input and that its path is valid. The preview uses `FFVideoSource` and `ShowFrameNumber`.
- **Frame export fails:** Check the console error and confirm the chosen frame index exists in every source file. Also ensure the chosen output directory is writable and that sufficient disk space is available.
- **Console closes too quickly:** Run the `.bat` launcher; it pauses after the PowerShell script exits so errors remain visible.
