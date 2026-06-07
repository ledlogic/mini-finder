require 'dotenv/load'
require 'sinatra'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'pathname'
require 'cgi'
require 'rtesseract'
require 'mini_magick'

# ─── Configuration ────────────────────────────────────────────────────────────

configure do
  set :port, 4567
  set :bind, '127.0.0.1'
  set :views, File.join(File.dirname(__FILE__), 'views')
  set :public_folder, File.join(File.dirname(__FILE__), 'public')
  set :root_folder, ENV.fetch('ROOT_FOLDER', 'G:/My Drive/STL/UNIT9')
end

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
  Boolean  :tagged, default: false
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
].each do |sql|
  begin; DB.run(sql); rescue Sequel::DatabaseError; end
end

Collections = DB[:collections]
Images      = DB[:images]

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
  found = 0
  return found unless Dir.exist?(root)

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
  found
end

# Remove collections whose folder no longer exists on disk,
# and remove plain yyyy-mm collections when an -mmf sibling exists.
def purge_missing_collections
  removed = 0
  all_folders = Collections.select_map(:folder_path)

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

    # Remove plain yyyy-mm if an -mmf sibling exists in the DB
    if base.match?(/^\d{4}-\d{2}$/)
      mmf_sibling = File.join(parent, base + '-mmf')
      if all_folders.include?(mmf_sibling)
        Images.where(collection_id: col[:id]).delete
        Collections.where(id: col[:id]).delete
        removed += 1
      end
    end
  end
  removed
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
  send_file path
end

# ── 1. Catalog ────────────────────────────────────────────────────────────────

get '/catalog' do
  @show_all      = params[:show_all] == '1'
  @folder_filter = params[:folder].to_s.strip
  @status_filter = params[:status].to_s.strip  # legacy single filter
  @f_untagged    = params[:f_untagged]  == '1'
  @f_unprinted   = params[:f_unprinted] == '1'
  @f_unpainted   = params[:f_unpainted] == '1'
  @page          = [params[:page].to_i, 1].max
  @per_page      = 25
  @root          = settings.root_folder

  # All distinct folders for the dropdown
  @folders = Images.distinct.select_map(:source_folder).sort

  dataset = Images.order(:source_folder, :filename)

  # When print/paint flags active, show all tagged states
  any_flag = @f_untagged || @f_unprinted || @f_unpainted
  @show_all = true if @f_unprinted || @f_unpainted

  # Tagged/untagged base filter
  dataset = dataset.where(tagged: false) unless @show_all || any_flag

  # Apply folder filter
  dataset = dataset.where(source_folder: @folder_filter) unless @folder_filter.empty?

  # Apply flag filters (combinable)
  dataset = dataset.where(tagged: false) if @f_untagged
  if @f_unprinted
    dataset = dataset.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
  end
  if @f_unpainted
    dataset = dataset.where(Sequel.expr { painted < 1 } | Sequel.expr(painted: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
  end

  # Legacy single status filter (from collections page links)
  case @status_filter
  when 'unprinted'
    @f_unprinted = true
    dataset = dataset.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
  when 'unpainted'
    @f_unpainted = true
    dataset = dataset.where(Sequel.expr { painted < 1 } | Sequel.expr(painted: nil))
    dataset = dataset.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    dataset = dataset.exclude(Sequel.ilike(:mini_name, 'bundle'))
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

  @images = dataset.limit(@per_page, (@page - 1) * @per_page).all
  @pages  = (@total.to_f / @per_page).ceil

  # Pre-load collections so views can look them up by id
  @collections = Collections.all.each_with_object({}) { |c, h| h[c[:id]] = c }

  erb :catalog
end

post '/scan' do
  purged = purge_missing_collections
  count  = scan_folder(settings.root_folder)
  redirect "/catalog?scanned=#{count}&purged=#{purged}"
end

# ── 2. Inline save ────────────────────────────────────────────────────────────

post '/images/:id' do
  id  = params[:id].to_i
  row = Images.where(id: id).first
  halt 404 unless row

  Images.where(id: id).update(
    mini_name:   params[:mini_name].to_s.strip,
    species:     params[:species].to_s.strip,
    gender:      params[:gender].to_s.strip,
    weapons:     params[:weapons].to_s.strip,
    stance:      params[:stance].to_s.strip,
    mini_size:   params[:mini_size].to_s.strip,
    notes:       params[:notes].to_s.strip,
    description: params[:description].to_s.strip,
    mini_count:  [params[:mini_count].to_i, 1].max,
    printed:     [params[:printed].to_i, 0].max,
    painted:     [params[:painted].to_i, 0].max,
    tagged:      params[:mini_name].to_s.strip.length > 0,
    updated_at:  Time.now
  )
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
    rows = Images.where(collection_id: col[:id]).select(:printed, :painted, :mini_count, :mini_name).all
    # Exclude bundles (named "Bundle" or mini_count >= 4) from print/paint tracking
    trackable = rows.reject { |r| r[:mini_count].to_i >= 4 || r[:mini_name].to_s.downcase == 'bundle' }
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
  erb :edit
end

post '/edit/:id' do
  id = params[:id].to_i
  halt 404 unless Images.where(id: id).first

  Images.where(id: id).update(
    mini_name:   params[:mini_name].to_s.strip,
    species:     params[:species].to_s.strip,
    gender:      params[:gender].to_s.strip,
    weapons:     params[:weapons].to_s.strip,
    stance:      params[:stance].to_s.strip,
    mini_size:   params[:mini_size].to_s.strip,
    notes:       params[:notes].to_s.strip,
    description: params[:description].to_s.strip,
    mini_count:  [params[:mini_count].to_i, 1].max,
    printed:     [params[:printed].to_i, 0].max,
    painted:     [params[:painted].to_i, 0].max,
    tagged:      params[:mini_name].to_s.strip.length > 0,
    updated_at:  Time.now
  )
  redirect '/catalog'
end

# ── 3. Search ─────────────────────────────────────────────────────────────────

get '/search' do
  @params     = params
  @results    = []
  @query_made = false
  @collections = Collections.all.each_with_object({}) { |c, h| h[c[:id]] = c }

  has_query = %i[q mini_name species gender weapons stance mini_size mini_count collection].any? do |k|
    params[k.to_s].to_s.strip.length > 0
  end

  if has_query
    @query_made = true

    # Filter by collection name if provided
    dataset = Images.all
    col_filter = params['collection'].to_s.strip.downcase
    if col_filter.length > 0
      matching_col_ids = Collections.all.select { |c|
        c[:name].to_s.downcase.include?(col_filter)
      }.map { |c| c[:id] }
      dataset = Images.where(collection_id: matching_col_ids)
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

    scored = dataset.map do |row|
      result = score_row(row, params.transform_keys(&:to_sym))
      result[:score] > 0 ? result.merge(row: row) : nil
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