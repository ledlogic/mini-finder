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
      text_fields = %i[mini_name species weapons stance notes]
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

end