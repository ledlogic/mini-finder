# UNIT9 Miniatures Catalog (mini-finder)

A local Ruby/Sinatra web app to browse, tag, search, and manage your UNIT9 Cyberdreams miniature image library.

---

## Requirements

- Ruby 4.0+ (`ruby -v` to check)
- Bundler (`gem install bundler`)
- Tesseract OCR (for non-MMF folder name detection)

---

## Setup

```bash
# 1. Enter the project folder
cd mini-finder

# 2. Install dependencies
bundle install

# 3. Create a .env file and set your root UNIT9 folder
echo ROOT_FOLDER=G:/My Drive/STL/UNIT9/Cyberdreams > .env
echo SESSION_SECRET=your-random-string-at-least-64-characters-long-goes-here >> .env

# 4. Run the app
ruby app.rb

# 5. Open your browser
#    http://localhost:4567
```

On first launch, hit **Scan Folder** in the sidebar to discover all images under your root folder. A backup of the database is created automatically on the first scan of each session.

---

## Interface Overview

### Catalog (`/catalog`)
- Lists all untagged images by default — toggle **Show All** to see everything
- Edit **Name, Species, Gender, Weapons, Stance, Size** inline per row
- Name, Species, Gender stacked in one column; Stance, Weapons stacked in another
- Size, Count, Printed, Painted, Colorized all stacked in the right counter column
- Hit **✓** to save a row; click **✎** for a full-page edit form with image preview
- Filter flags: **○ Untagged · 🖨 Unprinted · 🎨 Unpainted · 🎨 Color · ⬜ Grey · ◌ Unknown**
- Folder filter dropdown narrows to one collection; collection info bar shows name, month, PDF link
- Edit collection name inline from the catalog info bar
- Thumbnail size toggle S/M/L/XL persists in localStorage
- ⊙ button on thumbnails sets the collection cover image
- 🔗 checkbox links a colorized image as a secondary view of a grey primary
- ⤵ copy sibling button pre-fills fields from another image with the same name
- Images sorted within a collection: cover → bundles → alphabetical by name, secondaries follow their primary

### Collections (`/collections`)
- Card grid showing all scanned collections with cover image, stats, and quick links
- Year filter bar and status filter (All / 🖨 0 printed / 🎨 0 painted / 🖨 Partial)
- Sort toggle: newest first (default) / oldest first
- Stub cards for unscanned months from 2022-01 to present, each with a direct MMF search link
- Edit collection name and release month inline; detect name via OCR; set cover image
- Stats exclude bundles and secondary (linked) images from print/paint tracking

### Bulk Tag (`/bulk`)
- Grid view for quickly setting a single field across many images at once
- Field selector: Stance / Weapons / Gender / Species / Size / Colorized
- Filter by collection; all images checked by default
- Click value button → all checked images updated instantly via AJAX, cards fade on completion
- Text fields support free-text entry; fixed fields (Gender, Size, Colorized) use quick-pick buttons

### Search (`/search`)
- Free-text query across all fields with per-field filters
- Filter by Colorized status: Any / 🎨 Colorized / ⬜ Grey / ◌ Unknown
- Quick 🎨 / ⬜ / ◌ colorized toggle buttons on each result card (no page reload)
- Link to the collection directly from each result card
- **Scoring:** Name=4, Species=3, Weapons=2, Stance=1.5, Gender=1, Size=1
- Fuzzy matching via Levenshtein distance; match highlights in yellow (exact) and purple (fuzzy)

### Random (`/random`)
- Shows a random sample of images from the full catalog
- Filter row 1 — Color: All / 🎨 Color / ⬜ Grey / ◌ Unknown
- Filter row 2 — Show: 🚫 Bundles (toggle) / 🖨 Unprinted only
- Count selector: 10 / 20 / 30 / 60 / 90 / 120 / 180 / 240
- Size selector: S / M / L / XL (card grid width)
- Click an image to jump to its row in the catalog; **Shuffle** preserves all filters

### Edit (`/edit/:id`)
- Full-page form for a single image with preview
- Cross-reference (xref) dropdown to link as secondary to a grey primary in the same collection

---

## Getting Images (HAR Toolkit Workflow)

Mini-finder is designed to work alongside the **[HAR Toolkit](https://github.com/ledlogic/har-toolkit)** — a companion Java tool that extracts images from browser HAR files. Together they form a complete pipeline for building your local image library.

> Full workflow documented at: [ledlogic.blogspot.com — Unit 9/MMF Mini Finder](https://ledlogic.blogspot.com/2026/06/claude-ai-tools-june-2026.html)

### Step-by-step

1. **Browse MyMiniFactory** — visit the UNIT9 collection page for a given month and step through the images in your browser

2. **Capture a HAR file** — open browser DevTools (F12), go to the **Network** tab, reload/navigate the page, then:
   - Right-click any request → *Save all as HAR with content*
   - Save the `.har` file to a working folder

3. **Run HarImageApp** — extract the images from the HAR:
   ```bash
   java -jar har-toolkit.jar <path-to.har> --output-dir "G:/My Drive/STL/UNIT9/Cyberdreams"
   ```
   - Saves images to a folder named `YYYY-MM` (e.g. `2024-03`) or `YYYY-MM-mmf` for MMF releases
   - Prefers large images (>1000px); falls back to `720X720` previews if that's all that's available
   - Skips `70x70` and `230x230` thumbnail URLs automatically

4. **Alternatively use MmfImageApp** — for MMF pages directly (no HAR needed):
   ```bash
   java -jar har-toolkit.jar mmf <mmf-object-url> --output-dir "G:/My Drive/STL/UNIT9/Cyberdreams"
   ```
   - Fetches the page directly and downloads all CDN images
   - Use `--cookie "..."` if you get a 403 (copy Cookie header from browser DevTools)

5. **Scan in Mini-finder** — click **Scan Folder** in the sidebar
   - New images are registered automatically
   - MMF folder names (`yyyy-mm-mmf`) trigger filename-based name extraction (no OCR)
   - Standard folder names trigger Tesseract OCR to detect mini name and collection name
   - Plain `yyyy-mm` folders are automatically superseded by `-mmf` siblings

### Folder naming conventions

| Folder pattern | Meaning |
|---|---|
| `2024-03-mmf` | MMF release, March 2024 — names extracted from filenames |
| `2024-03` | Standard release — names extracted via OCR |
| `2024-03-cd` | Alternate/additional images — **skipped by scanner** |


---

## Scanning

- **Scan Folder** (top of sidebar) discovers new images, auto-registers collections, and auto-detects names
- MMF folders (`yyyy-mm-mmf`): names extracted from filenames, no OCR needed
- Standard folders: Tesseract OCR extracts name and collection name from the image
- Plain `yyyy-mm` folders are automatically removed if an `-mmf` sibling exists
- `-cd` folders are skipped and removed
- Missing folders are purged from the database on each scan
- Chained secondary links (A→B→C) are resolved to direct links (A→C) on startup

---

## Backup

- A timestamped backup of `catalog.db` is created automatically on the **first scan of each session**
- **Backup** button in the sidebar footer for manual snapshots at any time
- After **25 unsaved changes** the Backup button pulses amber as a reminder
- Backups stored in `db/backups/`, keeping the most recent 20
- DB size shown in sidebar footer

---

## Maintenance Scripts

Located in `scripts/`:

| Script | Purpose |
|---|---|
| `rename_collection_folder.rb` | Rename a folder on disk and update all DB references (e.g. `2021-11` → `2021-11-mmf`) |
| `remove_small_images.rb` | Find/remove images below a size threshold (default 500px) |
| `remove_mmf_collection.rb` | Remove plain `yyyy-mm` collections when `-mmf` sibling exists (manual) |
| `backfill_collections.rb` | Backfill collection records for existing images |
| `ocr_collections.rb` | Re-run OCR on collection images to detect names |
| `export_samples.rb` | Export sample images for testing |

---

## Data

- Database: `db/catalog.db` (SQLite — single file, portable)
- Backups: `db/backups/catalog-YYYYMMDD-HHMMSS-{label}.db`
- Images served directly from your local disk — no copying
- Multi-value fields store comma-separated lists (e.g. `M,F` for mixed-gender scenes)
- `colorized` field: `NULL` = unknown, `true` = rendered/colored, `false` = grey 3D print

---

## Folder Structure

```
mini-finder/
├── app.rb                  # Sinatra app — config, DB schema, routes only
├── Gemfile
├── .env                    # ROOT_FOLDER and SESSION_SECRET (not committed)
├── db/
│   ├── catalog.db          # Created automatically on first run
│   └── backups/            # Timestamped DB backups
├── lib/                    # Helper modules (loaded by app.rb)
│   ├── helpers.rb          # Search scoring, view helpers (levenshtein, score_row, hl_field)
│   ├── url_helpers.rb      # URL builders — url_pdf, url_random, url_collections, url_mmf_search
│   ├── file_helpers.rb     # Filesystem helpers — file_image_path, file_mmf_folder?, etc.
│   ├── ocr_helpers.rb      # OCR pipeline — ocr_unit9_image, ocr_clean_line, etc.
│   └── db_helpers.rb       # DB helpers — db_scan_folder, db_purge_missing_collections, db_make_backup
├── public/
│   ├── css/style.css       # Dark cyberpunk theme (Oxanium + DM Mono fonts)
│   └── js/app.js           # Lightbox, autocomplete, dirty-state, inline helpers
├── scripts/                # One-off maintenance scripts
│   ├── rename_collection_folder.rb
│   ├── remove_small_images.rb
│   └── ...
└── views/
    ├── layout.erb          # Shared nav, sidebar, toast, backup button
    ├── catalog.erb         # Main image table with inline editing
    ├── collections.erb     # Collection card grid
    ├── bulk.erb            # Bulk field tagger
    ├── edit.erb            # Full single-image edit form
    ├── search.erb          # Fuzzy search with filters
    └── random.erb          # Random image sampler
```

---

## Tips

- **Scan** is safe to run multiple times — skips already-registered files
- Image dimensions are read from the filename (e.g. `720X720`) automatically
- The `tagged` flag is set automatically when a Name is saved
- To move the database, copy `db/catalog.db` — all metadata travels with it
- Collection names are auto-uppercased on save
- Mini names are auto-capitalised (Title Case) on save
- Secondary images (xref) inherit their primary's sort position in the catalog
- Bundle images (`mini_count ≥ 4` or named "Bundle") are excluded from print/paint tracking

---

## Built With Claude AI

This project was designed and built collaboratively with **Claude Sonnet 4.6** (Anthropic) through an extended back-and-forth pairing session.

**Session stats:**
- Started: June 6, 2026
- Last updated: June 19, 2026
- Model: Claude Sonnet 4.6 (`claude-sonnet-4-6`)
- Exchanges: 200+ back-and-forth messages across 3 conversation sessions
- Code produced:
  - ~2,350 lines of Ruby
  - ~1,800 lines of ERB templates
  - ~2,000 lines of CSS
  - ~630 lines of JavaScript

**What Claude helped with:**
- Full application architecture (Sinatra, Sequel, SQLite schema, migrations)
- All Ruby routes, helper modules, and scanner logic
- OCR pipeline for UNIT9 image name extraction (MiniMagick + Tesseract)
- Inline editing UI, lightbox, autocomplete, dirty-state tracking
- Fuzzy search scoring (Levenshtein) with dynamic score slider
- Bulk tagger, random image sampler with count/filter controls
- Cross-reference (xref) secondary image linking system
- Colorized/grey image classification and filtering with alert banners
- Collection management: cover images, stubs, year/sort filters, `/collection/:id` route
- Statistics page: species, gender, stance, weapons, print/paint breakdowns with live links
- Backup system with session-aware auto-backup and change counter
- Major refactoring: separation of concerns across `lib/helpers.rb`, `lib/url_helpers.rb`, `lib/file_helpers.rb`, `lib/ocr_helpers.rb`, `lib/db_helpers.rb`
- Consistent method naming conventions (`url_*`, `file_*`, `ocr_*`, `db_*`, `catalog_*`, `str_*`)
- This README

> *"All code was reviewed and guided by a human developer throughout. Claude handled implementation; the human handled direction, testing, and domain knowledge about UNIT9 miniatures."*