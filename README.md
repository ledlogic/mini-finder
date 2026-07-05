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

## Changelog

### v1.99 — July 4, 2026
- Stance and weapons quick-pick buttons hidden when field already has a value; only shown when blank

### v1.98 — July 4, 2026
- CSS split into 5 focused files (style.css retired):
  - `mf-base.css` — fonts, variables, layout, nav, toast (157 lines)
  - `mf-components.css` — reusable widgets: buttons, autocomplete, lightbox, modals, alerts (589 lines)
  - `mf-catalog.css` — catalog table, rows, cells, xref, info bar, filter pills (712 lines)
  - `mf-collections.css` — collections page: cards, thumbnails, stubs, filter bar (313 lines)
  - `mf-pages.css` — edit, search, bulk tagger, statistics page styles (425 lines)

### v1.97 — July 4, 2026
- Stance and species quick-pick buttons now DB-frequency ordered (most used first), fallback list for sparse DBs
- Fixes AIMING and other common stances not appearing due to hardcoded core list taking priority

### v1.96 — July 4, 2026
- Weapons quick-pick buttons now ordered by DB frequency (most used first), not hardcoded list
- NONE always pinned first; fallback list used only when DB is sparse
- MACHINE GUN and other multi-word weapons now correctly appear when they lead the stats

### v1.95 — July 4, 2026
- JS split into four focused files: `mf-autocomplete.js`, `mf-actions.js`, `mf-catalog.js`, `mf-ui.js`; `app.js` retired

### v1.94
- Selecting ROBOT, VEHICLE, DRONE, CONSTRUCT, or BEAST species auto-sets gender to NA with cyan flash
- `NA_GENDER_SPECIES` constant; `applySpeciesRules()` triggered from quickpick and species input blur/change
- Rule also applies on edit page via `editQuickpick()`

### v1.93
- Weapons quick-pick buttons added to catalog rows and edit page (NONE · SWORD · PISTOL · RIFLE · KNIFE · STAFF · SHIELD · BOW · AXE)
- NONE always pinned as first weapon button regardless of DB frequency
- `setFieldQuickpick()` and `editQuickpick()` use `data-*` attributes to avoid HTML quote conflicts

### v1.92
- After saving a row with an xref assigned, page reloads automatically so secondary ordering updates
- Species and stance quick-pick buttons fixed (were silently broken due to single-quote conflicts in onclick)
- `setFieldQuickpick(btn)` reads from `data-field` / `data-value` data attributes

### v1.91
- Stance quick-pick buttons added to catalog rows and edit page (STANDING · CROUCHING · RUNNING · KNEELING · CHARGING · PRONE · JUMPING · COMBAT)
- `@top_stance` computed in `catalog_build_images` helper and edit route
- `setFieldQuickpick()` generic function handles both species and stance

### v1.90
- Species quick-pick buttons added to catalog rows and edit page
- Core species always shown: HUMAN · ROBOT · VEHICLE · ALIEN · CREATURE · UNDEAD · BEAST
- DB most-common species fill remaining slots up to 8
- `@top_species` computed in `catalog_build_images` helper and edit route

### v1.89 — July 3, 2026
- Random 🚫 Vehicles filter now also excludes xref secondaries (colorized renders) linked to vehicle primaries

### v1.88 — July 3, 2026
- Random page: 🚫 Vehicles filter toggle — excludes images by species=VEHICLE and common vehicle name keywords
- Dynamic HTML page titles per route and collection name
- Collection name input width now fills available bar space (flex:1, max-width 420px)
- `collection-info-left` and `col-info-name-form` made flex:1 so name input stretches properly

### v1.87 — July 3, 2026
- Collection name input min-width widened to 220px to fit longer names like "BLACK STONE COMMANDOS"
- Collection name save button changed to orange/red (`var(--accent2)`) to match dirty-state convention
- `autocomplete="off"` added to all catalog row inputs, selects, and the table element to prevent Chrome autofill interference
- Chrome autofill dark background override via `-webkit-autofill` CSS

### v1.86
- Weapons input style fixed: moved `text-transform:uppercase` to CSS class `cell-input-upper` so dark background renders correctly
- Save button background properly resets to green after successful `saveRow()` save
- Dirty-state baseline resets after save so button doesn't re-red unnecessarily
- Enter key in catalog rows now triggers `saveRow()` via `btn.click()` instead of stale `form.requestSubmit()`

### v1.85
- 💡 OCR lightbulb button per catalog row: retry name detection inline without leaving the page
- Fills name field directly if empty; shows suggestion button if name already set
- `detectName()` JS function added to app.js

### v1.84
- Autocomplete dropdown: confirmed (blue) names always sort above OCR suggestions
- Suppress all alternatives when query is within 1 edit distance of a confirmed name
- `change` event added alongside `input` on dirty-state watcher so selects trigger correctly

### v1.83 — July 2, 2026
- Chrome autofill dark background fix (`-webkit-autofill` override)
- Weapons input styled consistently with other inputs (moved `text-transform` to CSS class)
- Autocomplete dropdown: confirmed (blue) names always sort above OCR suggestions; suppress all alternatives when query is within 1 character of a confirmed name
- 💡 OCR lightbulb button per image row: retry name detection inline, fills or suggests
- `saveRow()` resets dirty-state baseline after save so button returns to green correctly
- Enter key in catalog rows triggers `saveRow()` instead of stale `form.requestSubmit()`
- Chrome DevTools probe (`/.well-known/appspecific/com.chrome.devtools.json`) silenced with empty JSON response

### v1.82
- Delete image: 🗑 button converted from nested form to pure JS `deleteImage()` fetch — fixes nested-form bug where delete was silently ignored
- Save row: converted from HTML form submit to pure JS `saveRow()` via fetch — no more nested forms in catalog rows
- Dirty-state watcher stores baseline on `row._dirtyOriginals`; resets after successful save
- Save button background resets to green on successful save

### v1.81
- Statistics page: Overview and Colorized on same row; Print and Paint as separate cards
- Statistics: weapons table added; all stats show full data (no Top 20 cap)
- Statistics: species, gender, size, weapons, stance all linkable to search/catalog/bulk
- Score slider on search: debounced 180ms, label updates instantly, `min-height` prevents layout shift

### v1.80
- `/statistics` route with full stats page: overview, colorized, print/paint, species, gender, size, weapons, stance
- Statistics nav link added to sidebar

### v1.79
- `/collection/:id` links used consistently across all pages (collections, random, search, catalog)
- Collection name header in catalog rows links to `/collection/:id` when browsing full catalog, plain text when inside a collection
- Folder name row hidden entirely when in collection view; column header changes to "File"
- "Edit collection ✎" link removed from row header
- Random page cards show collection name as link

### v1.78
- Unlinked colorized alert banner on `/collections` and `/collection/:id`
- Missing bundle/gallery image alert (purple) on collection pages
- Collection name in catalog info bar is a clickable browse link

### v1.77
- `/collection/:id` dedicated route sharing `catalog_setup_params` + `catalog_build_images` helpers
- `catalog_sort_images` and `catalog_collection_images` extracted to `lib/helpers.rb`
- All `catalog?folder=` links replaced with `/collection/:id`

### v1.76 — June 19, 2026
- Pure JS row actions — save (✓), delete (🗑) no longer use HTML forms; eliminates nested-form bugs
- Delete image: 🗑 button deletes file from disk and removes DB record with confirm dialog
- Action button sizing unified (28×28px, box-sizing, display:contents on delete form)
- `saveRow()` posts via fetch, server returns JSON; page does not reload on save
- App version constant (`APP_VERSION`) displayed in sidebar footer

### v1.75
- Statistics page (`/statistics`): overview, colorized, print/paint, species, gender, size, weapons, stance — all with clickable links
- Score slider on search page: dynamic client-side filter with 180ms debounce, no page reload
- Weapons forced uppercase on save and in bulk set; UI inputs show `text-transform: uppercase`

### v1.74
- `/collection/:id` route — dedicated single-collection endpoint sharing catalog helpers
- `catalog_setup_params` and `catalog_build_images` extracted to `lib/helpers.rb`
- `catalog_sort_images` and `catalog_collection_images` helper methods
- All `catalog?folder=` links replaced with `/collection/:id` across collections, search, random pages
- Collection name header in catalog rows is a link when browsing full catalog, plain text in collection view
- "Folder / File" column header changes to "File" when in collection view
- Folder name row hidden entirely when already in a collection view

### v1.73
- Unlinked colorized alert banner on both `/collections` and `/collection/:id` pages
- Missing bundle/gallery image alert (purple) on collection pages
- Collection name in catalog info bar is a clickable browse link
- Collection name header in row groups is a clickable link to `/collection/:id`
- "Edit collection ✎" link removed from row header (redundant with name click)

### v1.72
- DB schema and chain-fix moved to `lib/db_helpers.rb` as `db_setup_schema` / `db_fix_chained_secondaries`
- `db_setup_schema` and `db_fix_chained_secondaries` are top-level defs (not Sinatra helpers) called at startup

### v1.71
- Major helper refactor: all methods moved from `app.rb` into `lib/` subfolder
- `lib/helpers.rb` — search scoring, view helpers (`str_levenshtein`, `score_row`, `hl_field`)
- `lib/url_helpers.rb` — URL builders (`url_pdf`, `url_random`, `url_collections`, `url_mmf_search`, `url_query`)
- `lib/file_helpers.rb` — filesystem helpers (`file_image_path`, `file_mmf_folder?`, etc.)
- `lib/ocr_helpers.rb` — OCR pipeline (`ocr_unit9_image`, `ocr_clean_line`, etc.)
- `lib/db_helpers.rb` — DB helpers (`db_scan_folder`, `db_purge_missing_collections`, `db_make_backup`)
- Consistent method naming conventions: `url_*`, `file_*`, `ocr_*`, `db_*`, `catalog_*`, `str_*`
- `OCR_CROP_ZONES` renamed from `CROP_ZONES`
- `levenshtein` renamed to `str_levenshtein`

### v1.70
- Collections page sort toggle: newest first (default) / oldest first
- `/random` page: No Bundles toggle, Unprinted only toggle, Count selector (10–240), all filters persist through Shuffle
- Xref dropdown auto-checks the 🔗 checkbox when a primary image is selected
- Grey/grey xref supported (e.g. back of mini → front of mini)

### v1.69
- Pagination removed when ≤50 images in view (threshold raised to 50 per page)
- Collections page unlinked colorized alert with counts and direct links
- `url_query` (was `q`) URL query string builder

### v1.68
- Bulk Tag page: stance, weapons, gender, species, mini_size, colorized fields
- Random page with color, size, and shuffle filters
- Search page: colorized filter dropdown and quick 🎨/⬜/◌ toggle buttons on result cards
- Fuzzy search scoring with Levenshtein distance and match highlights

### v1.67
- Collections page: year filter bar, status filter, stub cards for unscanned months with MMF links
- Cover image set via ⊙ button; cover sorts first in catalog
- ⤵ copy sibling button pre-fills fields from another image with same name
- Inline collection name rename from catalog info bar

### v1.66
- Backup system: auto-backup on first scan of session, manual Backup button, 25-change reminder
- `db_make_backup` with timestamped files, keeps 20 most recent

### v1.65
- Cross-reference (xref) secondary image linking — colorized renders linked to grey primaries
- Primary/secondary sort: cover → bundles → primaries (alpha), each followed by secondaries
- Colorized/grey/unknown classification with 🎨/⬜/◌ filter flags

### v1.60
- MMF folder support (`yyyy-mm-mmf`): names extracted from filenames, no OCR needed
- `file_extract_mmf_name` parsing CamelCase MMF filenames
- Plain `yyyy-mm` folders auto-removed when `-mmf` sibling exists

### v1.50
- OCR pipeline for UNIT9 image name extraction (MiniMagick + Tesseract, 6 crop zones)
- `ocr_unit9_image` with zone scoring, accent normalisation, multi-line name collapse

### v1.40
- Full catalog with inline editing: name, species, gender, weapons, stance, size, count, printed, painted
- Print/paint counts (0–10) excluding bundles and secondaries
- Flag filters: Untagged, Unprinted, Unpainted, Colorized, Grey, Unknown

### v1.30
- Collection management: cover images, release month, notes, rename
- Collection card grid with stats and quick links

### v1.20
- Image scanner: discovers images, creates collections, extracts names
- SQLite schema via Sequel; images and collections tables with migrations

### v1.10
- Initial Sinatra app: catalog, edit, search routes
- SQLite DB, dark cyberpunk theme (Oxanium + DM Mono)

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
