# helpers.rb
# Core Sinatra helper methods — search scoring and view rendering.
# Loaded by app.rb via: require_relative 'helpers'
#
# For other helpers see:
#   url_helpers.rb   — URL builders for routes and external sites (url_* prefix)
#   file_helpers.rb  — filesystem/path helpers (file_* prefix)
#   db_helpers.rb    — database queries, scanner, backup (db_* prefix)
#   ocr_helpers.rb   — OCR/image processing (ocr_* prefix)

helpers do

  # ─── Time helpers ────────────────────────────────────────────────────────────

  def relative_time(time)
    return '—' unless time
    diff = Time.now - time
    case diff.abs.to_i
    when 0..59        then "#{diff.to_i}s ago"
    when 60..3599     then "#{(diff / 60).to_i}m ago"
    when 3600..86399  then "#{(diff / 3600).to_i}h ago"
    when 86400..604799 then "#{(diff / 86400).to_i}d ago"
    when 604800..2591999 then "#{(diff / 604800).to_i}w ago"
    when 2592000..31535999 then "#{(diff / 2592000).to_i}mo ago"
    else "#{(diff / 31536000).to_i}y ago"
    end
  end

  # ─── Search / scoring ────────────────────────────────────────────────────────

  def str_levenshtein(s, t)
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
          best    = row_vals.map { |v| str_levenshtein(v, term) }.min || 99
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
      text_fields = %i[mini_name species weapons stance]
      text_fields.each do |field|
        cell = row[field].to_s.downcase
        q.split.each do |word|
          if cell.include?(word)
            score += 1.5
            highlights[field] ||= []
            highlights[field] << word
          else
            best = cell.split(/[\s,]+/).map { |v| str_levenshtein(v, word) }.min || 99
            if best <= (word.length * 0.4).ceil && word.length > 2
              score += 0.5
              highlights[field] ||= []
              highlights[field] << "~#{word}"
            end
          end
        end
      end

      # Also score against collection name
      col_name = row[:_collection_name].to_s.downcase
      unless col_name.empty?
        q.split.each do |word|
          if col_name.include?(word)
            score += 2.0
            highlights[:collection_name] ||= []
            highlights[:collection_name] << word
          end
        end
      end

      desc = row[:description].to_s.downcase
      unless desc.empty?
        desc_words = desc.split(/\s+/)
        q.split.each do |word|
          if desc.include?(word)
            score += 2.0
            highlights[:description] ||= []
            highlights[:description] << word
          else
            best    = desc_words.map { |v| str_levenshtein(v, word) }.min || 99
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

  # ─── View helpers ────────────────────────────────────────────────────────────

  # Highlight matched search terms in a comma-separated field value
  def hl_field(val, matched)
    return '<em class="empty-val">—</em>' if val.to_s.strip.empty?
    terms = matched || []
    val.split(',').map(&:strip).map { |part|
      hit   = terms.any? { |t| t.sub(/^~/, "").length > 0 && part.downcase.include?(t.sub(/^~/, "")) }
      fuzzy = !hit && terms.any? { |t| t.start_with?("~") && part.downcase.include?(t.sub(/^~/, "")) }
      if hit
        "<mark class='hl-exact'>#{part}</mark>"
      elsif fuzzy
        "<mark class='hl-fuzzy'>#{part}</mark>"
      else
        part
      end
    }.join(", ")
  end


  # ─── Catalog setup (shared by /catalog and /collection/:id) ────────────
  def catalog_setup_params
    @show_all          = params[:show_all] == '1'
    @folder_filter     = params[:folder].to_s.strip
    @status_filter     = params[:status].to_s.strip
    @f_untagged        = params[:f_untagged]  == '1'
    @f_unprinted       = params[:f_unprinted] == '1'
    @f_unpainted       = params[:f_unpainted] == '1'
    @f_no_weapons      = params[:f_no_weapons]  == '1'
    @f_no_stance       = params[:f_no_stance]   == '1'
    @f_no_species      = params[:f_no_species]  == '1'
    @f_no_vehicles     = params[:f_no_vehicles] == '1'
    @f_no_robots       = params[:f_no_robots]   == '1'
    @f_no_bundles      = params[:f_no_bundles]  == '1'
    @colorized_catalog = params[:colorized].to_s.strip
    @colorized_catalog = '' unless %w[true false unknown].include?(@colorized_catalog)
    @page     = [params[:page].to_i, 1].max
    @per_page = 50
    @root     = settings.root_folder
    @folders  = Images.distinct.select_map(:source_folder).sort

    any_flag = @f_untagged || @f_unprinted || @f_unpainted || @f_no_weapons || @f_no_stance || @f_no_species || @f_no_vehicles || @f_no_robots || @f_no_bundles || !@colorized_catalog.empty?
    @show_all = true if @f_unprinted || @f_unpainted || @f_no_weapons || @f_no_stance || @f_no_species || @f_no_vehicles || @f_no_robots || @f_no_bundles || !@colorized_catalog.empty?
    any_flag
  end



  def catalog_build_images(dataset, any_flag)
    dataset = dataset.where(tagged: false) unless @show_all || any_flag
    dataset = dataset.where(source_folder: @folder_filter) unless @folder_filter.empty?
    dataset = dataset.where(tagged: false) if @f_untagged

    case @colorized_catalog
    when 'true'    then dataset = dataset.where(colorized: true)
    when 'false'   then dataset = dataset.where(colorized: false)
    when 'unknown' then dataset = dataset.where(colorized: nil)
    end

    bundle_exclude = ->(ds) {
      ds.where(Sequel.expr { mini_count < 4 } | Sequel.expr(mini_count: nil))
        .exclude(Sequel.ilike(:mini_name, 'bundle'))
        .where(primary_image_id: nil)
    }

    if @f_unprinted
      dataset = bundle_exclude.call(dataset)
      dataset = dataset.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil))
    end
    if @f_unpainted
      dataset = bundle_exclude.call(dataset)
      dataset = dataset.where(Sequel.expr { painted < 1 } | Sequel.expr(painted: nil))
    end
    if @f_no_weapons
      dataset = dataset.where(Sequel.~(tagged: false))
      dataset = dataset.where(Sequel.expr(weapons: nil) | Sequel.expr(weapons: ''))
    end
    if @f_no_stance
      dataset = dataset.where(Sequel.~(tagged: false))
      dataset = dataset.where(Sequel.expr(stance: nil) | Sequel.expr(stance: ''))
    end
    if @f_no_species
      dataset = dataset.where(Sequel.~(tagged: false))
      dataset = dataset.where(Sequel.expr(species: nil) | Sequel.expr(species: ''))
    end
    if @f_no_vehicles
      vehicle_ids = Images.where(
        Sequel.ilike(:species, '%VEHICLE%') | Sequel.ilike(:mini_name, '%vehicle%')
      ).select_map(:id)
      xref_vehicle_ids = Images.where(primary_image_id: vehicle_ids).select_map(:id)
      all_vehicle_ids = (vehicle_ids + xref_vehicle_ids).uniq
      dataset = dataset.exclude(id: all_vehicle_ids) unless all_vehicle_ids.empty?
    end
    if @f_no_robots
      robot_ids = Images.where(
        Sequel.ilike(:species, '%ROBOT%') | Sequel.ilike(:mini_name, '%robot%')
      ).select_map(:id)
      xref_robot_ids = Images.where(primary_image_id: robot_ids).select_map(:id)
      all_robot_ids = (robot_ids + xref_robot_ids).uniq
      dataset = dataset.exclude(id: all_robot_ids) unless all_robot_ids.empty?
    end
    if @f_no_bundles
      bundle_ids = Images.where(
        Sequel.expr { mini_count >= 4 } | Sequel.ilike(:mini_name, 'bundle')
      ).select_map(:id)
      xref_bundle_ids = Images.where(primary_image_id: bundle_ids).select_map(:id)
      all_bundle_ids = (bundle_ids + xref_bundle_ids).uniq
      dataset = dataset.exclude(id: all_bundle_ids) unless all_bundle_ids.empty?
    end

    case @status_filter
    when 'unprinted'
      @f_unprinted = true
      dataset = bundle_exclude.call(dataset)
      dataset = dataset.where(Sequel.expr { printed < 1 } | Sequel.expr(printed: nil))
    when 'unpainted'
      @f_unpainted = true
      dataset = bundle_exclude.call(dataset)
      dataset = dataset.where(Sequel.expr { painted < 1 } | Sequel.expr(painted: nil))
    when 'untagged'
      @f_untagged = true
      dataset = dataset.where(tagged: false)
    end

    @total = dataset.count

    if !@folder_filter.empty?
      folder_base = Images.where(source_folder: @folder_filter)
      folder_base = folder_base.where(tagged: false) unless @show_all || @f_untagged
      @total_unfiltered = folder_base.count
      @total_context    = 'in folder'
    elsif @f_untagged || @f_unprinted || @f_unpainted
      grand_base = Images
      grand_base = grand_base.where(tagged: false) unless @show_all || @f_untagged
      @total_unfiltered = grand_base.count
      @total_context    = 'total'
    end

    all_rows = dataset.all
    col_ids  = all_rows.map { |img| img[:collection_id] }.uniq
    cover_ids = Collections.where(id: col_ids)
                            .select_hash(:id, :cover_image_id)
                            .values.compact.to_set

    ordered = catalog_sort_images(all_rows, cover_ids)

    if @total <= @per_page
      @images = ordered
      @pages  = 1
      @page   = 1
    else
      @images = ordered[(@page - 1) * @per_page, @per_page] || []
      @pages  = (@total.to_f / @per_page).ceil
    end

    @collections = Collections.all.each_with_object({}) { |c, h| h[c[:id]] = c }

    collection_ids = @images.map { |img| img[:collection_id] }.compact.uniq
    @collection_images = catalog_collection_images(collection_ids)

    primary_ids = @images.map { |img| img[:primary_image_id] }.compact.uniq
    @primary_lookup = primary_ids.empty? ? {} :
      Images.where(id: primary_ids).select_hash(:id, :mini_name)

    @unlinked_colorized_count = if !@folder_filter.empty?
      Images.where(source_folder: @folder_filter, colorized: true, primary_image_id: nil)
            .exclude(Sequel.ilike(:mini_name, 'bundle'))
            .count
    else
      0
    end

    # Top species for quick-pick buttons
    fallback_species = %w[HUMAN ROBOT VEHICLE ALIEN CREATURE UNDEAD BEAST]
    db_species = Images
      .where(Sequel.~(species: nil))
      .exclude(species: '')
      .select_map(:species)
      .flat_map { |s| s.split(',').map(&:strip).map(&:upcase) }
      .reject(&:empty?)
      .tally
      .sort_by { |_, v| -v }
      .map(&:first)
    @top_species = (db_species + (fallback_species - db_species)).first(8)

    # Top stance for quick-pick buttons
    fallback_stance = %w[STANDING CROUCHING RUNNING KNEELING CHARGING PRONE JUMPING COMBAT FLYING AIMING MOUNTED]
    db_stance = Images
      .where(Sequel.~(stance: nil))
      .exclude(stance: '')
      .select_map(:stance)
      .flat_map { |s| s.split(',').map(&:strip).map(&:upcase) }
      .reject(&:empty?)
      .tally
      .sort_by { |_, v| -v }
      .map(&:first)
    @top_stance = (db_stance + (fallback_stance - db_stance)).first(8)

    # Top weapons for quick-pick buttons
    fallback_weapons = ['SWORD', 'PISTOL', 'RIFLE', 'KNIFE', 'STAFF', 'SHIELD', 'BOW', 'AXE', 'MACHINE GUN']
    db_weapons = Images
      .where(Sequel.~(weapons: nil))
      .exclude(weapons: '')
      .select_map(:weapons)
      .flat_map { |w| w.split(',').map(&:strip).map(&:upcase) }
      .reject(&:empty?)
      .tally
      .sort_by { |_, v| -v }
      .map(&:first)
    @top_weapons = (['NONE'] + (db_weapons + (fallback_weapons - db_weapons)).reject { |w| w == 'NONE' }).first(9)

    # Per-species weapon stats for adaptive quickpick buttons
    @weapons_by_species = {}
    Images
      .where(Sequel.~(weapons: nil)).exclude(weapons: '')
      .where(Sequel.~(species: nil)).exclude(species: '')
      .select_map([:species, :weapons])
      .each do |sp_raw, wp_raw|
        sp_raw.split(',').map(&:strip).map(&:upcase).each do |sp|
          wp_raw.split(',').map(&:strip).map(&:upcase).each do |wp|
            @weapons_by_species[sp] ||= Hash.new(0)
            @weapons_by_species[sp][wp] += 1
          end
        end
      end
    @weapons_by_species.transform_values! do |tally|
      (['NONE'] + tally.sort_by { |_, v| -v }.map(&:first).reject { |w| w == 'NONE' }).first(9)
    end

    # Per-species stance stats for adaptive quickpick buttons
    @stance_by_species = {}
    Images
      .where(Sequel.~(stance: nil)).exclude(stance: '')
      .where(Sequel.~(species: nil)).exclude(species: '')
      .select_map([:species, :stance])
      .each do |sp_raw, st_raw|
        sp_raw.split(',').map(&:strip).map(&:upcase).each do |sp|
          st_raw.split(',').map(&:strip).map(&:upcase).each do |st|
            @stance_by_species[sp] ||= Hash.new(0)
            @stance_by_species[sp][st] += 1
          end
        end
      end
    @stance_by_species.transform_values! do |tally|
      tally.sort_by { |_, v| -v }.map(&:first).first(8)
    end

    # Check if this collection is missing a bundle/gallery image
    # (an image with mini_count >= 4 or named 'bundle')
    @missing_bundle = if !@folder_filter.empty?
      !Images.where(source_folder: @folder_filter)
             .where(
               Sequel.expr { mini_count >= 4 } |
               Sequel.ilike(:mini_name, 'bundle')
             ).any?
    else
      false
    end
  end


  # Sort image rows: cover → bundles (alpha) → primaries (alpha),
  # each followed by their secondaries (alpha). Orphans appended last.
  def catalog_sort_images(all_rows, cover_ids)
    by_primary = Hash.new { |h, k| h[k] = [] }
    primaries_and_unlinked = []

    all_rows.each do |img|
      if img[:primary_image_id]
        by_primary[img[:primary_image_id]] << img
      else
        primaries_and_unlinked << img
      end
    end

    covers,  non_covers = primaries_and_unlinked.partition { |img| cover_ids.include?(img[:id]) }
    bundles, rest       = non_covers.partition { |img|
      img[:mini_count].to_i >= 4 || img[:mini_name].to_s.downcase == 'bundle'
    }
    primaries_and_unlinked = covers +
                             bundles.sort_by { |img| img[:mini_name].to_s.downcase } +
                             rest.sort_by    { |img| img[:mini_name].to_s.downcase }

    ordered = []
    primaries_and_unlinked.each do |img|
      ordered << img
      if by_primary.key?(img[:id])
        ordered.concat(by_primary[img[:id]].sort_by { |s| s[:mini_name].to_s.downcase })
      end
    end

    linked_ids = primaries_and_unlinked.map { |img| img[:id] }
    by_primary.each do |primary_id, secs|
      next if linked_ids.include?(primary_id)
      ordered.concat(secs)
    end

    ordered
  end

  # Build xref dropdown candidates for a set of collection ids
  def catalog_collection_images(collection_ids)
    result = {}
    collection_ids.each do |cid|
      cid_cover = Collections.where(id: cid).get(:cover_image_id)
      rows = Images.where(collection_id: cid, primary_image_id: nil)
                   .select(:id, :mini_name, :filename, :stance, :weapons, :mini_count, :colorized)
                   .all
      cover_row,  non_cover  = rows.partition { |r| r[:id] == cid_cover }
      bundle_rows, rest_rows = non_cover.partition { |r|
        r[:mini_count].to_i >= 4 || r[:mini_name].to_s.downcase == 'bundle'
      }
      result[cid] = cover_row +
                    bundle_rows.sort_by { |r| r[:mini_name].to_s.downcase } +
                    rest_rows.sort_by   { |r| r[:mini_name].to_s.downcase }
    end
    result
  end

end
