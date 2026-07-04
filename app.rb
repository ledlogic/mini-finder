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

require_relative 'lib/helpers'
require_relative 'lib/url_helpers'
require_relative 'lib/file_helpers'
require_relative 'lib/ocr_helpers'
require_relative 'lib/db_helpers'

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

CHANGES_BEFORE_REMINDER = 25
APP_VERSION = "1.89"

# ─── Database ─────────────────────────────────────────────────────────────────

DB = Sequel.sqlite(File.join(File.dirname(__FILE__), 'db', 'catalog.db'))

# Collections — one per folder

# Schema and migrations — defined in lib/db_helpers.rb
db_setup_schema

Collections = DB[:collections]
Images      = DB[:images]

# Fix any chained secondary links — defined in lib/db_helpers.rb
db_fix_chained_secondaries

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

MONTH_NAMES = %w[january february march april may june
                 july august september october november december].freeze

MONTH_ABBR  = %w[jan feb mar apr may jun
                 jul aug sep oct nov dec].freeze

BUNDLE_WORDS    = %w[together bundle pack set group].freeze
SKIP_NAME_WORDS = %w[adv img page].freeze

MIN_OCR_WIDTH = 400

# ─── Routes ───────────────────────────────────────────────────────────────────

get '/' do
  redirect '/catalog'
end

# Silence Chrome DevTools auto-probe (Chrome 136+)
get '/.well-known/appspecific/com.chrome.devtools.json' do
  content_type :json
  '{}'
end

get '/image_file/:id' do
  row = Images.where(id: params[:id].to_i).first
  halt 404, 'Image not found' unless row
  path = file_image_path(row)
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

# ── 1. Catalog ────────────────────────────────────────────────────────────────

get '/catalog' do
  any_flag = catalog_setup_params
  catalog_build_images(Images.order(:source_folder, :filename), any_flag)
  erb :catalog
end

# ── 1b. Single collection view ─────────────────────────────────────────────────

get '/collection/:id' do
  col = Collections.where(id: params[:id].to_i).first
  halt 404, 'Collection not found' unless col
  params[:folder]   = col[:folder_path]
  params[:show_all] = '1'
  any_flag = catalog_setup_params
  catalog_build_images(Images.order(:source_folder, :filename), any_flag)
  @page_title = col[:name].to_s.empty? ? File.basename(col[:folder_path]) : col[:name]
  erb :catalog
end

post '/scan' do
  # Auto-backup on first scan of each browser session
  unless session[:scanned_this_session]
    db_make_backup('scan')
    session[:scanned_this_session] = true
    session[:changes_since_backup] = 0
  end
  purge_result = db_purge_missing_collections
  purged       = purge_result[:removed]
  scan_result  = db_scan_folder(settings.root_folder)
  count        = scan_result[:found]
  new_col_id   = scan_result[:first_new_col_id]
  params_str   = "scanned=#{count}&purged=#{purged}"
  params_str  += "&new_col=#{new_col_id}" if new_col_id
  redirect "/collections?#{params_str}"
end

# Manual backup endpoint
post '/backup' do
  dest = db_make_backup('manual')
  session[:changes_since_backup] = 0
  filename = File.basename(dest)
  redirect back + (back.include?('?') ? '&' : '?') + "backed_up=#{CGI.escape(filename)}"
end

# ── 2. Inline save ────────────────────────────────────────────────────────────

post '/images/:id/delete' do
  id  = params[:id].to_i
  row = Images.where(id: id).first
  halt 404, 'Not found' unless row

  # Remove file from disk
  path = File.join(row[:source_folder], row[:filename])
  File.delete(path) if File.exist?(path)

  # Remove from DB (also clear any references to this as a primary)
  Images.where(primary_image_id: id).update(primary_image_id: nil, updated_at: Time.now)
  Images.where(id: id).delete

  session[:changes_since_backup] = (session[:changes_since_backup].to_i + 1)

  # Redirect back to the collection or catalog
  col = Collections.where(id: row[:collection_id]).first
  redirect col ? "/collection/#{col[:id]}" : '/catalog'
end

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
    weapons:          params[:weapons].to_s.strip.upcase,
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

  # AJAX save — return JSON
  if request.xhr? || request.env['HTTP_ACCEPT']&.include?('application/json')
    content_type :json
    { ok: true, id: id }.to_json
  else
    back_url = request.referer || '/catalog'
    back_url = back_url.sub(/#.*$/, '')
    redirect "#{back_url}#row-#{id}"
  end
end

# ── Collections management ────────────────────────────────────────────────────

get '/collections' do
  @filter     = params[:filter].to_s.strip
  @year_filter = params[:year].to_s.strip   # e.g. '2024'

  @sort_order  = params[:sort].to_s == 'asc' ? 'asc' : 'desc'
  @collections = if @sort_order == 'asc'
    Collections.order(:release_month, :name).all
  else
    Collections.order(Sequel.desc(:release_month), :name).all
  end

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
    @stubs.reverse! if @sort_order == 'desc'
  end

  # Count colorized images that haven't been xref-linked yet
  # Also count unknown (nil) colorized images as needing attention
  @unlinked_colorized_count = Images
    .where(colorized: true)
    .where(primary_image_id: nil)
    .exclude(Sequel.ilike(:mini_name, 'bundle'))
    .where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    .count

  # Separately count images with unknown colorized status (nil) for a fuller picture
  @unset_colorized_count = Images
    .where(colorized: nil, primary_image_id: nil)
    .exclude(Sequel.ilike(:mini_name, 'bundle'))
    .where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    .count

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
                .select(:id, :mini_name, :filename, :stance, :weapons, :mini_count, :colorized)
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

  core_species = %w[HUMAN ROBOT VEHICLE ALIEN CREATURE UNDEAD BEAST]
  db_species   = Images
    .where(Sequel.~(species: nil))
    .exclude(species: '')
    .select_map(:species)
    .flat_map { |s| s.split(',').map(&:strip).map(&:upcase) }
    .reject(&:empty?)
    .tally.sort_by { |_, v| -v }.map(&:first)
  @top_species = (core_species + (db_species - core_species)).first(8)

  core_stance = %w[STANDING CROUCHING RUNNING KNEELING CHARGING PRONE JUMPING COMBAT]
  db_stance   = Images
    .where(Sequel.~(stance: nil))
    .exclude(stance: '')
    .select_map(:stance)
    .flat_map { |s| s.split(',').map(&:strip).map(&:upcase) }
    .reject(&:empty?)
    .tally.sort_by { |_, v| -v }.map(&:first)
  @top_stance = (core_stance + (db_stance - core_stance)).first(8)

  core_weapons = %w[SWORD PISTOL RIFLE KNIFE STAFF SHIELD BOW AXE]
  db_weapons   = Images
    .where(Sequel.~(weapons: nil))
    .exclude(weapons: '')
    .select_map(:weapons)
    .flat_map { |w| w.split(',').map(&:strip).map(&:upcase) }
    .reject(&:empty?)
    .tally.sort_by { |_, v| -v }.map(&:first)
  @top_weapons = (core_weapons + (db_weapons - core_weapons)).first(8)

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
    weapons:          params[:weapons].to_s.strip.upcase,
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

get '/statistics' do
  # Total counts
  @total_images      = Images.count
  @total_collections = Collections.count
  @total_tagged      = Images.where(tagged: true).count
  @total_untagged    = @total_images - @total_tagged

  # Exclude bundles and secondaries from print/paint stats
  trackable = Images
    .where(primary_image_id: nil)
    .where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
    .exclude(Sequel.ilike(:mini_name, 'bundle'))

  @total_trackable   = trackable.count
  @total_printed     = trackable.where(Sequel.expr { printed > 0 }).count
  @total_unprinted   = trackable.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil)).count
  @total_painted     = trackable.where(Sequel.expr { painted > 0 }).count
  @total_unpainted   = trackable.where(Sequel.expr { painted < 1 } | Sequel.expr(painted: nil)).count
  @sum_printed       = trackable.sum(:printed).to_i
  @sum_painted       = trackable.sum(:painted).to_i

  # Colorized breakdown
  @colorized_color   = Images.where(colorized: true).count
  @colorized_grey    = Images.where(colorized: false).count
  @colorized_unknown = Images.where(colorized: nil).count

  # Unlinked colorized (need xref)
  @unlinked_colorized = Images
    .where(colorized: true, primary_image_id: nil)
    .exclude(Sequel.ilike(:mini_name, 'bundle'))
    .count

  # Species breakdown (non-empty, non-bundle, split on comma)
  species_raw = Images
    .exclude(Sequel.ilike(:mini_name, 'bundle'))
    .where(Sequel.~(species: nil))
    .exclude(species: '')
    .select_map(:species)
  @by_species = species_raw
    .flat_map { |s| s.split(',').map(&:strip) }
    .reject(&:empty?)
    .tally
    .sort_by { |_, v| -v }

  # Gender breakdown
  gender_raw = Images
    .exclude(Sequel.ilike(:mini_name, 'bundle'))
    .where(Sequel.~(gender: nil))
    .exclude(gender: '')
    .select_map(:gender)
  @by_gender = gender_raw
    .flat_map { |g| g.split(',').map(&:strip) }
    .reject(&:empty?)
    .tally
    .sort_by { |_, v| -v }

  # Weapons breakdown
  weapons_raw = Images
    .exclude(Sequel.ilike(:mini_name, 'bundle'))
    .where(Sequel.~(weapons: nil))
    .exclude(weapons: '')
    .select_map(:weapons)
  @by_weapons = weapons_raw
    .flat_map { |w| w.split(',').map(&:strip) }
    .reject(&:empty?)
    .tally
    .sort_by { |_, v| -v }

  # Stance breakdown
  stance_raw = Images
    .exclude(Sequel.ilike(:mini_name, 'bundle'))
    .where(Sequel.~(stance: nil))
    .exclude(stance: '')
    .select_map(:stance)
  @by_stance = stance_raw
    .flat_map { |s| s.split(',').map(&:strip) }
    .reject(&:empty?)
    .tally
    .sort_by { |_, v| -v }

  # Mini size breakdown
  size_raw = Images
    .where(Sequel.~(mini_size: nil))
    .exclude(mini_size: '')
    .select_map(:mini_size)
  @by_size = size_raw
    .flat_map { |s| s.split(',').map(&:strip) }
    .reject(&:empty?)
    .tally
    .sort_by { |k, _| k }

  erb :statistics
end

get '/random' do
  @colorized_filter  = params[:colorized].to_s
  @no_bundles        = params[:no_bundles]  == '1'
  @no_vehicles       = params[:no_vehicles] == '1'
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
  if @no_vehicles
    # Find vehicle image ids directly (by species or name keywords)
    vehicle_ids = Images
      .where(
        Sequel.ilike(:species, '%VEHICLE%') |
        Sequel.ilike(:mini_name, '%vehicle%') |
        Sequel.ilike(:mini_name, '%bike%') |
        Sequel.ilike(:mini_name, '%car%') |
        Sequel.ilike(:mini_name, '%truck%') |
        Sequel.ilike(:mini_name, '%mech%')
      )
      .select_map(:id)
    # Also include secondaries (xrefs) whose primary is a vehicle
    xref_vehicle_ids = Images
      .where(primary_image_id: vehicle_ids)
      .select_map(:id)
    all_vehicle_ids = (vehicle_ids + xref_vehicle_ids).uniq
    base = base.exclude(id: all_vehicle_ids) unless all_vehicle_ids.empty?
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
    col_map  = Collections.select_hash(:id, :folder_path)
    name_map = Collections.select_hash(:id, :name)
    @images = rows.map do |img|
      position = Images.where(source_folder: img[:source_folder])
                        .where { filename < img[:filename] }
                        .count
      target_page = (position / per_page) + 1
      {
        id:              img[:id],
        filename:        img[:filename],
        mini_name:       img[:mini_name],
        collection_id:   img[:collection_id],
        collection_name: name_map[img[:collection_id]],
        folder_path:     col_map[img[:collection_id]],
        target_page:     target_page
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
  value = value.upcase if field == 'weapons'

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

  q = params[:q].to_s.strip
  @page_title = q.empty? ? nil : "Search: #{q}"
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
