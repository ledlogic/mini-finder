# UNIT9 Miniatures Catalog

A local Ruby/Sinatra web app to browse, tag, and search your UNIT9 miniature image library.

---

## Requirements

- Ruby 3.0+ (`ruby -v` to check)
- Bundler (`gem install bundler`)

---

## Setup

```bash
# 1. Enter the project folder
cd unit9_catalog

# 2. Install dependencies
bundle install

# 3. Set your root UNIT9 folder (Windows path, forward slashes are fine)
#    Option A: environment variable (recommended)
set ROOT_FOLDER=G:/My Drive/STL/UNIT9      # Windows CMD
$env:ROOT_FOLDER="G:/My Drive/STL/UNIT9"   # Windows PowerShell
export ROOT_FOLDER="G:/My Drive/STL/UNIT9" # macOS/Linux

# 4. Run the app
ruby app.rb

# 5. Open your browser
#    http://localhost:4567
```

On first launch, hit **Scan Folder** in the sidebar to discover all images under your root folder.

---

## Interface Overview

### Catalog (`/catalog`)
- Lists all untagged images by default — toggle to show all
- Edit **Name, Species, Gender, Weapons, Stance, Size** inline per row
- Hit **✓** (or press **Enter**) to save a row
- Click **✎** for a full-page edit form with image preview
- Thumbnails are clickable to open a full lightbox
- Paginated at 25 per page

### Edit (`/edit/:id`)
- Full-page form for a single image
- Gender and Size use checkboxes (supports multiple values, e.g. M+F on a scene)

### Search (`/search`)
- Free-text query across all fields
- Optional per-field filters (Name, Species, Gender, Weapons, Stance, Size)
- **Scoring:**
  - Exact field match: full weight (Name=4, Species=3, Weapons=2, Stance=1.5, Gender=1, Size=1)
  - Free-text term in any field: +1.5 per hit
  - Fuzzy match (Levenshtein ≤40% edit distance): half weight
- Results sorted by score (highest first)
- Match highlights in yellow (exact) and purple (fuzzy)
- Colored match tags show which fields triggered which terms
- Click the image to enlarge; click **Edit ✎** to jump to the edit form

---

## Data

- Database: `db/catalog.db` (SQLite — single file, portable)
- Images are served directly from your local disk — no copying
- Multi-value fields (Name, Species, Weapons, Stance) store comma-separated lists

---

## Folder Structure

```
unit9_catalog/
├── app.rb              # Main Sinatra application
├── Gemfile
├── db/
│   └── catalog.db      # Created automatically on first run
├── public/
│   ├── css/style.css
│   └── js/app.js
└── views/
    ├── layout.erb
    ├── catalog.erb
    ├── edit.erb
    └── search.erb
```

---

## Tips

- **Scan** is safe to run multiple times — it skips already-registered files
- Image dimensions are read from the filename (e.g. `1080x1080`) automatically
- The `tagged` flag is set automatically when a Name is saved
- To move the database, copy `db/catalog.db` — all metadata travels with it
