# Disk inventory app: design

Date: 2026-10-28
Status: draft for founder review
Working name: none yet (founder to pick; "the app" below)

Mockups: `2026-10-28-mockups/dropdown-flat.html` (menu bar dropdown) and
`2026-10-28-mockups/main-window-flat.html` (full window). Open them in a browser.
They are the visual reference for this document.

## 1. Intent

The founder loves Disk Inventory X, but it and its modern rewrites (DI Y, DI Xs)
all run out of memory and freeze the Mac when scanning a full disk and drawing
the treemap. The freezing is the thing they hate most.

The app does what those tools do (show where disk space went, let you drill in
and clean up), but:

- never freezes the UI and never blows up memory, at any disk size;
- answers the question people actually have most often, "where did my space go
  recently?", without a full scan, from a menu bar dropdown;
- feels like a modern Mac app next to Raycast, CleanShot and Arc: flat, crisp,
  keyboard-first, with personality from precision and meaningful color rather
  than decoration.

## 2. Goals, non-goals, anti-goals

Goals
- Menu bar item that opens instantly with fresh numbers and a "what changed" list.
- Full window with a zoomable treemap plus a side list (layout "A").
- Memory that does not grow with file count in RAM (see section 6).
- Internal disk and external drives.
- Safe cleanup through a review basket.

Non-goals (for now)
- Mac App Store distribution. Ship outside the store, signed and notarized.
- Network shares and NAS.
- Duplicate-file finding.
- Windows or Linux.

Anti-goals: the app has failed even if it technically works when:
- the UI ever beachballs or stutters during a scan or zoom;
- it deletes anything without the user reviewing it first;
- it shows a number that disagrees with reality without saying why (purgeable
  space, snapshots, clones, cloud placeholders);
- it looks like a generic template: no gradients, no glossy "bubbly" blocks, no
  retro costume. The founder rejected all three of those directions explicitly.

## 3. Surfaces

### 3.1 Menu bar item
- A thin ring that fills as the disk fills, followed by free space in GB
  (`82 GB`). Option in settings: icon only.
- Shows the internal disk by default.
- My call: ring and number turn amber below 15% free and red below 5%.

### 3.2 Dropdown (mockup: `dropdown-flat.html`)
Top to bottom:
1. **Drive tabs.** One per known drive, each with its tint dot. Disconnected
   drives appear dimmed with "last seen <date>" and their last data.
2. **Free space.** Large "82 GB free", the total, and space macOS can reclaim on
   its own (purgeable plus local snapshots).
3. **Disk bar.** Used space split by content type in the map's colors, then a
   finely ruled segment for reclaimable space, then free. A small key below.
4. **What changed.** Segmented switch Today / 7 days / 30 days. Four or five rows:
   type dot, name, location in grey, signed change (orange growth, green freed).
   A "Net" line under them. Clicking a row opens the full window zoomed to that
   item.
5. **Actions.** "Open map" and a primary "Review N GB to clear" that opens the
   basket pre-filled with the safe-to-clear items for that drive.
6. **Footer.** "Updated N min ago" and Settings (⌘,). For external drives,
   "Connected N min ago" and Eject.

Nothing is ever deleted from the dropdown.

### 3.3 Full window (mockup: `main-window-flat.html`)
Layout A: treemap on the left (~70%), sorted list on the right.

- **Toolbar.** Drive chip in the drive's tint with free space; breadcrumb
  (click any segment to go back up); search field that is also the command bar
  (⌘K).
- **Treemap.** Squarified. Click a block, or press ↵ on the selection, to zoom
  into it with a short animation (about 200 ms, off when Reduce Motion is on).
  Esc or the breadcrumb zooms out. Blocks are solid fills with 4px corners and
  2px gutters, white name plus size inside. Hover shows a white 2px inner
  outline and dims the other blocks. No glow, no scale, no gradient.
- **Growth strip.** A block that grew in the selected period shows a finely
  ruled strip along its right edge, drawn to scale (8.1 GB new out of 92 GB is
  about 9% of the block's width). This is the one expressive detail; keep it.
- **Small files.** Items below the drawing threshold are folded into one grey
  block per folder: "3,912 small files, 6 GB".
- **Hover card.** Name, size, change in the period, and for known items a
  one-line plain explanation and what to do ("The virtual disk Docker runs on.
  It grows but never shrinks by itself. Reclaim space in Docker › Settings ›
  Resources.").
- **Side list.** The children of the current zoom level, sorted by size, each
  with a type dot and a thin bar showing size relative to the largest sibling.
  Hover and selection are linked both ways with the map.
- **Bottom bar (Raycast style).** Selected item on the left; key hints on the
  right: Zoom in ↵, Quick Look Space, Add to basket ⌫, Actions ⌘K.
- **Basket.** A squared dark bar floating over the bottom of the map when it is
  non-empty: color chips for the items, count, total, "Review".

### 3.4 Basket and review
- Items get there by drag, ⌫, the ⌘K action, or "Review N GB to clear".
- Review sheet lists every item with path, size, and its explanation, each with
  a checkbox. One button: "Move N items to Trash".
- Deletion only ever means Move to Trash. The app never empties Trash.
- Items that should not be trashed but shrunk elsewhere (Docker.raw, Photos
  library, iOS backups managed by Finder) show the instruction instead of a
  checkbox.
- After moving, show "Freed 11.4 GB" and update all views immediately.

### 3.5 Junk lenses ("safe to clear")
A data-driven rule list (bundled JSON, updatable with app releases). Each rule
has: path pattern, display name, one-line explanation, safety level
(`regenerates` = safe, `review` = user should look, `app-managed` = shrink in
the owning app, never trash). Initial set: Xcode DerivedData, Xcode archives,
simulator runtimes and devices, `node_modules`, package-manager caches (npm,
yarn, pnpm, pip, Homebrew, Cargo, Gradle), `~/Library/Caches`, old installers
(`.dmg`, `.pkg` in Downloads older than 30 days), video proxies and render
caches (Final Cut, Premiere, DaVinci), Docker (app-managed), iOS backups
(app-managed), Trash (shown, not trashed).

## 4. Visual system

Native macOS window chrome, menus, and SF Pro. Personality lives in the map,
the color meaning, the growth strip, and the voice of the text.

Content-type colors (flat, shared by map, list dots, disk bar):

| Type | Hex |
|---|---|
| Apps | `#4C7CE0` |
| Virtual machines / containers | `#2E9FC4` |
| Developer | `#7A5FD6` |
| Photos and video | `#D45C7E` |
| Mail and documents | `#D9893A` |
| App data | `#3E9E7A` |
| Caches | `#6B7183` |
| Small files | grey at ~22% opacity of the label color |

Change colors: growth `#E8805F`, freed `#3FA67F`.

Drive tint: each drive gets a tint (internal default violet `#8B7BFF`,
externals picked from a small set, teal `#0FA39B` first), used on the drive
chip, tabs and selection highlight. My call: a palette of 8 tints, assigned
to new drives in order, and the user can pick a different one per drive in
Settings. Builder picks the other six hues.

Shape: 4px block corners, 2px gutters, 5 to 6px for controls, 10px for the
window and dropdown. No gradients anywhere except the fine ruled pattern that
marks reclaimable space and growth.

Dark and light both supported, following the system setting.

Voice: plain, short, a little dry. Explain what a thing is and what to do.
"Safe to clear. Rebuilds itself." Errors say what happened and how to fix it.

## 5. Platform and distribution (founder: "your call on tech", outside App Store)

- Swift. SwiftUI for windows and settings, AppKit for `NSStatusItem` and the
  dropdown panel. Treemap rendered with Metal.
- macOS 14 or newer.
- Distributed as a Developer ID signed, notarized download. Updates via
  Sparkle (my call).
- Needs Full Disk Access to see everything. First run explains why and deep-links
  to System Settings › Privacy & Security › Full Disk Access; without it the app
  works on what it can read and marks unreadable folders as such.
- Launch at login via `SMAppService.mainApp`, on by default after first run
  (user can turn off).
- My call: a single process. The app runs as a menu bar accessory
  (`LSUIElement`) and creates the full window on demand, releasing it and its
  map data on close. A Dock icon appears only while the window is open. A
  separate helper process is not needed for the memory targets.

## 6. Engine and memory

The core promise: RAM grows with the number of **folders**, not files, and
drawing cost depends on screen size, not file count.

### 6.1 Scanning
- Parallel directory walk with `getattrlistbulk`, a fixed 64 KB buffer per
  worker, a bounded work queue of folders. Never build the full tree in RAM.
- Attributes per entry: name, type, allocated size, logical size, inode/object
  ID, link count, flags (to spot iCloud dataless placeholders and clones), mtime.
- Count allocated size (what the disk actually spends). Show logical size in
  the hover card when it differs. Dataless cloud files count as ~0.
- Hard links: count once. Track only inodes with link count > 1.
- APFS clones: cannot be resolved per file cheaply; mark cloned files and note
  in the hover card that shared blocks may be counted more than once. (Builder
  may improve this.)
- Stay on one volume: do not cross mount points. Scan the internal disk via
  the Data volume so firmlinks are not double counted; report the system
  volume as one "macOS" block.
- Scanning runs at utility QoS, never on the main thread. Progressive results:
  the UI shows the biggest folders as soon as they are known and refines.

### 6.2 Index (per volume, on disk)
- Stored in `~/Library/Application Support/<app>/Volumes/<volume UUID>/`.
- Folder table in RAM: about 32 bytes per folder (parent index, total allocated
  size, file count, first child index, name reference).
- File table and name pool in a memory-mapped file: about 24 bytes per file plus
  names. macOS pages in only what is viewed and can drop clean pages under
  pressure.
- Files below the per-folder threshold are not stored individually; the folder
  keeps a small-files count and total. Threshold: my call, start at 1 MB or
  0.1% of the parent, whichever is larger; builder may tune.
- A global top-1000 largest files list, kept in a fixed-size heap.

### 6.3 Staying current without rescanning
- FSEvents stream per device (`FSEventStreamCreateRelativeToDevice`), storing
  the last event ID per volume so changes made while the app was not running,
  or while an external drive was unplugged, are caught up on next launch or
  mount. On a "must scan subdirs" or history-wrapped event, rescan only that
  subtree.
- Volumes without a persistent event journal (exFAT, FAT): rescan in the
  background, but only when the user opens that drive (my call).
- External drives are never woken or scanned on a timer.
- Volumes are keyed by UUID, so renaming or replugging keeps history.

### 6.4 History and "what changed"
- Once a day (and at app quit), store a snapshot of folder totals for folders
  at or above 100 MB, plus individual files at or above 500 MB, delta-encoded
  against the previous snapshot. Keep 90 days. A few KB per day.
- "What changed" diffs now against the snapshot at the period start, and
  attributes each change to the deepest item that accounts for at least 70% of
  its parent's change, so the list says "Docker.raw" and not "Library".
- Today is computed live from FSEvents-updated totals versus last night's
  snapshot.

  My call on the fallback: when no child reaches 70%, report the parent itself.
  Growth inside files below the storage threshold is reported as "small files
  in <folder>".
- The small-files threshold in 6.2 uses allocated size, like every size in the
  app.

### 6.5 Drawing
- Layout computed off the main thread for the current zoom level only.
  Squarified layout (Bruls, Huizing, van Wijk), children sorted by size
  descending.
- Rectangles under about 2 pt on screen are not drawn; they fold into the
  parent's small-files area. Layout never recurses below that size.
- Hard cap around 50,000 drawn rectangles at any zoom. If hit, the smallest
  siblings in each folder merge into one "N more items" block.
- My call: Metal draws only the treemap (blocks, labels, hover outline, dimming,
  growth strip), in an `MTKView` that redraws on change, not on a constant loop.
  Toolbar, side list, bottom bar, hover card and basket are native
  SwiftUI/AppKit views layered above or beside it.

### 6.6 Crash and quit safety
- Index and history files are written atomically (write to a temp file, then
  rename), with periodic checkpoints during long scans.
- A subtree being scanned is marked dirty until its results are committed. On
  relaunch, dirty subtrees are rescanned.
- The stored FSEvents event ID advances only after the matching changes are
  applied to the index, so nothing is lost if the app quits mid-update.

### 6.7 Numbers that match reality
- Free space from `volumeAvailableCapacityForImportantUsage` and
  `volumeAvailableCapacity`; the difference shown as "reclaimable".
- Local snapshots listed (via `tmutil listlocalsnapshots` or equivalent) and
  counted in reclaimable, with a hover explanation.

## 7. Targets

- Menu bar process idle: under 40 MB resident.
- Full window open on a 5-million-file disk: under 150 MB resident.
- Dropdown opens in under 100 ms.
- First full scan of an internal SSD: 30 to 90 s, with the UI responsive and
  first results within 3 s.
- Zoom animation at display refresh rate, no dropped frames on Apple silicon.
- Main thread never blocked for more than 16 ms by app work.

## 8. Decisions

By the founder
- Build a new, simpler app focused on no freezing and low memory.
- Menu bar icon with a dropdown that shows recent changes: direction A
  ("Pulse").
- Full window layout A: map plus side list.
- Visual style: modern (Raycast, CleanShot, Arc as references), flat, no
  gradients, not bubbly, not retro.
- Internal disk and external drives in scope.
- Ship outside the App Store for now. Tech choices delegated to Claude.

My calls (founder to check)
- Swift, SwiftUI plus AppKit, Metal, macOS 14+, Sparkle, single process.
- Amber/red thresholds at 15% / 5% free.
- Small-file threshold 1 MB or 0.1% of parent.
- History retention 90 days; snapshot thresholds 100 MB folders, 500 MB files.
- Non-journaled external drives rescan only when opened.
- Deletion is Move to Trash only; the app never empties Trash.
- Launch at login on by default.
- Metal draws only the treemap; everything around it is native views.
- "What changed" falls back to the parent when no child explains 70%.
- When the drawing cap is hit, smallest siblings merge into "N more items".
- 8 drive tints, assigned in order, changeable per drive.

## 9. Left to the builder

- Exact on-disk index format and file layout.
- Label fitting inside blocks.
- The six additional drive tint hues.
- The settings window contents beyond: menu bar display, launch at login,
  warning thresholds, drive tints, excluded folders.
- Test strategy, including synthetic trees of millions of files for memory
  and performance tests.
