# db_helpers.rb
# Database helpers — queries, scans, and backup that read/write the catalog DB.
# Loaded by app.rb via: require_relative 'db_helpers'

helpers do

  # ─── Lookup ──────────────────────────────────────────────────────────────────

  # Find a collection record by folder path
  def db_collection_for_folder(folder_path)
    Collections.where(folder_path: folder_path).first
  end

  # ─── Backup ──────────────────────────────────────────────────────────────────

  # Create a timestamped backup of catalog.db, pruning old backups
  def db_make_backup(label = 'manual')
    FileUtils.mkdir_p(BACKUP_DIR)
    ts   = Time.now.strftime('%Y%m%d-%H%M%S')
    dest = File.join(BACKUP_DIR, "catalog-#{ts}-#{label}.db")
    FileUtils.cp(DB_PATH, dest)
    backups = Dir.glob(File.join(BACKUP_DIR, 'catalog-*.db')).sort
    if backups.length > BACKUP_KEEP
      backups[0..-(BACKUP_KEEP + 1)].each { |f| File.delete(f) }
    end
    dest
  end

  # ─── Scanner ─────────────────────────────────────────────────────────────────

  # Scan the root folder for new images and register them in the DB.
  # Returns { found: N, first_new_col_id: id|nil }
  def db_scan_folder(root)
    found         = 0
    first_new_col = nil
    return { found: found, first_new_col_id: nil } unless Dir.exist?(root)

    # Find all MMF folders — used to skip their plain yyyy-mm counterparts
    mmf_base_paths = Dir.glob(File.join(root, '**', '*-mmf'))
                        .select { |p| File.directory?(p) }
                        .map    { |p| File.join(File.dirname(p), file_mmf_base_month(p)) }

    Dir.glob(File.join(root, '**', '*')).each do |path|
      next unless File.file?(path)
      next unless SUPPORTED_EXTS.include?(File.extname(path).downcase)

      folder   = File.dirname(path)
      filename = File.basename(path)
      next if Images.where(source_folder: folder, filename: filename).any?

      is_mmf = file_mmf_folder?(folder)

      next if File.basename(folder).end_with?('-cd')
      next if !is_mmf && mmf_base_paths.include?(folder)

      # Find or create collection for this folder
      col = Collections.where(folder_path: folder).first
      unless col
        release_month = is_mmf ? file_mmf_base_month(folder) : file_parse_release_month(folder)
        col_id = Collections.insert(
          folder_path:   folder,
          release_month: release_month,
          created_at:    Time.now,
          updated_at:    Time.now
        )
        col = Collections.where(id: col_id).first
        first_new_col ||= col_id
      end

      # Name extraction
      if is_mmf
        suggested   = file_extract_mmf_name(filename)
        auto_tagged = !suggested.nil?
        is_bundle   = suggested == 'Bundle'
      else
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
  # and remove plain yyyy-mm collections when an -mmf sibling exists.
  # Returns { removed: N, log: [...] }
  def db_purge_missing_collections
    removed      = 0
    script_lines = []
    all_folders  = Collections.select_map(:folder_path)

    Collections.all.each do |col|
      folder = col[:folder_path]
      base   = File.basename(folder)
      parent = File.dirname(folder)

      if !Dir.exist?(folder)
        Images.where(collection_id: col[:id]).delete
        Collections.where(id: col[:id]).delete
        removed += 1
        next
      end

      if base.end_with?('-cd')
        Images.where(collection_id: col[:id]).delete
        Collections.where(id: col[:id]).delete
        removed += 1
        script_lines << "Removed -cd folder: #{base}"
        next
      end

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


end # helpers do

# ─── Startup methods (called directly from app.rb, not Sinatra helpers) ───────

def db_setup_schema
  DB.create_table?(:collections) do
    primary_key :id
    String   :folder_path,    null: false, unique: true
    String   :name
    String   :release_month
    String   :notes
    Integer  :cover_image_id
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
  end

  DB.create_table?(:images) do
    primary_key :id
    foreign_key :collection_id, :collections
    String   :source_folder,  null: false
    String   :filename,       null: false
    String   :image_size
    String   :suggested_name
    String   :mini_name
    String   :species
    String   :gender
    String   :weapons
    String   :stance
    String   :mini_size
    String   :notes
    String   :description
    Integer  :mini_count,       default: 1
    Integer  :printed,          default: 0
    Integer  :painted,          default: 0
    Boolean  :tagged,           default: false
    Boolean  :colorized,        default: nil
    Integer  :primary_image_id
    DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP
  end

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
end

# ─── Fix chained secondary links on startup ───────────────────────────────────

def db_migrate_mini_sizes
  # Migrate legacy S/M/L mini_size values to mm equivalents
  # M=30mm, S=20mm, L=40mm (best approximations)
  mapping = {
    'S'     => '20mm',
    'M'     => '30mm',
    'L'     => '40mm',
    'S,M'   => '20mm,25mm',
    'M,L'   => '25mm,40mm',
    'S,M,L' => '20mm,25mm,40mm',
  }
  updated = 0
  mapping.each do |old_val, new_val|
    n = DB[:images].where(mini_size: old_val).update(mini_size: new_val, updated_at: Time.now)
    updated += n if n.is_a?(Integer)
  end
  puts "Mini size migration: #{updated} image(s) updated (S→20mm, M→25mm, L→40mm)" if updated > 0

  # Follow-up: shift 30mm -> 25mm (M was initially mapped to 30mm, now corrected to 25mm)
  n2 = DB[:images].where(mini_size: '30mm').update(mini_size: '25mm', updated_at: Time.now)
  puts "Mini size migration: #{n2} image(s) updated (30mm→25mm)" if n2.to_i > 0
end

def db_normalise_case
  # Force weapons and species to uppercase in all existing rows
  weapons_updated = 0
  DB[:images].where(Sequel.~(weapons: nil)).exclude(weapons: '').each do |row|
    upcased = row[:weapons].split(',').map { |w| w.strip.upcase }.join(', ')
    if upcased != row[:weapons]
      DB[:images].where(id: row[:id]).update(weapons: upcased, updated_at: Time.now)
      weapons_updated += 1
    end
  end
  puts "Case normalisation: #{weapons_updated} weapons row(s) upcased" if weapons_updated > 0

  species_updated = 0
  DB[:images].where(Sequel.~(species: nil)).exclude(species: '').each do |row|
    upcased = row[:species].split(',').map { |s| s.strip.upcase }.join(', ')
    if upcased != row[:species]
      DB[:images].where(id: row[:id]).update(species: upcased, updated_at: Time.now)
      species_updated += 1
    end
  end
  puts "Case normalisation: #{species_updated} species row(s) upcased" if species_updated > 0
end

def db_fix_chained_secondaries
  fixed = 0
  Images.where(Sequel.~(primary_image_id: nil)).each do |img|
    target = Images.where(id: img[:primary_image_id]).first
    next unless target
    next if target[:primary_image_id].nil?

    seen   = [img[:id]]
    cursor = target
    while cursor && !cursor[:primary_image_id].nil?
      break if seen.include?(cursor[:id])
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

