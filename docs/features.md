# PhotoCatalog features

The full reference to what PhotoCatalog does; [README](../README.md) has the overview. Menu and control names below are given in Chinese, the app's source language; the English interface shows their translations.

## Library

- **Main window** — native split view: source-list sidebar, unified toolbar (图库 | 修图 module picker, view mode, filter, sort, import / export, catalog actions, search), optional filter bar, photo grid, collapsible Inspector, and a status bar carrying the thumbnail-size slider. The chrome follows the macOS light or dark appearance (Settings → 常规 → 外观) around a neutral dark photo canvas, with a blue accent.
- **Sidebar** — 资料库 (全部 / 最近导入 / 未评分 / 精选 / 被拒绝 / 缺失·离线 / 重复文件 / 快捷收藏), 设备, 文件夹, 相册, 智能相册, 关键词, 人物 and 地点, all with live counts. Album sets (相册集, + → 新建相册集) file albums, smart albums and other sets into nested folders; right-click any of them → 移到相册集, and deleting a set moves what it held up a level.
- **Grid** — borderless photo tiles that fill each row, adjustable thumbnail size, offline / missing badges, color labels, flags, star ratings and accent-ring multi-select (click, ⌘-click, ⇧-click).
- **Loupe** — single-photo view with a bottom HUD and a filmstrip; zoom to 1:1 (double-click or `Z`), drag or pinch to pan, and the zoom holds while stepping through a burst. Full resolution decodes on demand, from the paired JPEG when there is one.
- **Compare** — 2–4 photos side by side with linked 1:1 zoom and pan, per-photo rating and flags, and 选为最佳 to pick the winner.
- **Survey** — the selection side by side, as large as fits: arrows pick the active photo, rating and flag keys act on it, × takes one out, and the rest stay selected back in the grid.
- **Culling** — rate, flag and label from the keyboard; hold `Shift` to move on to the next photo, or make that the default with 照片 → 评分后自动前进. `B` adds to or removes from the Quick Collection (资料库 → 快捷收藏, kept in the catalog), `Tab` hides the side panels, and 照片 → 移除被拒绝的照片… clears the rejects out of the current view at once.
- **RAW+JPEG pairs** — a RAW and its same-name JPEG or HEIC in one folder show as one photo; ratings, flags, keywords, time shifts, deletion and batch rename act on both files (Settings → 导入 lists them separately).
- **Stacks** — duplicates and edited copies stack with their originals. 照片 → 堆叠 → 按拍摄时间自动叠放… (Lightroom's Auto-Stack by Capture Time) stacks photos one camera took within 1 s – 1 h of each other (bursts, brackets; the dialog counts the stacks as the slider moves), keeps doing so for later imports, collapses the new stacks, and undoes in one step. `S` (or the badge) opens or closes a stack, and the menu collapses or expands them all.
- **Virtual copies** (照片 menu or right-click) — another catalog entry for the same original with its own develop settings and metadata, badged 副本 n on the thumbnail. They're never taken for duplicates or RAW+JPEG pairs, don't write the shared XMP sidecar, follow the original when it's renamed, moved or relocated, and removing a copy only removes it from the catalog.
- **Search and filters** — live search over an FTS5 index, a filter bar and sort. Capture dates by year, month and day, relative-date presets, and inclusive custom ranges; any filter can be saved as a smart album. To search with a sentence, see [AI assistant](#ai-assistant).
- **Smart albums** — AND/OR rule rows with a live match-count preview.
- **Capture analysis** — camera, lens, focal length, aperture, shutter and ISO distributions for the filtered results or the selected photos; cancellable background aggregation rejects stale results and reports missing metadata separately.
- **Inspector** — header with focal length / aperture / shutter / ISO at a glance, then Info / Metadata (EXIF, GPS, maker notes) / Organize (rating, flags, color, keywords, title, caption) / History.
- **Working with other apps** — right-click a photo to open it (default app or 打开方式), show it in Finder, share it, or rate, flag, label and remove it; drag photos out to Finder or an editor, and drop a folder onto the window to import it.

## Organizing and metadata

- **Keywords** — right-click a keyword in the sidebar to rename it (sub-keywords follow; typing an existing keyword merges the two) or delete it from every photo; both are undoable.
- **People** — 人物 analyses photos on device, from cached previews or a RAW's embedded JPEG; nothing leaves the Mac.
  - Vision finds each face and its landmarks, the face is turned and scaled onto a standard template by its eyes, nose and mouth, and SFace (bundled, running on this Mac) gives it 128 numbers that tell people apart: 99.4% on the LFW face-verification benchmark, where the Vision feature print used before scored 85%.
  - Each person's faces are grouped; on LFW, 0.3% of faces land in someone else's group, nearly all of them the benchmark's own mislabelled photos.
  - Groups are suggestions: untick faces that aren't the person, then name the rest. Naming another group the same merges them, 不是此人 takes a face back, and faces new analyses find close to a named person are offered for confirmation. Look-alikes, siblings above all, can still share a group, so review before naming.
  - Confirmed people tag their photos with `人物/名字` keywords, so search, smart albums and XMP carry them. Photos an earlier version analysed are offered for analysing again, keeping their names.
- **Places** — 地点 shows GPS-tagged photos on a map. 照片 → 设置位置… (or right-click) opens a map: search a place or click to drop the pin, and it applies to every selected photo (RAW+JPEG pairs together), or remove their location. 按 GPX 轨迹匹配位置… reads a GPX track and places photos by capture time, with the camera's time zone to line up clocks, interpolation between close fixes, and a live count before applying. Locations round-trip through XMP sidecars.
- **Duplicates** — exact duplicates by size-bucketed SHA-256 content hashing, and similar photos (疑似重复) by perceptual dHash and Hamming distance, resolved by keeping one.
- **Rename Photos** (照片 menu or right-click) — a name template with tokens (`{original}` `{seq}` `{date}` `{time}` `{camera}` `{title}` `{rating}`) and a start number, previewing old → new names before anything moves. A RAW's paired JPEG and the `.xmp` sidecar are renamed with it and virtual copies follow; a name another file in the folder already has, in any extension, gets `_1` (the preview warns).
- **Capture times** — Settings → 文件操作 → 批量调整拍摄时间 shifts the selected photos' capture times together (time zone or camera-clock fixes) or sets them to one time.
- **Metadata template** — author and copyright (with `{year}` from the capture date) applied to every import, alongside post-import keywords, color label and album.
- **XMP sidecars** — read on import and written on export or on demand (rating, label, keywords, title, caption, location). Writing merges into an existing sidecar and keeps everything else in it; one that can't be parsed is left alone. A sidecar that doesn't mention a rating or label leaves the photo's as they are. Sidecars move with their originals when photos are renamed or moved.
- **Sidecars changed by other apps** — when Lightroom, Bridge or another app edits a photo's `.xmp`, the photo gets a badge and lands in 管理 → 元数据已在外部更改. 照片 → 从文件读取元数据 takes the file's metadata (undoable, without rewriting the sidecar), or turn on 自动读取外部修改的 XMP in Settings. Our own writes never count as changes (照片 → 将元数据写入文件 writes them on request), and automatic writes never overwrite a sidecar another app changed until it has been read.

## Import

- **Folders** (toolbar 导入, or drop a folder on the window) — recursive scan → EXIF / GPS metadata (Image I/O) → thumbnails and previews (sharded disk cache) → content and quick hashes → the catalog, with animated scan → import progress, a panel of five running counts and a thumbnail wall. 分析场景与人脸 adds on-device scene tagging and face detection.
- **Referenced or managed** — photos stay where they are, or are copied into the catalog's `Originals` folder, by date (`YYYY/MM/DD`) or by camera (`<camera>/YYYY/MM`) (Settings → 导入 → 导入模式).
- **Checkpoints** — the first photo becomes browsable immediately, then files commit in batches of up to 32 or one second. Each transaction saves the assets, initial metadata and develop settings, album membership, source root and per-file checkpoint together. Saved counts reflect committed photos; browsing and editing can continue during import. Restarted managed and referenced imports reuse committed files without overwriting later edits. A persistence failure stops the files after it and keeps earlier batches; originals already copied and caches are not removed automatically.
- **Memory cards** — cards (any mounted volume with a DCIM folder) appear under 设备 in the sidebar and in the Import menu. Pick photos by day (ones already in the catalog are marked and left unchecked), copy them into dated folders (年 / 年-月-日), optionally rename with a template (RAW+JPEG pairs keep one name), keep a backup copy in a second location, apply keywords, author and copyright, and eject when done. The catalog references the copies, never the card.
- **Cameras and iPhones** — devices on a cable that speak PTP (ImageCaptureCore) appear under 设备 and in the card-import window and import the same way: pick by day, see what's already imported, and files are filed, renamed and backed up by the card rules as they download. Each download is staged on the destination disk and removed once placed. This path is exercised with a simulated device, not yet with physical hardware.
- **Videos** — MOV, MP4 and M4V import beside photos (folders, cards). Their length, size as they play (turned by the track's transform), creation time (an instant, kept as this Mac's wall clock like a photo's capture time), camera (QuickTime make/model or MP4 user data) and location are read with AVFoundation, and an early frame makes their thumbnails. In the loupe a video plays in the system player with its inline controls (Space plays or pauses; it stops when you move on or leave); a ▶ badge shows the length in the grid, the inspector shows length, resolution and format. They rate, flag, label, keyword, filter (类型 → 视频, also in smart albums) and stack like photos; develop, merge, enhance, print and outside editors are for photos, and export copies a video's original under the name template. A video beside a photo of the same name (a Live Photo) keeps its own `<name>.<ext>.xmp` sidecar.
- **Tethered capture** (目录库 → 联机拍摄…) — shoot straight into the catalog, from a camera on a cable that macOS can control (ImageCaptureCore; `F12`, or the bar's 拍摄, releases the shutter when the camera takes pictures on command), or by watching a folder that the maker's tethering software (EOS Utility and the like) saves to; files already there are left alone, and a new one is taken once its size holds still.
  - Each shot lands in a folder named for the session (inside an existing source folder it is filed under that folder), named as shot or `Session-0001` with a RAW and its JPEG sharing a number and numbering going on when a session is picked up again.
  - Shots import one at a time in order, get the session's develop preset (changeable from the bar mid-session) and keywords, and show in the loupe.
  - Ending the session, or unplugging the camera, leaves the folder watched like any imported one. The folder path and the session are covered by `--pipeline`; the camera path is written against ImageCaptureCore and exercised through a simulated device, not a physical camera.
- **Develop settings on import** — a develop preset chosen in Settings → 导入, the import window or the card window applies to new photos, on top of the per-camera RAW defaults (see [Presets and sync](#develop)).
- **Watching** — referenced folders are watched with FSEvents: new files import and removed files are flagged missing automatically.
- **Missing and offline** — originals are re-checked on launch and flagged missing if gone; unmounting an external drive marks its photos offline instead, and remounting restores them.

## Develop

`D` opens the selected photo in 修图. Development is non-destructive and rendered with the system RAW engine (CIRAWFilter); the original is never modified. Every adjustment previews live while dragging, with an RGB histogram and clipping warnings, and is undoable; double-click a slider's name to reset it.

- **Profiles** — 标准 is the RAW engine's own rendering; 中性, 鲜艳, 人像 and 风景 are the app's own base looks (a tone curve, a response per color band and an overall saturation), applied before every other adjustment at an amount of 0–200%. Rest the pointer on one to preview it. Lightroom presets' Adobe and Camera profiles map to the nearest one.
- **Black and white** — 处理方式 彩色 / 黑白, or the 单色 profile. The color mixer gives way to a black-and-white mix: how light each of the eight color bands turns, scaled by how colorful a pixel is so grays keep their tone. 自动 spreads the photo's main colors apart by their lightness without darkening skin's orange; color grading then tones it, e.g. sepia. Camera Raw's ConvertToGrayscale and GrayMixer settings map both ways.
- **Basic** — white balance, exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, dehaze, vibrance and saturation.
  - White balance starts from the as-shot Kelvin and tint read from the RAW. The eyedropper (`W`) sets it from something you click that should be gray.
  - Auto white balance (`⇧⌘U`, or 自动 beside 白平衡) finds the photo's gray surfaces near neutral on its as-shot rendering, brighter ones counting more, and sets temperature and tint so they render gray: the same answer from any slider position, and none when nothing in the photo is close to gray.
  - Auto white balance and auto tone (`⌘U`) act on the photo in Develop, or on every selected photo in the grid.
- **Tone curve** — a point curve, composite and per channel: click to add a point, drag, double-click to remove; linear / medium / strong presets.
- **Color mixer** — hue, saturation and luminance for eight color bands, weighted by how colorful a pixel is so whites and grays stay put.
- **Color grading** — a tint and luminance for shadows, midtones, highlights and the whole photo, with blending and balance (positive favors the highlights, as in Lightroom).
- **LUTs** — import `.cube` 3D LUTs into a library every catalog shares, and apply one with an amount; 33- and 65-point LUTs are resampled.
- **Calibration** — applied first: a green–magenta shadows tint, and the red, green and blue primaries' hue and saturation through a matrix on linear light that keeps white and grays as they are. Camera Raw's ShadowTint, RedHue … BlueSaturation map both ways.
- **Detail** — sharpening with radius and edge masking, luminance and color noise reduction.
- **Lens corrections** — manual distortion and lens vignetting (Apple's RAW engine has no profiles for Canon RF lenses). 删除色差 measures the photo's lateral chromatic aberration on its achromatic edges (red and blue each magnified slightly differently from green) once per file, and rescales red and blue back into place. 紫边去除 / 绿边去除, 0–20 as in Lightroom, take the color out of purple and green fringes along high-contrast edges. Presets carry them as Camera Raw's AutoLateralCA and Defringe amounts.
- **Effects** — post-crop vignette and film grain.
- **Lens blur** (镜头模糊) — the background or foreground blurred by how far it lies from the depth in focus, from a depth map Depth Anything V2 (bundled, running on this Mac) makes once per photo and caches. Turning it on focuses on the largest face, else the subject; 点选焦点 sets the focus by clicking the photo, and 显示深度 shows the depth map, near warm and far cool. Amount, focus distance and focus range sliders. Copy and sync leave it behind unless ticked, since its focus belongs to one photo.
- **Masks** — local adjustments, each mask with its own exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, texture, clarity, dehaze and saturation. Any mask can be inverted, `O` tints the selected mask's coverage red, and masks stay on the same part of the picture when you crop or rotate.
  - **Gradients** (`M` linear, `⇧M` radial) — drag on the photo to draw one; drag its handles to move, turn or reshape it.
  - **Brush** (`K`) — paint with size, feather and density; hold `⌥` to erase, `[` / `]` to resize. 用画笔增减 paints onto or erases from any gradient, subject or sky mask.
  - **选择主体 / 选择天空** — the subject (Vision's foreground segmentation) or the sky (smooth, bright or blue areas grown from the top edge, stopped at the horizon and the subject).
  - **选择人物** — a whole person or a part of them (face skin, body skin, eyebrows, eye sclera, iris and pupil, lips or teeth) from Vision's person segmentation, person instances and face landmarks, skin told apart by the face's own color. With several people a mask takes everyone or one person (numbered left to right), and its part can be changed later.
  - **选择物体** (select object) — whatever a box drawn around it, or a click on it, picks out. SAM 2.1 (bundled, running on this Mac) encodes the photo once and decodes each box or click in a few hundredths of a second; click a part it missed to add it, ⌥-click an extra part to take it out, or drag to box it again.
  - **选择景观** (select landscape) — the water, vegetation, mountains, architecture, natural ground or artificial ground, from the labels DETR (bundled) gives every part of the photo, with edges fitted to the photo's; the category can be changed later.
  - **颜色范围 / 明亮度范围** — the parts of the photo in sampled colors (click up to five places) or within a range of tones; any other mask can be narrowed to such a range too.
- **Spot removal** (`Q`) — click a speck to heal it (the source is found automatically among nearby places whose surroundings match) or drag outward to size it; drag a spot or its source to move it, its edge to resize. Heal matches the surrounding color and brightness, clone copies as is. 移除 (remove) paints over an object and, on letting go, fills it with what LaMa (bundled, running on this Mac) makes of its surroundings; the fill is made once from the full-size photo and cached, then matched to the current color and brightness like heal, so later exposure or white-balance changes still blend. 显示污点 shows only fine detail so sensor dust stands out.
- **Crop and straighten** (`R`) — aspect presets; drag corners or edges or move the crop; draw a line outside it to level the photo, or auto-straighten from the horizon (Vision). Quarter turns (`⌘[` / `⌘]`) and horizontal flip work on a whole selection from the grid too.
- **Transform** — vertical and horizontal perspective correction, and Upright: 自动 sets verticals upright and turns a clearly visible facade's horizontals most of the way to parallel, 垂直 sets verticals upright only. The crop is kept off the empty corners.
- **Soft proofing** (`S`, or 软打样 at the top of the panel) — the photo shown through sRGB, Display P3, Adobe RGB or any printer profile installed on this Mac, with a perceptual or relative intent through ColorSync, optionally simulating paper white and ink black. 色域警告 paints red the colors whose hue, saturation or lightness doesn't survive the profile (black that only prints as the ink's black doesn't count). The histogram shows the proof.
- **Before and after** — `\` toggles the before view; `Y` shows before and after side by side, framed alike, side by side or one above the other, whichever shows the photo larger.
- **Snapshots and history** — snapshots are named states to come back to (new, rename, update, delete); a per-photo history of every edit is kept in the catalog. Click a step or snapshot to return to it; undo takes a step away, redo puts it back.
- **Presets and sync** — copy and paste settings (`⇧⌘C` / `⇧⌘V`) or sync them across a selection (`⇧⌘S`) with a per-setting checklist; white balance only travels between photos of the same kind.
  - Built-in and your own presets apply from the Develop panel, the 照片 menu or the right-click menu. Rest the pointer on one to preview it on the photo. After applying one, an amount slider (0–200%) scales its sliders, white balance, curves, mixer, grading and masks' own adjustments.
  - Right-click a preset to rename it, update it from the current settings, move it to a group or a new group, or delete it (after confirming).
  - Presets import and export as `.xmp`: the app's own files round-trip completely, masks and spots included, and also carry Camera Raw's settings so Lightroom can import them. Lightroom and Camera Raw presets bring in the settings the two apps share, and the app says what it left out.
  - RAW defaults per camera (Settings → 修图): one preset for every camera and one for each camera, or the photo as shot. They apply at import, under the import preset, and resetting a photo returns to them. Right-click a preset to make it the current camera's default.

## Merge, enhance and outside editors

- **Photo Merge → HDR** (`⌃H`, 照片 menu or right-click) — 2–9 bracketed exposures lined up by median threshold bitmaps and merged by exposure fusion in Laplacian pyramids, with optional deghosting and a preview. The result is a 16-bit TIFF beside the middle exposure (`name-HDR.tif`), added to the catalog with its metadata.
- **Photo Merge → Panorama** (`⌃M`) — 2–30 overlapping photos, in order, projected onto a cylinder (focal length from EXIF), lined up by masked normalized correlation, horizontal or vertical, exposure-matched and feathered, and auto-cropped to the largest filled rectangle; a pair that doesn't overlap is named. The result is `name-Pano.tif` beside the first photo.
- **Enhance** (`⌃⌥I`, 照片 menu or right-click) — AI denoise (SCUNet, amount 0–100) and/or super resolution (Real-ESRGAN, twice the width and height) with Core ML models bundled in the app, running on this Mac, and a 100% before/after preview. Each result is a 16-bit TIFF beside its original (`name-Enhanced.tif`) carrying the original's metadata, added to the catalog with its develop settings (white balance aside). Progress and cancel are in the status bar.
- **Edit in an external editor** (`⌥⌘E`; pick the app once: Photoshop, Affinity Photo, Pixelmator Pro…) — the photo with its adjustments becomes a 16-bit Adobe RGB TIFF beside the original (`name-编辑.tif`), joins the catalog with the original's rating, labels and keywords, stacks with it, and opens in the editor. The original is never touched, and the editor's saves come back through folder watching.

## Output

- **Export** (`⇧⌘E`) — renders the selection with its Develop adjustments to JPEG, HEIC or TIFF (8/16-bit):
  - resize by long or short edge or a box; quality; sRGB, Display P3 or Adobe RGB;
  - file-name templates (`{original}` `{seq}` `{date}` `{time}` `{camera}` `{title}` `{rating}`) and collision handling;
  - output sharpening on the final pixels, for screen, matte or glossy paper (paper takes a wider radius), at low, standard or high, luminance only;
  - metadata: all, copyright only or none, optional location removal, and the catalog's title, caption, keywords and rating included; a text watermark.

  Built-in and saved export presets. Exports queue and run one after another in the background, with progress and cancel in the status bar. `⌘E` copies the untouched originals instead (keeping their modification dates), with a JSON metadata sidecar.
- **Print** (`⌘P`) — the selection on paper:
  - A3 / A4 / A5 / Letter / Legal / Tabloid / 4×6 / 5×7 / 8×10, portrait or landscape, margins;
  - one photo per page (fit, or fill and crop) or a contact sheet of rows × columns with spacing; rotate to fit turns a photo a quarter when that fills its place better; captions (file name or title) under each photo;
  - photos rendered at 150–360 ppi for their size on the paper (never decoded larger than that needs), print sharpening for matte or glossy paper, and color managed either by the printer or by converting to an installed printer profile (perceptual or relative, through ColorSync).

  The dialog previews each page with the same drawing the printer and 存储为 PDF… use.
- **Slideshow** (照片 → 幻灯片…, or `⌘↩` to play at once) — the selected photos (or the whole list) full screen, as Develop shows them: each for 1–20 s, fading into the next (0–3 s), with a slow pan and zoom that never shows an edge, in list or a repeatable random order; captions (title, file name or caption) that take turns through a fade; a black, gray or white backdrop; and music that loops with the show or sets each photo's time to fill it. `Space` pauses, `←` / `→` go back or on, `Esc` ends. 导出视频… writes the same show as an H.264 MP4 at 720p, 1080p or 4K, rendered from the originals with their develop settings, with the music fading out at the end; progress and cancel in the status bar.
- **Web gallery** (照片 → 导出网页画廊…) — the selected photos (or the whole list) as a folder that works on any web host: `index.html` (one file, no outside code) with a dark or light grid of square thumbnails and a viewer with arrows, keys and swipes; a title and subtitle, captions (title, caption or file name) and a camera · lens · exposure line. Photos are rendered as developed into sRGB JPEGs without metadata at a chosen size (never enlarged), thumbnails sized for the tiles at 2×. Captions are escaped, a new gallery never overwrites another, and a cancelled one leaves nothing.
- **Photo book** (照片 → 制作画册…) — the selected photos (or the whole list) laid out as a book and saved as a PDF: 20 × 20 cm, 25 × 20 cm, 20 × 25 cm or A4 landscape pages; auto layout (a photo shaped like the page alone, two of the other shape side by side or one above the other) or one, two or four a page; no margin (a photo alone fills its page to the edges), narrow or wide margins; a white or black background; a cover with the first photo, a title and subtitle; captions (title, caption or file name) right under each photo; page numbers. Photos are rendered as developed at 300 ppi for the size they print, and the dialog previews each page with the same drawing the PDF uses.

## AI assistant

Optional. Settings → AI points these features at a language-model service: Anthropic's Messages API or any OpenAI-compatible chat-completions endpoint (OpenAI, DeepSeek, Qwen, Doubao, Kimi, GLM, or Ollama / LM Studio on this Mac, which need no key), with its address, model and whether it reads images, and a connection test. The API key is kept in the login keychain, one per service. Nothing is sent until a feature is used, and photos go only as JPEG previews reduced to 1024 pixels.

- **Describe photos** (照片 → AI 描述照片…, `⌃⌥D`, or right-click) — confirm the service, model and what will be sent, then generate titles, captions and keywords from the previews, three at a time with progress and cancel in the Task Center.
  - Capture date, camera, location and existing keywords are sent only if enabled for that batch. The batch keeps the service configuration you consented to even if Settings changes while it runs.
  - Results are never applied automatically: review the current and proposed values, select photos, then apply. Keywords are appended; titles and captions fill empty fields unless 替换 is on; each application is undoable. Failed items can be resent after confirmation without regenerating the ones that succeeded.
  - Unapplied results stay in memory until discarded, the catalog is switched or the app quits. Task history persists, but can't restore these proposals or resend photos by itself.
- **Natural-language search** (视图 → 用自然语言查找…, `⌥⌘F`) — a sentence ("去年夏天在海边拍的、四星以上的照片") becomes the filter bar and the search box: rating, flag, color label, file type, camera, lens, capture dates, location and search words, checked against what the filters accept. Only the sentence and the catalog's camera, lens and keyword names are sent.
- **AI 调整** (Develop) — a described look ("暖一点的胶片感") becomes new values for the Basic, Presence and Effects sliders, white balance and color grading, each kept within its slider and applied as one undoable step, with the model's one-line explanation. The first time it would send a photo to a service off this Mac, it asks.

Replies are checked rather than trusted: a search filter counts only when the sentence says something about it, slider values are kept within their ranges, and a reply that only repeats the current values changes nothing. They're also read leniently: JSON inside prose or a code fence, single-quoted, or cut off by the token limit. Small local models (a few billion parameters) describe photos well but read search requests and looks less reliably than the hosted ones.

## Catalog and safety

- **Welcome** — the first launch opens a card to create a catalog or open a recent one; 目录库 → 新建目录库… / 打开目录库… (`⌘N` / `⌘O`) switch catalogs later.
- **Catalog** — a `.photolibrary` package (`catalog.sqlite` + `manifest.json` + `Cache/` + `Backups/`) on the system SQLite library. Edits (rating, flag, color, keywords, title, caption, develop settings) write through and survive relaunch, and `⌘Z` / `⇧⌘Z` undo and redo them.
- **Backup** — the status bar and automatic snapshots back up the catalog's SQLite database only (维护 → 创建目录库快照 / 恢复目录库快照…). 维护 → 完整备份与恢复… creates a verified `.photobackup` containing catalog metadata and history, active originals, XMP, the catalog's Config and the LUT and fill resources it references. Restore creates a new `.photolibrary`; it never overwrites or switches the current library and doesn't resume old imports. Missing originals or resources fail the backup; previews, deleted originals, global preferences and preset lists, credentials and unsaved editing drafts are left out.
- **Task Center** (status-bar task button, or 维护 → 任务中心…) — catalog-scoped import, rendered export, enhancement, preview, backup and restore work, with actual progress and failure details. Controls come from the engine that owns the work; reopening never replays exports or network requests. History keeps the newest 200 finished tasks and up to 100 failure details per task without dropping active work; interrupted work and history write failures stay visible. Operational history lives in the catalog's Logs folder and is left out of full backups.
- **Maintenance** — catalog health check (维护 → 运行健康检查), rescanning the current source, and rebuilding or clearing the thumbnail and preview caches (Settings → 缓存与性能).
- **Scale** — measured at 500,000 photos with a synthetic catalog (`--scale`, Release build, Apple silicon, warm file cache): the first photos appear within a second of launch and the whole catalog is usable in about 5 s. Filtering, sorting, searching and switching collections respond in 0.1–0.35 s, and rating a photo in about 50 ms. Asset metadata stays resident in memory in a compact copy-on-write form (about 1 GB at 500k photos) rather than being paged from SQLite.

## Keyboard shortcuts

Single-key shortcuts don't apply while you type in a text field.

**Views and navigation**

| Key | Action |
| --- | --- |
| `G` / `E` / `C` / `N` / `A` / `D` | Grid / loupe / compare / survey / capture analysis / develop |
| `Return` · `Space` | Open the loupe (in the loupe, `Space` plays or pauses a video) |
| Arrows | Move through photos |
| `Esc` | Close panels and sheets, finish a Develop tool |
| `Z` or double-click | Zoom to 1:1 (linked across Compare) |
| `Tab` | Hide the side panels |
| `F` · `⇧⌘F` | Show or hide the filter bar |
| `I` | Show or hide the info on thumbnails |
| `⌘F` | Search |
| `⌥⌘F` | Search with a sentence (AI) |
| `⌘I` | Inspector |
| `⌘+` / `⌘-` / `⌘0` | Thumbnail size |
| `⌘A` · `⇧⌘A` | Select all in the list · invert the selection |
| `⌘S` | Save the current filter as a smart album |

**Culling and organizing**

| Key | Action |
| --- | --- |
| `1`–`5` · `0` | Rate · clear the rating |
| `P` / `X` / `U` | Pick / reject / unflag |
| `6`–`9` | Color label |
| `Shift` + any of the above | …and move on to the next photo |
| `B` | Add to or remove from the Quick Collection |
| `S` | Open or close a stack (outside Develop) |
| `⌘'` | Virtual copy |
| `⌘[` / `⌘]` | Rotate left / right |
| `⌘Z` · `⇧⌘Z` | Undo · redo |
| `⌫` · `⌘⌫` | Remove from the catalog · move the originals to the Trash |

**Develop**

| Key | Action |
| --- | --- |
| `\` · `Y` | Before / after · before and after side by side |
| `R` | Crop and straighten |
| `W` | White-balance eyedropper |
| `M` · `⇧M` | Linear · radial gradient |
| `K` | Brush (`⌥` erases, `[` / `]` resize) |
| `O` | Show the selected mask's coverage |
| `Q` | Spot removal |
| `S` | Soft proofing |
| `Delete` | Remove the selected mask or spot |
| `Return` · `Esc` | Finish the current tool |
| `⌘U` · `⇧⌘U` | Auto tone · auto white balance |
| `⇧⌘C` / `⇧⌘V` / `⇧⌘S` | Copy / paste / sync develop settings |
| `⌥⌘E` | Edit in an external editor |

**Commands**

| Key | Action |
| --- | --- |
| `⌘N` · `⌘O` | New · open catalog |
| `⇧⌘I` | Import |
| `⇧⌘E` · `⌘E` | Export rendered · export originals |
| `⌘P` | Print |
| `⌘↩` | Play a slideshow (`Space` pauses, `←` / `→` go back or on, `Esc` ends) |
| `⌃H` · `⌃M` | Merge to HDR · panorama |
| `⌃⌥I` | Enhance |
| `⌃⌥D` | Describe photos (AI) |
| `F12` | Release the shutter while tethered (`fn`-`F12` where the top row controls the Mac) |
| `⌘R` | Rescan the current source |
| `⌘B` · `⇧⌘B` | Catalog snapshot · restore one |
| `⌘,` | Settings |
