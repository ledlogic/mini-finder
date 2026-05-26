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
  Boolean  :tagged, default: false
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

# Migrations — add columns to existing DBs that predate this version
[
  "ALTER TABLE images ADD COLUMN collection_id INTEGER REFERENCES collections(id)",
  "ALTER TABLE images ADD COLUMN suggested_name TEXT",
  "ALTER TABLE collections ADD COLUMN release_month TEXT",
  "ALTER TABLE collections ADD COLUMN notes TEXT",
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

# UNIT9 places the name block in different positions depending on artwork layout.
# We try multiple crop zones and pick the one that yields the most clean ALL-CAPS
# words — that zone is almost certainly the name block.
CROP_ZONES = [
  { label: 'upper-right',  x: 0.40, y: 0.68, w: 0.55, h: 0.12 },  # Ash Shepherd style
  { label: 'lower-right',  x: 0.45, y: 0.78, w: 0.50, h: 0.15 },  # Kunoichi style
  { label: 'bottom-right', x: 0.40, y: 0.82, w: 0.55, h: 0.12 },  # low placement
  { label: 'mid-right',    x: 0.50, y: 0.60, w: 0.45, h: 0.18 },  # tall artwork
].freeze

# Clean a raw OCR line down to uppercase words only.
# Returns the cleaned string or nil if it doesn't look like a name.
def clean_ocr_line(line)
  cleaned = line.gsub(/^[^A-Z]+/, '').gsub(/[^A-Za-z\s]/, '').strip
  cleaned if cleaned.length > 3 && cleaned == cleaned.upcase
end

# Score a list of candidate name lines — more words, longer text = better.
def zone_score(names)
  names.sum { |n| n.split.length * n.length }
end

# Extract mini name (line 1) and collection name (line 2) from a UNIT9 image.
# Returns { suggested_name: String|nil, collection_name: String|nil }
def ocr_unit9_image(image_path)
  return { suggested_name: nil, collection_name: nil } unless File.exist?(image_path)

  orig = MiniMagick::Image.open(image_path)
  w = orig.width
  h = orig.height

  best_names = []
  best_score = 0

  CROP_ZONES.each do |zone|
    # Re-open for each crop so we always start from the original
    img = MiniMagick::Image.open(image_path)

    crop_w = (w * zone[:w]).to_i
    crop_h = (h * zone[:h]).to_i
    crop_x = (w * zone[:x]).to_i
    crop_y = (h * zone[:y]).to_i

    img.crop "#{crop_w}x#{crop_h}+#{crop_x}+#{crop_y}"
    img.colorspace "Gray"

    tmp = File.join(Dir.tmpdir, "unit9_ocr_#{Time.now.to_i}_#{rand(99999)}.jpg")
    img.write(tmp)

    raw = RTesseract.new(tmp, psm: 6).to_s
    File.delete(tmp) if File.exist?(tmp)

    names = raw.split("\n").map(&:strip).reject(&:empty?).filter_map { |l| clean_ocr_line(l) }
    score = zone_score(names)

    if score > best_score
      best_score = score
      best_names = names
    end
  end

  {
    suggested_name:  best_names[0],  # e.g. "KUNOICHI SISTERS"
    collection_name: best_names[1]   # e.g. "BORYOKUDAN"
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
    end

    { score: score.round(2), highlights: highlights }
  end

  def full_path(row)
    File.join(row[:source_folder], row[:filename])
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
    mini_name:  params[:mini_name].to_s.strip,
    species:    params[:species].to_s.strip,
    gender:     params[:gender].to_s.strip,
    weapons:    params[:weapons].to_s.strip,
    stance:     params[:stance].to_s.strip,
    mini_size:  params[:mini_size].to_s.strip,
    notes:      params[:notes].to_s.strip,
    tagged:     params[:mini_name].to_s.strip.length > 0,
    updated_at: Time.now
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
  erb :collections
end

post '/collections/:id' do
  id = params[:id].to_i
  halt 404 unless Collections.where(id: id).first
  Collections.where(id: id).update(
    name:       params[:name].to_s.strip,
    notes:      params[:notes].to_s.strip,
    updated_at: Time.now
  )
  redirect '/collections'
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
    mini_name:  params[:mini_name].to_s.strip,
    species:    params[:species].to_s.strip,
    gender:     params[:gender].to_s.strip,
    weapons:    params[:weapons].to_s.strip,
    stance:     params[:stance].to_s.strip,
    mini_size:  params[:mini_size].to_s.strip,
    notes:      params[:notes].to_s.strip,
    tagged:     params[:mini_name].to_s.strip.length > 0,
    updated_at: Time.now
  )
  redirect '/catalog'
end

# ── 3. Search ─────────────────────────────────────────────────────────────────

get '/search' do
  @params     = params
  @results    = []
  @query_made = false
  @collections = Collections.all.each_with_object({}) { |c, h| h[c[:id]] = c }

  has_query = %i[q mini_name species gender weapons stance mini_size collection].any? do |k|
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

    scored = dataset.map do |row|
      result = score_row(row, params.transform_keys(&:to_sym))
      result[:score] > 0 ? result.merge(row: row) : nil
    end.compact.sort_by { |r| -r[:score] }
    @results = scored
  end

  erb :search
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
