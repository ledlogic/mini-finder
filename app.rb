require 'sinatra'
require 'sinatra/json'
require 'sequel'
require 'json'
require 'pathname'

# ─── Configuration ────────────────────────────────────────────────────────────

configure do
  set :port, 4567
  set :bind, '127.0.0.1'
  set :views, File.join(File.dirname(__FILE__), 'views')
  set :public_folder, File.join(File.dirname(__FILE__), 'public')

  # Root folder containing all UNIT9 image subdirectories.
  # Override via ENV: ROOT_FOLDER="G:/My Drive/STL/UNIT9" ruby app.rb
  set :root_folder, ENV.fetch('ROOT_FOLDER', 'G:/My Drive/STL/UNIT9')
end

# ─── Database ─────────────────────────────────────────────────────────────────

DB = Sequel.sqlite(File.join(File.dirname(__FILE__), 'db', 'catalog.db'))

DB.create_table?(:images) do
  primary_key :id
  String  :source_folder,  null: false
  String  :filename,       null: false
  String  :image_size                    # e.g. "1080x1080"
  String  :mini_name                     # comma-separated display names
  String  :species                       # comma-separated
  String  :gender                        # comma-separated M/F/NA
  String  :weapons                       # comma-separated
  String  :stance                        # comma-separated
  String  :mini_size                     # comma-separated S/M/L
  String  :notes
  Boolean :tagged, default: false
  DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
  DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
end

Images = DB[:images]

# ─── Constants ────────────────────────────────────────────────────────────────

FIELD_WEIGHTS = {
  mini_name: 4.0,
  species:   3.0,
  weapons:   2.0,
  stance:    1.5,
  gender:    1.0,
  mini_size: 1.0
}.freeze

# ─── Helpers ──────────────────────────────────────────────────────────────────

helpers do
  def image_url(row)
    "/image_file/#{row[:id]}"
  end

  # Levenshtein distance between two strings (case-insensitive)
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

  # Score a single DB row against query parameters.
  # Returns { score: Float, highlights: Hash<field, [matched_terms]> }
  def score_row(row, params)
    score = 0.0
    highlights = {}
    q = params[:q].to_s.strip.downcase

    FIELD_WEIGHTS.each do |field, weight|
      filter_val = params[field].to_s.strip.downcase
      next if filter_val.empty?
      row_vals = row[field].to_s.downcase.split(',').map(&:strip)
      filter_terms = filter_val.split(',').map(&:strip).reject(&:empty?)
      matched = []
      filter_terms.each do |term|
        if row_vals.any? { |v| v.include?(term) }
          score += weight
          matched << term
        else
          # Levenshtein fuzzy — reward near-matches
          best = row_vals.map { |v| levenshtein(v, term) }.min || 99
          max_len = [term.length, 1].max
          if best <= (max_len * 0.4).ceil
            score += weight * (1.0 - best.to_f / max_len) * 0.5
            matched << "~#{term}"
          end
        end
      end
      highlights[field] = matched unless matched.empty?
    end

    # Free-text query across all text fields
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

  def tagged_class(row)
    row[:tagged] ? 'tagged' : 'untagged'
  end
end

# ─── Image Scanner ────────────────────────────────────────────────────────────

def scan_folder(root)
  supported = %w[.png .jpg .jpeg .gif .webp .bmp]
  found = 0
  return found unless Dir.exist?(root)

  Dir.glob(File.join(root, '**', '*')).each do |path|
    next unless File.file?(path)
    next unless supported.include?(File.extname(path).downcase)

    folder   = File.dirname(path)
    filename = File.basename(path)

    # Skip if already registered — use exists? instead of count > 0
    next if Images.where(source_folder: folder, filename: filename).any?

    # Try to read dimensions from filename (e.g. 1080x1080)
    dim_match  = filename.match(/(\d+x\d+)/i)
    image_size = dim_match ? dim_match[1] : nil

    Images.insert(
      source_folder: folder,
      filename:      filename,
      image_size:    image_size,
      tagged:        false,
      created_at:    Time.now,
      updated_at:    Time.now
    )
    found += 1
  end
  found
end

# ─── Routes ───────────────────────────────────────────────────────────────────

get '/' do
  redirect '/catalog'
end

# Serve actual image file by id
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
  @show_all = params[:show_all] == '1'
  @page     = [params[:page].to_i, 1].max
  @per_page = 25
  @root     = settings.root_folder

  dataset = @show_all ? Images.order(:source_folder, :filename)
                      : Images.where(tagged: false).order(:source_folder, :filename)

  @total  = dataset.count
  @images = dataset.limit(@per_page, (@page - 1) * @per_page).all
  @pages  = (@total.to_f / @per_page).ceil

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

# ── Full edit page ─────────────────────────────────────────────────────────────

get '/edit/:id' do
  @image = Images.where(id: params[:id].to_i).first
  halt 404, 'Not found' unless @image
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

  has_query = %i[q mini_name species gender weapons stance mini_size].any? do |k|
    params[k.to_s].to_s.strip.length > 0
  end

  if has_query
    @query_made = true
    scored = Images.all.map do |row|
      result = score_row(row, params.transform_keys(&:to_sym))
      result[:score] > 0 ? result.merge(row: row) : nil
    end.compact.sort_by { |r| -r[:score] }
    @results = scored
  end

  erb :search
end

# JSON API
get '/api/images' do
  content_type :json
  Images.all.to_json
end