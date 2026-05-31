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
  cleaned = line.gsub(/^[^A-Za-z'"]+/, '').strip
  # Remove characters that are definitely noise but keep apostrophes/quotes for names like 'TITANESS'
  cleaned = cleaned.gsub(/[|\\@#$%^&*_=<>{}\[\]]/, '').strip
  # Collapse multiple spaces
  cleaned = cleaned.gsub(/\s+/, ' ').strip
  # Must be at least 3 chars and mostly letters
  letter_ratio = cleaned.gsub(/[^A-Za-z]/, '').length.to_f / [cleaned.length, 1].max
  return nil if cleaned.length < 3 || letter_ratio < 0.5
  normalise_accents(cleaned)
end

# Score a zone result — prefer more words, longer names, penalise short noise
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

helpers do
  def levenshtein(s, t)
    s = s.downcase; t = t.downcase
    return t.length if s.empty?
    return s.length if t.empty?
    d = Array.new(s.length + 1) { |i| Array.new(t.length + 1, 0) }
    (0..s.length).each { |i| d[i][0] = i }
    (0..t.length).each { |j| d[0][j] = j }
    (1..t.length).each do |j|
      (1..s.length).each do |i|
        cost = s[i-1] == t[j-1] ? 0 : 1
        d[i][j] = [d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+cost].min
      end
    end
    d[s.length][t.length]
  end

  def score_row(row, params)
    score = 0.0
    highlights = {}
    q = params[:q].to_s.strip.downcase

    FIELD_WEIGHTS.each do |field, weight|
      filter_val = params[field].to_s.strip.downcase
      next if filter_val.empty?
      row_vals     = row[field].to_s.downcase.split(',').map(&:strip)
      filter_terms = filter_val.split(',').map(&:strip).reject(&:empty?)
      matched = []
      filter_terms.each do |term|
        if row_vals.any? { |v| v.include?(term) }
          score += weight
          matched << term
        else
          best    = row_vals.map { |v| levenshtein(v, term) }.min || 99
          max_len = [term.length, 1].max
          if best <= (max_len * 0.4).ceil
            score += weight * (1.0 - best.to_f / max_len) * 0.5
            matched << "~#{term}"
          end
        end
      end
      highlights[field] = matched unless matched.empty?
    end

    unless q.empty?
      text_fields = %i[mini_name species weapons stance notes]
      text_fields.each do |field|
        cell = row[field].to_s.downcase
        q.split.each do |word|
          if cell.include?(word)
            score += 1.5
            highlights[field] ||= []
            highlights[field] << word
          else
            best = cell.split(/[\s,]+/).map { |v| levenshtein(v, word) }.min || 99
            if best <= (word.length * 0.4).ceil && word.length > 2
              score += 0.5
              highlights[field] ||= []
              highlights[field] << "~#{word}"
            end
          end
        end
      end

      # Description: higher weight Levenshtein word-level matching
      desc = row[:description].to_s.downcase
      unless desc.empty?
        desc_words = desc.split(/\s+/)
        q.split.each do |word|
          if desc.include?(word)
            score += 2.0
            highlights[:description] ||= []
            highlights[:description] << word
          else
            best    = desc_words.map { |v| levenshtein(v, word) }.min || 99
            max_len = [word.length, 1].max
            if best <= (max_len * 0.35).ceil && word.length > 2
              score += 1.0
              highlights[:description] ||= []
              highlights[:description] << "~#{word}"
            end
          end
        end
      end
    end

    { score: score.round(2), highlights: highlights }
  end

  def full_path(row)
    File.join(row[:source_folder], row[:filename])
  end

  # Returns the source PDF path for a collection folder if it exists
  def collection_pdf_path(folder_path)
    pdf = folder_path + ".pdf"
    File.exist?(pdf) ? pdf : nil
  end

  # Server URL to stream a collection PDF via the app
  def pdf_url(collection_id)
    "/pdf/#{collection_id}"
  end

  # Highlight matched terms in a comma-separated field value
  def hl_field(val, matched)
    return '<em class="empty-val">—</em>' if val.to_s.strip.empty?
    terms = matched || []
    val.split(',').map(&:strip).map { |part|
      hit   = terms.any? { |t| t.sub(/^~/, '').length > 0 && part.downcase.include?(t.sub(/^~/, '')) }
      fuzzy = !hit && terms.any? { |t| t.start_with?('~') && part.downcase.include?(t.sub(/^~/, '')) }
      if hit
        "<mark class='hl-exact'>#{part}</mark>"
      elsif fuzzy
        "<mark class='hl-fuzzy'>#{part}</mark>"
      else
        part
      end
    }.join(', ')
  end

  # Highlight matched terms in a comma-separated field value
  def hl_field(val, matched)
    return '<em class="empty-val">—</em>' if val.to_s.strip.empty?
    terms = matched || []
    val.split(',').map(&:strip).map { |part|
      hit   = terms.any? { |t| t.sub(/^~~/,"").sub(/^~/,"").length > 0 && part.downcase.include?(t.sub(/^~/,"")) }
      fuzzy = !hit && terms.any? { |t| t.start_with?("~") && part.downcase.include?(t.sub(/^~/,"")) }
      if hit
        "<mark class='hl-exact'>\#{part}</mark>"
      elsif fuzzy
        "<mark class='hl-fuzzy'>\#{part}</mark>"
      else
        part
      end
    }.join(", ")
  end

  # Find or build collection record for a given folder path
  def collection_for_folder(folder_path)
    Collections.where(folder_path: folder_path).first
  end

  # Parse a release month from a folder name containing YYYY-MM or YYYYMM
  def parse_release_month(folder_name)
    base = File.basename(folder_name)
    if (m = base.match(/(\d{4})-(\d{2})/))
      "#{m[1]}-#{m[2]}"
    elsif (m = base.match(/(\d{4})(\d{2})/))
      "#{m[1]}-#{m[2]}"
    end
  end
end

# ─── Scanner ──────────────────────────────────────────────────────────────────

def scan_folder(root)
  found = 0
  return found unless Dir.exist?(root)

  Dir.glob(File.join(root, '**', '*')).each do |path|
    next unless File.file?(path)
    next unless SUPPORTED_EXTS.include?(File.extname(path).downcase)

    folder   = File.dirname(path)
    filename = File.basename(path)
    next if Images.where(source_folder: folder, filename: filename).any?

    # ── Find or create collection for this folder ──
    col = Collections.where(folder_path: folder).first
    unless col
      release_month = parse_release_month(folder)
      col_id = Collections.insert(
        folder_path:   folder,
        release_month: release_month,
        created_at:    Time.now,
        updated_at:    Time.now
      )
      col = Collections.where(id: col_id).first
    end

    # ── OCR for suggested name + collection name ──
    ocr = ocr_unit9_image(path)

    # If OCR found a collection name and the collection doesn't have one yet,
    # save it back to the collection record
    if ocr[:collection_name] && col[:name].to_s.empty?
      Collections.where(id: col[:id]).update(
        name:       ocr[:collection_name],
        updated_at: Time.now
      )
    end

    dim_match  = filename.match(/(\d+x\d+)/i)
    image_size = dim_match ? dim_match[1] : nil

    Images.insert(
      collection_id:  col[:id],
      source_folder:  folder,
      filename:       filename,
      image_size:     image_size,
      suggested_name: ocr[:suggested_name],
      tagged:         false,
      created_at:     Time.now,
      updated_at:     Time.now
    )
    found += 1
  end
  found
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
  @page          = [params[:page].to_i, 1].max
  @per_page      = 25
  @root          = settings.root_folder

  # All distinct folders for the dropdown
  @folders = Images.distinct.select_map(:source_folder).sort

  dataset = @show_all ? Images.order(:source_folder, :filename)
                      : Images.where(tagged: false).order(:source_folder, :filename)

  # Apply folder filter if set
  dataset = dataset.where(source_folder: @folder_filter) unless @folder_filter.empty?

  @total  = dataset.count
  @images = dataset.limit(@per_page, (@page - 1) * @per_page).all
  @pages  = (@total.to_f / @per_page).ceil

  # Pre-load collections so views can look them up by id
  @collections = Collections.all.each_with_object({}) { |c, h| h[c[:id]] = c }

  erb :catalog
end

post '/scan' do
  count = scan_folder(settings.root_folder)
  redirect "/catalog?scanned=#{count}"
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
    tagged:      params[:mini_name].to_s.strip.length > 0,
    updated_at:  Time.now
  )
  redirect back
end

# ── Collections management ────────────────────────────────────────────────────

get '/collections' do
  @collections = Collections.order(:release_month, :name).all
  # Attach image counts
  @counts = Images.group_and_count(:collection_id).each_with_object({}) do |r, h|
    h[r[:collection_id]] = r[:count]
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
