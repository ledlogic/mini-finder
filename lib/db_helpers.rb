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

end
