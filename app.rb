require 'dotenv/load'
require 'sinatra'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'pathname'
require 'cgi'
require 'date'
require 'fileutils'
require 'rtesseract'
require 'mini_magick'

# ─── Configuration ────────────────────────────────────────────────────────────

configure do
  set :port, 4567
  set :bind, '127.0.0.1'
  set :views, File.join(File.dirname(__FILE__), 'views')
  set :public_folder, File.join(File.dirname(__FILE__), 'public')
  set :root_folder, ENV.fetch('ROOT_FOLDER', 'G:/My Drive/STL/UNIT9')
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET', 'mini-finder-secret-key-please-change-this-in-production-it-must-be-64-bytes-long!!')
end

# ─── Backup helpers ───────────────────────────────────────────────────────────
DB_PATH      = File.join(File.dirname(__FILE__), 'db', 'catalog.db')
BACKUP_DIR   = File.join(File.dirname(__FILE__), 'db', 'backups')
BACKUP_KEEP  = 20   # how many backups to retain

def make_backup(label = 'manual')
  FileUtils.mkdir_p(BACKUP_DIR)
  ts   = Time.now.strftime('%Y%m%d-%H%M%S')
  dest = File.join(BACKUP_DIR, "catalog-#{ts}-#{label}.db")
  FileUtils.cp(DB_PATH, dest)
  # Prune old backups, keeping the most recent BACKUP_KEEP
  backups = Dir.glob(File.join(BACKUP_DIR, 'catalog-*.db')).sort
  if backups.length > BACKUP_KEEP
    backups[0..-(BACKUP_KEEP + 1)].each { |f| File.delete(f) }
  end
  dest
end

CHANGES_BEFORE_REMINDER = 25

# ─── Database ─────────────────────────────────────────────────────────────────

DB = Sequel.sqlite(File.join(File.dirname(__FILE__), 'db', 'catalog.db'))

# Collections — one per folder
DB.create_table?(:collections) do
  primary_key :id
  String   :folder_path,    null: false, unique: true
  String   :name                          # e.g. "ASH NOMADS"
  String   :release_month                 # e.g. "2026-02" parsed from folder
  String   :notes
  Integer  :cover_image_id
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

# Images — belong to a collection
DB.create_table?(:images) do
  primary_key :id
  foreign_key :collection_id, :collections
  String   :source_folder,  null: false
  String   :filename,       null: false
  String   :image_size
  String   :suggested_name               # from OCR line 1
  String   :mini_name                    # confirmed by user
  String   :species
  String   :gender
  String   :weapons
  String   :stance
  String   :mini_size
  String   :notes
  String   :description
  Integer  :mini_count, default: 1
  Integer  :printed,    default: 0
  Integer  :painted,    default: 0
  Boolean  :tagged,     default: false
  Boolean  :colorized,  default: nil   # nil=unknown, true=rendered, false=3d grey
  Integer  :primary_image_id              # if set, this image is a secondary
                                           # (alt view) of another image
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

# Migrations — add columns to existing DBs that predate this version
[
  "ALTER TABLE images ADD COLUMN collection_id INTEGER REFERENCES collections(id)",
  "ALTER TABLE images ADD COLUMN suggested_name TEXT",
  "ALTER TABLE images ADD COLUMN description TEXT",
  "ALTER TABLE images ADD COLUMN mini_count INTEGER DEFAULT 1",
  "ALTER TABLE images ADD COLUMN printed INTEGER DEFAULT 0",
  "ALTER TABLE images ADD COLUMN painted INTEGER DEFAULT 0",
  "ALTER TABLE collections ADD COLUMN release_month TEXT",
  "ALTER TABLE collections ADD COLUMN notes TEXT",
  "ALTER TABLE collections ADD COLUMN cover_image_id INTEGER",
  "ALTER TABLE images ADD COLUMN primary_image_id INTEGER",
  "ALTER TABLE images ADD COLUMN colorized BOOLEAN DEFAULT NULL",
].each do |sql|
  begin; DB.run(sql); rescue Sequel::DatabaseError; end
end

Collections = DB[:collections]
Images      = DB[:images]

# ─── Fix chained secondaries ──────────────────────────────────────────────────
# A secondary should only ever point to a primary (primary_image_id = nil).
# If secondary A points to secondary B which points to primary C, fix A -> C.
# If secondary A points to another secondary that itself has no primary found,
# clear A's link entirely.
begin
  fixed = 0
  Images.where(Sequel.~(primary_image_id: nil)).each do |img|
    target = Images.where(id: img[:primary_image_id]).first
    next unless target                          # orphaned link — leave for scan cleanup
    next if target[:primary_image_id].nil?     # already points to a primary, ok

    # Target is itself a secondary — walk the chain to find the real primary
    seen = [img[:id]]
    cursor = target
    while cursor && !cursor[:primary_image_id].nil?
      break if seen.include?(cursor[:id])       # circular, break
      seen << cursor[:id]
      cursor = Images.where(id: cursor[:primary_image_id]).first
    end

    new_primary = cursor && cursor[:primary_image_id].nil? ? cursor[:id] : nil
    Images.where(id: img[:id]).update(primary_image_id: new_primary, updated_at: Time.now)
    fixed += 1
    puts "  [chain-fix] image #{img[:id]} -> #{new_primary.inspect} (was #{img[:primary_image_id]})"
  end
  puts "Chain fix: #{fixed} image(s) corrected." if fixed > 0
rescue => e
  puts "Chain fix error: #{e.message}"
end

# ─── Constants ────────────────────────────────────────────────────────────────

FIELD_WEIGHTS = {
  mini_name: 4.0,
  species:   3.0,
  weapons:   2.0,
  stance:    1.5,
  gender:    1.0,
  mini_size: 1.0
}.freeze

SUPPORTED_EXTS = %w[.png .jpg .jpeg .gif .webp .bmp].freeze

# ─── OCR ──────────────────────────────────────────────────────────────────────

# From analysing UNIT9 image samples, the name block is consistently in the
# right 60% of the image, between y=65% and y=88%. We use one wide crop zone
# that captures this whole region, then parse it carefully.
#
# Key findings from sample analysis:
#   - Names are always right-aligned in the bottom portion
#   - Collection name appears on a darker bar below the mini name
#   - Accented chars (Ō, Ū, É) need to be normalised
#   - Mixed case names exist (e.g. "Nomads Tribe", "Security Officer")
#   - Multi-line names need joining (e.g. DANNY / 'ROAD RAMBLER' / WILLIAMS)
#   - 2024+ folders contain small thumbnails — skip OCR if image < 400px wide

MIN_OCR_WIDTH = 400  # skip images too small for reliable OCR

# ─── MMF filename name extraction ─────────────────────────────────────────────

# Detect if a folder is an MMF folder (ends in -mmf)
def mmf_folder?(folder_path)
  File.basename(folder_path).end_with?('-mmf')
end

# Extract the base month from an MMF folder name e.g. "2026-06-mmf" -> "2026-06"
def mmf_base_month(folder_path)
  File.basename(folder_path).sub(/-mmf$/, '')
end

# Extract mini name from MMF filename by stripping prefix/suffix and splitting CamelCase
# e.g. "0002_June24-adv-1080-XiuYing02.jpg" -> "Xiu Ying"
BUNDLE_WORDS    = %w[together bundle pack set group].freeze
SKIP_NAME_WORDS = %w[adv img page].freeze

def extract_mmf_name(filename)
  name  = File.basename(filename, '.*')
  name  = name.sub(/^\d+_/, '')
  raw   = name.split('-').last.to_s
  raw   = raw.sub(/\d+$/, '').strip
  return nil if raw.empty?
  # Map bundle/group words to "Bundle"
  return 'Bundle' if BUNDLE_WORDS.include?(raw.downcase)
  # Skip noise words
  return nil if SKIP_NAME_WORDS.include?(raw.downcase)
  # Split CamelCase into space-separated words
  raw.gsub(/([A-Z])/, ' \\1').strip
end
CROP_ZONES = [
  { label: 'name-block-high',       x: 0.38, y: 0.63, w: 0.62, h: 0.20 },
  { label: 'name-block-mid',        x: 0.38, y: 0.70, w: 0.62, h: 0.20 },
  { label: 'name-block-low',        x: 0.38, y: 0.76, w: 0.62, h: 0.18 },
  { label: 'name-block-bottom',     x: 0.38, y: 0.80, w: 0.62, h: 0.18 },
  { label: 'name-block-wider',      x: 0.30, y: 0.63, w: 0.70, h: 0.25 },
  { label: 'name-block-right-only', x: 0.52, y: 0.72, w: 0.48, h: 0.26 },
].freeze

# Normalise accented characters Tesseract commonly mangles
def normalise_accents(str)
  str
    .gsub(/[ŌÖO]\s*(?=[A-Z])/, 'O')  # Ō → O mid-word
    .gsub(/Ō/, 'O').gsub(/ō/, 'o')
    .gsub(/Ū/, 'U').gsub(/ū/, 'u')
    .gsub(/É/, 'E').gsub(/é/, 'e')
    .gsub(/Á/, 'A').gsub(/á/, 'a')
    .gsub(/Í/, 'I').gsub(/í/, 'i')
end

# Clean a raw OCR line into a usable name candidate.
# More permissive than before — allows mixed case and some punctuation.
def clean_ocr_line(line)
  # Strip leading noise characters (non-alpha, non-quote)
  cleaned = line.gsub(/^[^A-Za-z\'\"-]+/, '').strip
  # Remove characters that are definitely noise, keep apostrophes/hyphens
  cleaned = cleaned.gsub(/[|\\@#$%^&*_=<>{}\[\]]/, '').strip
  # Collapse multiple spaces
  cleaned = cleaned.gsub(/\s+/, ' ').strip
  # Must be at least 2 chars and mostly letters (allow short names like JI, SAN)
  letter_ratio = cleaned.gsub(/[^A-Za-z]/, '').length.to_f / [cleaned.length, 1].max
  return nil if cleaned.length < 2 || letter_ratio < 0.4
  normalise_accents(cleaned)
end

# Try to join split names e.g. YŪGEN / JII-SAN across two OCR lines
def join_split_name(lines)
  return lines if lines.length < 2
  collection_words = /corp|friends|raiders|nomads|officer|sisters|squad|tribe/i
  result = []
  i = 0
  while i < lines.length
    line = lines[i]
    next_line = lines[i + 1] if i + 1 < lines.length
    if next_line &&
       line.split.length <= 2 &&
       next_line.split.length <= 3 &&
       !next_line.match?(collection_words) &&
       !line.match?(collection_words)
      result << "#{line} #{next_line}"
      i += 2
    else
      result << line
      i += 1
    end
  end
  result
end
def zone_score(names)
  names.sum { |n| n.split.length * n.length }
end

# Collapse multi-line names: if two consecutive lines look like parts of the
# same name (short lines, no collection-bar separator), join them.
def collapse_name_lines(lines)
  return lines if lines.length < 2
  result = []
  i = 0
  while i < lines.length
    line = lines[i]
    # If next line exists and both are short-ish, they may be one multi-line name
    if i + 1 < lines.length
      next_line = lines[i + 1]
      combined_words = (line + ' ' + next_line).split.length
      # Join if combined would be ≤6 words and neither looks like a collection tag
      if combined_words <= 6 && !next_line.include?('.') && line.split.length <= 3
        result << (line + ' ' + next_line)
        i += 2
        next
      end
    end
    result << line
    i += 1
  end
  result
end

# Extract mini name and collection name from a UNIT9 image.
# Returns { suggested_name: String|nil, collection_name: String|nil }
def ocr_unit9_image(image_path)
  return { suggested_name: nil, collection_name: nil } unless File.exist?(image_path)

  orig = MiniMagick::Image.open(image_path)
  w    = orig.width
  h    = orig.height

  # Skip tiny thumbnails — not full artwork
  if w < MIN_OCR_WIDTH || h < MIN_OCR_WIDTH
    return { suggested_name: nil, collection_name: nil }
  end

  best_names = []
  best_score = 0

  CROP_ZONES.each do |zone|
    img    = MiniMagick::Image.open(image_path)
    crop_w = (w * zone[:w]).to_i
    crop_h = (h * zone[:h]).to_i
    crop_x = (w * zone[:x]).to_i
    crop_y = (h * zone[:y]).to_i

    img.crop "#{crop_w}x#{crop_h}+#{crop_x}+#{crop_y}"
    img.colorspace 'Gray'
    # Boost contrast to make text stand out against dark backgrounds
    img.contrast
    img.contrast

    tmp = File.join(Dir.tmpdir, "unit9_ocr_#{Time.now.to_i}_#{rand(99999)}.jpg")
    img.write(tmp)

    raw   = RTesseract.new(tmp, psm: 6).to_s
    File.delete(tmp) if File.exist?(tmp)

    lines = raw.split("\n").map(&:strip).reject(&:empty?)
    names = lines.filter_map { |l| clean_ocr_line(l) }
    names = collapse_name_lines(names)
    names = join_split_name(names)
    score = zone_score(names)

    if score > best_score
      best_score = score
      best_names = names
    end
  end

  # Line 0: mini name (e.g. "JOHNNY")
  # Line 1: subtitle/role (e.g. "SECURITY OFFICER") — may be part of name
  # Line 2: collection/faction (e.g. "MICROMACHINES CORP")
  # If we have 3+ lines, line 2 is likely the collection.
  # If we have 2 lines, line 1 is the collection.
  # If line 1 looks like a role/subtitle (short, all caps descriptor), use line 2 for collection.
  mini    = best_names[0]
  line1   = best_names[1]
  line2   = best_names[2]

  # Heuristic: if line1 is a short role descriptor and line2 exists, use line2 as collection
  collection = if line2 && line1 && line1.split.length <= 3
    line2
  else
    line1
  end

  {
    suggested_name:  mini,
    collection_name: collection
  }
rescue => e
  warn "OCR failed for #{image_path}: #{e.message}"
  { suggested_name: nil, collection_name: nil }
end


# ─── Helpers ──────────────────────────────────────────────────────────────────

require_relative 'helpers'

# ─── Scanner ──────────────────────────────────────────────────────────────────

def scan_folder(root)
  found          = 0
  first_new_col  = nil   # id of the first newly-created collection
  return { found: found, first_new_col_id: nil } unless Dir.exist?(root)

  # Find all MMF folders — used to skip their plain yyyy-mm counterparts
  mmf_base_paths = Dir.glob(File.join(root, '**', '*-mmf'))
                      .select { |p| File.directory?(p) }
                      .map    { |p| File.join(File.dirname(p), mmf_base_month(p)) }

  Dir.glob(File.join(root, '**', '*')).each do |path|
    next unless File.file?(path)
    next unless SUPPORTED_EXTS.include?(File.extname(path).downcase)

    folder   = File.dirname(path)
    filename = File.basename(path)
    next if Images.where(source_folder: folder, filename: filename).any?

    is_mmf = mmf_folder?(folder)

    # Skip folders ending in -cd (alternate image sets we don't want)
    next if File.basename(folder).end_with?('-cd')

    # Skip plain yyyy-mm folder if an MMF version exists for that month
    next if !is_mmf && mmf_base_paths.include?(folder)

    # ── Find or create collection for this folder ──
    col = Collections.where(folder_path: folder).first
    unless col
      release_month = is_mmf ? mmf_base_month(folder) : parse_release_month(folder)
      col_id = Collections.insert(
        folder_path:   folder,
        release_month: release_month,
        created_at:    Time.now,
        updated_at:    Time.now
      )
      col = Collections.where(id: col_id).first
      first_new_col ||= col_id
    end

    # ── Name extraction ──
    if is_mmf
      # MMF: extract name directly from filename — no OCR needed
      suggested   = extract_mmf_name(filename)
      auto_tagged = !suggested.nil?
      is_bundle   = suggested == 'Bundle'
    else
      # Standard: run OCR
      ocr         = ocr_unit9_image(path)
      suggested   = ocr[:suggested_name]
      auto_tagged = false

      if ocr[:collection_name] && col[:name].to_s.empty?
        Collections.where(id: col[:id]).update(
          name:       ocr[:collection_name],
          updated_at: Time.now
        )
      end
    end

    dim_match  = filename.match(/(\d+x\d+)/i)
    image_size = dim_match ? dim_match[1] : nil

    Images.insert(
      collection_id:  col[:id],
      source_folder:  folder,
      filename:       filename,
      image_size:     image_size,
      suggested_name: suggested,
      mini_name:      auto_tagged ? suggested : nil,
      mini_count:     is_bundle ? 4 : 1,
      tagged:         auto_tagged,
      created_at:     Time.now,
      updated_at:     Time.now
    )
    found += 1
  end
  { found: found, first_new_col_id: first_new_col }
end

# Remove collections whose folder no longer exists on disk,
# and remove plain yyyy-mm collections when an -mmf sibling exists in the DB or on disk.
# Returns { removed: N, cleanup_script_output: "..." }
def purge_missing_collections
  removed      = 0
  script_lines = []
  all_folders  = Collections.select_map(:folder_path)

  Collections.all.each do |col|
    folder = col[:folder_path]
    base   = File.basename(folder)
    parent = File.dirname(folder)

    # Remove if folder is gone from disk
    if !Dir.exist?(folder)
      Images.where(collection_id: col[:id]).delete
      Collections.where(id: col[:id]).delete
      removed += 1
      next
    end

    # Remove -cd folders
    if base.end_with?('-cd')
      Images.where(collection_id: col[:id]).delete
      Collections.where(id: col[:id]).delete
      removed += 1
      script_lines << "Removed -cd folder: #{base}"
      next
    end

    # Remove plain yyyy-mm if an -mmf sibling exists in the DB or on disk
    if base.match?(/^\d{4}-\d{2}$/)
      mmf_sibling_path = File.join(parent, base + '-mmf')
      if all_folders.include?(mmf_sibling_path) || Dir.exist?(mmf_sibling_path)
        Images.where(collection_id: col[:id]).delete
        Collections.where(id: col[:id]).delete
        removed += 1
        script_lines << "Removed plain #{base} (MMF sibling exists)"
      end
    end
  end

  { removed: removed, log: script_lines }
end

# ─── Routes ───────────────────────────────────────────────────────────────────

get '/' do
  redirect '/catalog'
end

get '/image_file/:id' do
  row = Images.where(id: params[:id].to_i).first
  halt 404, 'Image not found' unless row
  path = full_path(row)
  halt 404, "File not on disk: #{path}" unless File.exist?(path)
  ext = File.extname(row[:filename]).downcase.delete('.')
  content_type "image/#{ext == 'jpg' ? 'jpeg' : ext}"
  # Long-lived cache: images don't change in place; if they do, the
  # row id stays the same but mtime changes, so use mtime-based ETag.
  cache_control :public, max_age: 31536000, immutable: true
  last_modified File.mtime(path)
  send_file path
end

# ── 1. Catalog ────────────────────────────────────────────────────────────────

get '/catalog' do
  @show_all      = params[:show_all] == '1'
  @folder_filter = params[:folder].to_s.strip
  @status_filter = params[:status].to_s.strip  # legacy single filter
  @f_untagged        = params[:f_untagged]  == '1'
  @f_unprinted       = params[:f_unprinted] == '1'
  @f_unpainted       = params[:f_unpainted] == '1'
  @colorized_catalog = params[:colorized].to_s.strip
  @colorized_catalog = '' unless %w[true false unknown].include?(@colorized_catalog)
  @page          = [params[:page].to_i, 1].max
  @per_page      = 25
  @root          = settings.root_folder

  # All distinct folders for the dropdown
  @folders = Images.distinct.select_map(:source_folder).sort

  dataset = Images.order(:source_folder, :filename)

  # When print/paint flags active, show all tagged states
  any_flag = @f_untagged || @f_unprinted || @f_unpainted || !@colorized_catalog.empty?
  @show_all = true if @f_unprinted || @f_unpainted || !@colorized_catalog.empty?

  # Tagged/untagged base filter
  dataset = dataset.where(tagged: false) unless @show_all || any_flag

  # Apply folder filter
  dataset = dataset.where(source_folder: @folder_filter) unless @folder_filter.empty?

  # Apply flag filters (combinable)
  dataset = dataset.where(tagged: false) if @f_untagged
  case @colorized_catalog
  when 'true'    then dataset = dataset.where(colorized: true)
  when 'false'   then dataset = dataset.where(colorized: false)
  when 'unknown' then dataset = dataset.where(colorized: nil)
  end
  if @f_unprinted
    dataset = dataset.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
    dataset = dataset.where(primary_image_id: nil)
  end
  if @f_unpainted
    dataset = dataset.where(Sequel.expr { painted < 1 } | Sequel.expr(painted: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
    dataset = dataset.where(primary_image_id: nil)
  end

  # Legacy single status filter (from collections page links)
  case @status_filter
  when 'unprinted'
    @f_unprinted = true
    dataset = dataset.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
    dataset = dataset.where(primary_image_id: nil)
  when 'unpainted'
    @f_unpainted = true
    dataset = dataset.where(Sequel.expr { painted < 1 } | Sequel.expr(painted: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
    dataset = dataset.where(primary_image_id: nil)
  when 'untagged'
    @f_untagged = true
    dataset = dataset.where(tagged: false)
  end

  @total  = dataset.count

  # Calculate comparison total for "X filtered / Y total" display
  any_active_flag = @f_untagged || @f_unprinted || @f_unpainted

  if !@folder_filter.empty?
    # Folder selected — compare against folder total (without flag filters)
    folder_base = Images.where(source_folder: @folder_filter)
    folder_base = folder_base.where(tagged: false) unless @show_all || @f_untagged
    @total_unfiltered = folder_base.count
    @total_context    = 'in folder'
  elsif any_active_flag
    # Flag filters only — compare against full unfiltered DB
    grand_base = Images
    grand_base = grand_base.where(tagged: false) unless @show_all || @f_untagged
    @total_unfiltered = grand_base.count
    @total_context    = 'total'
  end

  # ── Group secondary images directly after their primary, cover image first ─
  # Fetch all matching rows (unpaginated), reorder so each secondary follows
  # its primary, then paginate the reordered list in Ruby.
  all_rows = dataset.all

  # Build a set of cover_image_ids across all collections in this result set
  col_ids_in_view = all_rows.map { |img| img[:collection_id] }.uniq
  cover_ids = Collections.where(id: col_ids_in_view)
                          .select_hash(:id, :cover_image_id)
                          .values.compact.to_set

  # Build lookup: primary_id => [secondary rows...]
  by_primary = Hash.new { |h, k| h[k] = [] }
  primaries_and_unlinked = []
  all_rows.each do |img|
    if img[:primary_image_id]
      by_primary[img[:primary_image_id]] << img
    else
      primaries_and_unlinked << img
    end
  end

  # Sort order: cover first, then bundles (alpha), then primaries (alpha),
  # each followed immediately by their secondaries (also alpha by name)
  covers,  non_covers = primaries_and_unlinked.partition { |img| cover_ids.include?(img[:id]) }
  bundles, rest       = non_covers.partition { |img|
    img[:mini_count].to_i >= 4 || img[:mini_name].to_s.downcase == 'bundle'
  }
  bundles_sorted = bundles.sort_by { |img| img[:mini_name].to_s.downcase }
  rest_sorted    = rest.sort_by    { |img| img[:mini_name].to_s.downcase }
  primaries_and_unlinked = covers + bundles_sorted + rest_sorted

  ordered = []
  primaries_and_unlinked.each do |img|
    ordered << img
    # Append this image's secondaries sorted alphabetically by name
    if by_primary.key?(img[:id])
      sorted_secs = by_primary[img[:id]].sort_by { |s| s[:mini_name].to_s.downcase }
      ordered.concat(sorted_secs)
    end
  end

  # Any "orphaned" secondaries whose primary isn't in this result set
  # (e.g. primary is on a different tagged/filter state) — append at the end
  linked_ids = primaries_and_unlinked.map { |img| img[:id] }
  by_primary.each do |primary_id, secs|
    next if linked_ids.include?(primary_id)
    ordered.concat(secs)
  end

  @images = ordered[(@page - 1) * @per_page, @per_page] || []
  @pages  = (@total.to_f / @per_page).ceil

  # Pre-load collections so views can look them up by id
  @collections = Collections.all.each_with_object({}) { |c, h| h[c[:id]] = c }

  # For each image's collection, build a list of "candidate primary" images
  # (other images in the same collection) for the secondary-link dropdown,
  # and resolve each image's primary's display name if it's a secondary.
  collection_ids = @images.map { |img| img[:collection_id] }.compact.uniq
  @collection_images = {}
  collection_ids.each do |cid|
    # Load cover id for this collection
    cid_cover = Collections.where(id: cid).get(:cover_image_id)
    rows = Images.where(collection_id: cid, primary_image_id: nil)
                 .select(:id, :mini_name, :filename, :stance, :weapons, :mini_count)
                 .all
    # Sort: cover first, bundles, then alpha by name
    cover_row,  non_cover  = rows.partition { |r| r[:id] == cid_cover }
    bundle_rows, rest_rows = non_cover.partition { |r| r[:mini_count].to_i >= 4 || r[:mini_name].to_s.downcase == 'bundle' }
    @collection_images[cid] = cover_row +
                               bundle_rows.sort_by { |r| r[:mini_name].to_s.downcase } +
                               rest_rows.sort_by   { |r| r[:mini_name].to_s.downcase }
  end

  primary_ids = @images.map { |img| img[:primary_image_id] }.compact.uniq
  @primary_lookup = primary_ids.empty? ? {} :
    Images.where(id: primary_ids).select_hash(:id, :mini_name)

  erb :catalog
end

post '/scan' do
  # Auto-backup on first scan of each browser session
  unless session[:scanned_this_session]
    make_backup('scan')
    session[:scanned_this_session] = true
    session[:changes_since_backup] = 0
  end
  purge_result = purge_missing_collections
  purged       = purge_result[:removed]
  scan_result  = scan_folder(settings.root_folder)
  count        = scan_result[:found]
  new_col_id   = scan_result[:first_new_col_id]
  params_str   = "scanned=#{count}&purged=#{purged}"
  params_str  += "&new_col=#{new_col_id}" if new_col_id
  redirect "/collections?#{params_str}"
end

# Manual backup endpoint
post '/backup' do
  dest = make_backup('manual')
  session[:changes_since_backup] = 0
  filename = File.basename(dest)
  redirect back + (back.include?('?') ? '&' : '?') + "backed_up=#{CGI.escape(filename)}"
end

# ── 2. Inline save ────────────────────────────────────────────────────────────

post '/images/:id' do
  id  = params[:id].to_i
  row = Images.where(id: id).first
  halt 404 unless row

  # ── DEBUG: log incoming xref-related params ──────────────────────────────
  puts "[xref-debug] image_id=#{id} collection_id=#{row[:collection_id]} " \
       "is_secondary=#{params[:is_secondary].inspect} " \
       "primary_image_id=#{params[:primary_image_id].inspect}"

  # Secondary image linkage: if "is_secondary" checked and a primary was
  # chosen, store the link; otherwise clear it.
  primary_id = nil
  if params[:is_secondary] == '1' && params[:primary_image_id].to_s.strip != ''
    candidate = params[:primary_image_id].to_i
    # Guard against self-reference and cross-collection links
    if candidate != id
      cand_row = Images.where(id: candidate).first
      if cand_row.nil?
        puts "[xref-debug]   -> REJECTED: candidate id=#{candidate} not found in images table"
      elsif cand_row[:collection_id] != row[:collection_id]
        puts "[xref-debug]   -> REJECTED: candidate collection_id=#{cand_row[:collection_id]} != row collection_id=#{row[:collection_id]}"
      else
        primary_id = candidate
        puts "[xref-debug]   -> ACCEPTED: primary_id=#{primary_id}"
      end
    else
      puts "[xref-debug]   -> REJECTED: candidate == self (id=#{id})"
    end
  else
    puts "[xref-debug]   -> not linking (checkbox unchecked or empty selection)"
  end

  update_fields = {
    mini_name:        params[:mini_name].to_s.strip.split.map(&:capitalize).join(' '),
    species:          params[:species].to_s.strip,
    gender:           params[:gender].to_s.strip,
    weapons:          params[:weapons].to_s.strip,
    stance:           params[:stance].to_s.strip,
    mini_size:        params[:mini_size].to_s.strip,
    notes:            params[:notes].to_s.strip,
    description:      params[:description].to_s.strip,
    mini_count:       [params[:mini_count].to_i, 1].max,
    tagged:           params[:mini_name].to_s.strip.length > 0,
    primary_image_id: primary_id,
    colorized:        params[:colorized] == 'true' ? true : (params[:colorized] == 'false' ? false : nil),
    updated_at:       Time.now
  }

  # Secondary images don't track printed/painted counts
  if primary_id.nil?
    update_fields[:printed] = [params[:printed].to_i, 0].max
    update_fields[:painted] = [params[:painted].to_i, 0].max
  else
    update_fields[:printed] = 0
    update_fields[:painted] = 0
  end

  Images.where(id: id).update(update_fields)
  session[:changes_since_backup] = (session[:changes_since_backup].to_i + 1)
  # Build redirect back preserving folder/page params, anchor to the saved row
  back_url = request.referer || '/catalog'
  back_url = back_url.sub(/#.*$/, '')  # strip any existing anchor
  redirect "#{back_url}#row-#{id}"
end

# ── Collections management ────────────────────────────────────────────────────

get '/collections' do
  @filter     = params[:filter].to_s.strip
  @year_filter = params[:year].to_s.strip   # e.g. '2024'

  @collections = Collections.order(:release_month, :name).all

  # Build list of available years from release_month values
  @years = @collections
    .map { |c| c[:release_month].to_s[0, 4] }
    .select { |y| y.match?(/^\d{4}$/) }
    .uniq.sort

  # Attach image counts
  @counts = Images.group_and_count(:collection_id).each_with_object({}) do |r, h|
    h[r[:collection_id]] = r[:count]
  end

  # Attach print/paint stats per collection
  @stats = {}
  @collections.each do |col|
    rows = Images.where(collection_id: col[:id]).select(:printed, :painted, :mini_count, :mini_name, :primary_image_id).all
    # Exclude bundles (named "Bundle" or mini_count >= 4) and secondary images
    # (alt views linked to a primary) from print/paint tracking
    trackable = rows.reject { |r| r[:mini_count].to_i >= 4 || r[:mini_name].to_s.downcase == 'bundle' || !r[:primary_image_id].nil? }
    @stats[col[:id]] = {
      total:     rows.length,
      printed:   trackable.sum { |r| r[:printed].to_i },
      painted:   trackable.sum { |r| r[:painted].to_i },
      unprinted: trackable.count { |r| r[:printed].to_i == 0 },
      unpainted: trackable.count { |r| r[:painted].to_i == 0 }
    }
  end

  # Apply year filter
  unless @year_filter.empty?
    @collections = @collections.select { |c| c[:release_month].to_s.start_with?(@year_filter) }
  end

  # Apply status filter
  if @filter == 'unprinted'
    @collections = @collections.select { |c| (@stats[c[:id]] || {})[:printed].to_i == 0 }
  elsif @filter == 'unpainted'
    @collections = @collections.select { |c| (@stats[c[:id]] || {})[:painted].to_i == 0 }
  elsif @filter == 'partially_printed'
    @collections = @collections.select { |c| s = @stats[c[:id]]; s && s[:printed] > 0 && s[:unprinted] > 0 }
  end

  # Preview image per collection — use cover if set, else first image
  @previews = {}
  @collections.each do |col|
    img = if col[:cover_image_id]
      Images.where(id: col[:cover_image_id]).first
    end
    img ||= Images.where(collection_id: col[:id]).order(:filename).first
    @previews[col[:id]] = img if img
  end
  # ── Build stubs for months since 2022-01 with no collection yet ─────────
  # Only show stubs when no year/status filter is active (they'd just clutter)
  @stubs = []
  if @filter.empty?
    existing_months = Collections.select_map(:release_month).compact.to_set
    stub_start = @year_filter.empty? ? Date.new(2022, 1, 1) : Date.new(@year_filter.to_i, 1, 1)
    stub_end   = @year_filter.empty? ? Date.today.prev_month : [Date.new(@year_filter.to_i, 12, 1), Date.today.prev_month].min
    d = stub_start
    while d <= stub_end
      ym = d.strftime('%Y-%m')
      unless existing_months.include?(ym)
        @stubs << ym
      end
      d = d >> 1
    end
  end

  erb :collections
end

post '/collections/:id' do
  id = params[:id].to_i
  halt 404 unless Collections.where(id: id).first
  Collections.where(id: id).update(
    name:       params[:name].to_s.strip.upcase,
    notes:      params[:notes].to_s.strip,
    updated_at: Time.now
  )
  redirect "/collections?saved=#{id}"
end

# ── Full edit page ─────────────────────────────────────────────────────────────

get '/edit/:id' do
  @image      = Images.where(id: params[:id].to_i).first
  halt 404, 'Not found' unless @image
  @collection = Collections.where(id: @image[:collection_id]).first

  # Other images in the same collection, for the cross-reference dropdown
  # Exclude secondaries; sort cover first, then bundles, then alpha
  _cover_id = Collections.where(id: @image[:collection_id]).get(:cover_image_id)
  _rows = Images.where(collection_id: @image[:collection_id], primary_image_id: nil)
                .exclude(id: @image[:id])
                .select(:id, :mini_name, :filename, :stance, :weapons, :mini_count)
                .all
  _cover_r,  _non   = _rows.partition { |r| r[:id] == _cover_id }
  _bundle_r, _rest  = _non.partition  { |r| r[:mini_count].to_i >= 4 || r[:mini_name].to_s.downcase == 'bundle' }
  @collection_images = _cover_r +
                       _bundle_r.sort_by { |r| r[:mini_name].to_s.downcase } +
                       _rest.sort_by     { |r| r[:mini_name].to_s.downcase }

  # Resolve primary image's display name, if this image is a secondary
  @primary_name = nil
  if @image[:primary_image_id]
    p_row = Images.where(id: @image[:primary_image_id]).first
    @primary_name = p_row ? (p_row[:mini_name].to_s.empty? ? p_row[:filename] : p_row[:mini_name]) : nil
  end

  erb :edit
end

post '/edit/:id' do
  id  = params[:id].to_i
  row = Images.where(id: id).first
  halt 404 unless row

  # Secondary image linkage: if "is_secondary" checked and a primary was
  # chosen, store the link; otherwise clear it.
  primary_id = nil
  if params[:is_secondary] == '1' && params[:primary_image_id].to_s.strip != ''
    candidate = params[:primary_image_id].to_i
    # Guard against self-reference and cross-collection links
    if candidate != id
      cand_row = Images.where(id: candidate).first
      if cand_row && cand_row[:collection_id] == row[:collection_id]
        # Refuse to create a chain: candidate must itself be a primary (not a secondary)
        if cand_row[:primary_image_id].nil?
          primary_id = candidate
        else
          puts "[xref-save] rejected chain: #{id} -> #{candidate} (which is itself a secondary)"
        end
      end
    end
  end

  update_fields = {
    mini_name:        params[:mini_name].to_s.strip.split.map(&:capitalize).join(' '),
    species:          params[:species].to_s.strip,
    gender:           params[:gender].to_s.strip,
    weapons:          params[:weapons].to_s.strip,
    stance:           params[:stance].to_s.strip,
    mini_size:        params[:mini_size].to_s.strip,
    notes:            params[:notes].to_s.strip,
    description:      params[:description].to_s.strip,
    mini_count:       [params[:mini_count].to_i, 1].max,
    tagged:           params[:mini_name].to_s.strip.length > 0,
    primary_image_id: primary_id,
    colorized:        params[:colorized] == 'true' ? true : (params[:colorized] == 'false' ? false : nil),
    updated_at:       Time.now
  }

  # Secondary images don't track printed/painted counts
  if primary_id.nil?
    update_fields[:printed] = [params[:printed].to_i, 0].max
    update_fields[:painted] = [params[:painted].to_i, 0].max
  else
    update_fields[:printed] = 0
    update_fields[:painted] = 0
  end

  Images.where(id: id).update(update_fields)
  session[:changes_since_backup] = (session[:changes_since_backup].to_i + 1)
  redirect "/catalog#row-#{id}"
end

# ── 2b. Random images ───────────────────────────────────────────────────────

get '/random' do
  @colorized_filter  = params[:colorized].to_s
  @no_bundles        = params[:no_bundles]  == '1'
  @unprinted_only    = params[:unprinted]   == '1'
  @random_count      = [params[:n].to_i, 10].max
  @random_count      = [@random_count, 240].min
  @random_count      = 60 if params[:n].to_s.empty?

  base = Images
  base = base.where(colorized: true)  if @colorized_filter == 'true'
  base = base.where(colorized: false) if @colorized_filter == 'false'
  base = base.where(colorized: nil)   if @colorized_filter == 'unknown'
  if @no_bundles
    base = base.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    base = base.exclude(Sequel.ilike(:mini_name, 'bundle'))
  end
  if @unprinted_only
    base = base.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil))
    base = base.where(primary_image_id: nil)
    base = base.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    base = base.exclude(Sequel.ilike(:mini_name, 'bundle'))
  end
  count = base.count
  @count = count
  per_page = 25
  if count == 0
    @images = []
  else
    # Pick a screen's worth of random ids efficiently
    n = @random_count
    ids = base.select_map(:id)
    sample_ids = ids.sample([n, ids.length].min)
    rows = Images.where(id: sample_ids).all
    col_map = Collections.select_hash(:id, :folder_path)
    @images = rows.map do |img|
      # Compute this image's position within its folder (ordered by filename,
      # matching the catalog page's ordering), so we can link directly to the
      # catalog page containing this row.
      position = Images.where(source_folder: img[:source_folder])
                        .where { filename < img[:filename] }
                        .count
      target_page = (position / per_page) + 1
      {
        id:           img[:id],
        filename:     img[:filename],
        mini_name:    img[:mini_name],
        folder_path:  col_map[img[:collection_id]],
        target_page:  target_page
      }
    end.shuffle
  end
  erb :random
end

# ── 3. Search ─────────────────────────────────────────────────────────────────

# ── Bulk tagger ──────────────────────────────────────────────────────────────

get '/bulk' do
  @field  = params[:field].to_s.strip   # stance, weapons, gender, species, mini_size
  @field  = 'stance' if @field.empty? || !%w[stance weapons gender species mini_size colorized].include?(@field)
  @folder = params[:folder].to_s.strip

  # Images missing the chosen field (NULL or empty string), excluding secondaries/bundles
  dataset = Images.where(primary_image_id: nil)
                  .exclude(Sequel.ilike(:mini_name, 'bundle'))
  dataset = dataset.where(source_folder: @folder) unless @folder.empty?

  @images = case @field
  when 'stance'    then dataset.where(Sequel::SQL::BooleanExpression.new(:OR, Sequel.expr(stance: nil),    { stance: '' }))
  when 'weapons'   then dataset.where(Sequel::SQL::BooleanExpression.new(:OR, Sequel.expr(weapons: nil),   { weapons: '' }))
  when 'species'   then dataset.where(Sequel::SQL::BooleanExpression.new(:OR, Sequel.expr(species: nil),   { species: '' }))
  when 'mini_size' then dataset.where(Sequel::SQL::BooleanExpression.new(:OR, Sequel.expr(mini_size: nil), { mini_size: '' }))
  when 'gender'    then dataset.where(gender: nil).or(gender: '')
  when 'colorized' then dataset.where(colorized: nil)
  end.order(:source_folder, :filename).limit(120).all

  # Collection names for folder filter dropdown
  @collections = Collections.order(:release_month).all

  erb :bulk
end

post '/bulk/set' do
  ids   = Array(params[:ids]).map(&:to_i).select { |i| i > 0 }
  field = params[:field].to_s.strip
  value = params[:value].to_s.strip

  allowed = %w[stance weapons gender species mini_size colorized]
  halt 400, "Invalid field" unless allowed.include?(field)
  halt 400, "No images selected" if ids.empty?

  update = {}
  if field == 'colorized'
    update[:colorized] = value == 'true' ? true : (value == 'false' ? false : nil)
  else
    update[field.to_sym] = value.empty? ? nil : value
  end
  update[:updated_at] = Time.now

  Images.where(id: ids).update(update)
  session[:changes_since_backup] = (session[:changes_since_backup].to_i + ids.length)

  content_type :json
  { ok: true, updated: ids.length }.to_json
end

get '/search' do
  @params     = params
  @results    = []
  @query_made = false
  @collections = Collections.all.each_with_object({}) { |c, h| h[c[:id]] = c }

  @colorized_filter = params[:colorized].to_s
  has_query = %i[q mini_name species gender weapons stance mini_size mini_count collection].any? do |k|
    params[k.to_s].to_s.strip.length > 0
  end
  has_query ||= !@colorized_filter.empty?

  if has_query
    @query_made = true

    # Start with a Sequel dataset (not .all — keeps it chainable)
    dataset = Images

    # Filter by collection name if provided
    col_filter = params['collection'].to_s.strip.downcase
    if col_filter.length > 0
      matching_col_ids = Collections.all.select { |c|
        c[:name].to_s.downcase.include?(col_filter)
      }.map { |c| c[:id] }
      dataset = dataset.where(collection_id: matching_col_ids)
    end

    # Filter by colorized status
    case @colorized_filter
    when 'true'    then dataset = dataset.where(colorized: true)
    when 'false'   then dataset = dataset.where(colorized: false)
    when 'unknown' then dataset = dataset.where(colorized: nil)
    end

    # Filter by mini count if set
    mc_filter = params['mini_count'].to_s.strip
    unless mc_filter.empty?
      if mc_filter == '4+'
        dataset = dataset.where { mini_count >= 4 }
      else
        dataset = dataset.where(mini_count: mc_filter.to_i)
      end
    end

    # If only colorized filter is set (no text/field query), skip scoring
    # and just return all matching rows with a flat score of 1
    text_query = %i[q mini_name species gender weapons stance mini_size mini_count collection].any? do |k|
      params[k.to_s].to_s.strip.length > 0
    end

    scored = dataset.all.map do |row|
      if text_query
        result = score_row(row, params.transform_keys(&:to_sym))
        result[:score] > 0 ? result.merge(row: row) : nil
      else
        { score: 1, highlights: {}, row: row }
      end
    end.compact.sort_by { |r| -r[:score] }
    @results = scored
  end

  erb :search
end

# ── Serve source PDF for a collection ────────────────────────────────────────

get '/pdf/:id' do
  col = Collections.where(id: params[:id].to_i).first
  halt 404, 'Collection not found' unless col

  pdf_path = col[:folder_path] + '.pdf'
  halt 404, "PDF not found: #{pdf_path}" unless File.exist?(pdf_path)

  content_type 'application/pdf'
  headers['Content-Disposition'] = "inline; filename=\"#{File.basename(pdf_path)}\""
  send_file pdf_path
end

get '/api/images' do
  content_type :json
  Images.all.to_json
end

# Distinct confirmed mini names for autocomplete
get '/api/names' do
  content_type :json
  names = Images
    .where(Sequel.~(mini_name: nil))
    .where(Sequel.~(mini_name: ""))
    .select_map(:mini_name)
    .flat_map { |n| n.split(",").map(&:strip) }
    .uniq
    .sort
  names.to_json
end

# Distinct OCR suggested names (unconfirmed) for autocomplete
get '/api/suggested_names' do
  content_type :json
  names = Images
    .where(Sequel.~(suggested_name: nil))
    .where(Sequel.~(suggested_name: ""))
    .where(tagged: false)
    .select_map(:suggested_name)
    .flat_map { |n| n.split(",").map(&:strip) }
    .uniq
    .sort
  names.to_json
end

get '/api/collections' do
  content_type :json
  Collections.all.to_json
end

# OCR detect name for a single image
get '/images/:id/detect_name' do
  content_type :json
  img = Images.where(id: params[:id].to_i).first
  halt 404, { error: 'Not found' }.to_json unless img

  path = File.join(img[:source_folder], img[:filename])
  halt 422, { error: 'File not on disk' }.to_json unless File.exist?(path)

  result = ocr_unit9_image(path)

  if result[:suggested_name].nil? && result[:collection_name].nil?
    halt 422, { error: 'No text found in image' }.to_json
  end

  result.to_json
end

# Set cover image for a collection
# Fetch sibling images with the same name in the same collection
get '/images/:id/siblings' do
  id  = params[:id].to_i
  row = Images.where(id: id).first
  halt 404 unless row

  name = row[:mini_name].to_s.strip
  halt 400, "No name set" if name.empty?

  siblings = Images.where(collection_id: row[:collection_id])
                   .where(Sequel.ilike(:mini_name, name))
                   .exclude(id: id)
                   .select(:id, :mini_name, :species, :gender, :stance, :weapons, :mini_size)
                   .all

  content_type :json
  siblings.map { |s|
    { id: s[:id], mini_name: s[:mini_name],
      species: s[:species].to_s, gender: s[:gender].to_s,
      stance: s[:stance].to_s, weapons: s[:weapons].to_s,
      mini_size: s[:mini_size].to_s }
  }.to_json
end

# Quick colorized toggle — called via fetch from JS
post '/images/:id/colorized' do
  id    = params[:id].to_i
  value = case params[:value]
          when 'true'  then true
          when 'false' then false
          else nil
          end
  Images.where(id: id).update(colorized: value, updated_at: Time.now)
  session[:changes_since_backup] = (session[:changes_since_backup].to_i + 1)
  content_type :json
  { ok: true, value: value }.to_json
end

post '/collections/:id/rename' do
  id   = params[:id].to_i
  name = params[:name].to_s.strip.upcase
  Collections.where(id: id).update(name: name, updated_at: Time.now)
  session[:changes_since_backup] = (session[:changes_since_backup].to_i + 1)
  redirect params[:redirect_to].to_s.empty? ? '/collections' : params[:redirect_to]
end

post '/collections/:id/set_cover' do
  col_id = params[:id].to_i
  img_id = params[:image_id].to_i
  halt 404 unless Collections.where(id: col_id).first
  halt 404 unless Images.where(id: img_id, collection_id: col_id).first
  Collections.where(id: col_id).update(cover_image_id: img_id, updated_at: Time.now)
  content_type :json
  { ok: true, image_id: img_id }.to_json
end

# OCR a single collection folder and return suggested names
post '/collections/:id/detect_name' do
  content_type :json
  id  = params[:id].to_i
  col = Collections.where(id: id).first
  halt 404, { error: 'Not found' }.to_json unless col

  # Try up to 5 images in the folder until OCR succeeds
  candidates = Images
    .where(source_folder: col[:folder_path])
    .order(:filename)
    .all
    .select { |img| File.exist?(File.join(img[:source_folder], img[:filename])) }

  if candidates.empty?
    halt 422, { error: 'No image files found on disk' }.to_json
  end

  result = nil
  candidates.first(5).each do |img|
    path = File.join(img[:source_folder], img[:filename])
    r    = ocr_unit9_image(path)
    next if r[:suggested_name].nil? && r[:collection_name].nil?
    result = r
    break
  end

  if result.nil?
    halt 422, { error: 'OCR found no text in this folder' }.to_json
  end

  {
    suggested_name:  result[:suggested_name],
    collection_name: result[:collection_name]
  }.to_json
end
