# helpers.rb
# Sinatra helper methods — shared across all routes and views.
# Loaded by app.rb via: require_relative 'helpers'
#
# Contains:
#   - levenshtein()       fuzzy string distance
#   - score_row()         search scoring logic
#   - q()                 URL query string builder
#   - hl_field()          search result highlight renderer
#   - full_path()         image file path builder
#   - collection_pdf_path() source PDF existence check
#   - pdf_url()           server URL for streaming a collection PDF
#   - collection_for_folder()
#   - parse_release_month()

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

  # Build a MyMiniFactory search URL for a collection
  # release_month "YYYY-MM" -> "august24"
  MONTH_NAMES = %w[january february march april may june
                   july august september october november december].freeze

  def mmf_search_url(release_month)
    return nil unless release_month && release_month.match(/^\d{4}-\d{2}$/)
    year, month = release_month.split("-").map(&:to_i)
    month_name  = MONTH_NAMES[month - 1]
    short_year  = year.to_s[-2..]
    query       = "unit9 #{month_name}#{short_year}"
    json        = %Q({"searchString":"#{query}","categories":[],"designType":"premium-only","sortingKey":"relevance","tags":[]})
    encoded     = json.gsub('{', '%7B').gsub('}', '%7D')
                      .gsub('"'  , '%22').gsub(' '  , '%20')
                      .gsub('['  , '%5B').gsub(']'  , '%5D')
                      .gsub(':'  , '%3A').gsub(','  , '%2C')
    "https://www.myminifactory.com/search#/?#{encoded}"
  end

  # Highlight matched terms in a comma-separated field value
  # Build a query string from a hash of params
  def q(h)
    h.reject { |_, v| v.to_s.empty? }.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
  end

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
  # Build a query string from a hash of params
  def q(h)
    h.reject { |_, v| v.to_s.empty? }.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
  end

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