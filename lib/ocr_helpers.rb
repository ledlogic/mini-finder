# ocr_helpers.rb
# OCR and image-processing helpers for extracting mini names from UNIT9 images.
# Loaded by app.rb via: require_relative 'ocr_helpers'

OCR_CROP_ZONES = [
  { label: 'name-block-high',       x: 0.38, y: 0.63, w: 0.62, h: 0.20 },
  { label: 'name-block-mid',        x: 0.38, y: 0.70, w: 0.62, h: 0.20 },
  { label: 'name-block-low',        x: 0.38, y: 0.76, w: 0.62, h: 0.18 },
  { label: 'name-block-bottom',     x: 0.38, y: 0.80, w: 0.62, h: 0.18 },
  { label: 'name-block-wider',      x: 0.30, y: 0.63, w: 0.70, h: 0.25 },
  { label: 'name-block-right-only', x: 0.52, y: 0.72, w: 0.48, h: 0.26 },
].freeze

helpers do

  # Normalise accented characters Tesseract commonly mangles
  def ocr_normalise_accents(str)
    str
      .gsub(/[ŌÖO]\s*(?=[A-Z])/, 'O')
      .gsub(/Ō/, 'O').gsub(/ō/, 'o')
      .gsub(/Ū/, 'U').gsub(/ū/, 'u')
      .gsub(/É/, 'E').gsub(/é/, 'e')
      .gsub(/Á/, 'A').gsub(/á/, 'a')
      .gsub(/Í/, 'I').gsub(/í/, 'i')
  end

  # Clean a raw OCR line into a usable name candidate
  def ocr_clean_line(line)
    cleaned = line.gsub(/^[^A-Za-z\'"-]+/, '').strip
    cleaned = cleaned.gsub(/[|\\@#$%^&*_=<>{}\[\]]/, '').strip
    cleaned = cleaned.gsub(/\s+/, ' ').strip
    letter_ratio = cleaned.gsub(/[^A-Za-z]/, '').length.to_f / [cleaned.length, 1].max
    return nil if cleaned.length < 2 || letter_ratio < 0.4
    ocr_normalise_accents(cleaned)
  end

  # Try to join split names e.g. YŪGEN / JII-SAN across two OCR lines
  def ocr_join_split_name(lines)
    return lines if lines.length < 2
    collection_words = /corp|friends|raiders|nomads|officer|sisters|squad|tribe/i
    result = []
    i = 0
    while i < lines.length
      line      = lines[i]
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

  # Score a set of name candidates — longer/more words = better
  def ocr_zone_score(names)
    names.sum { |n| n.split.length * n.length }
  end

  # Collapse multi-line names where consecutive short lines form one name
  def ocr_collapse_name_lines(lines)
    return lines if lines.length < 2
    result = []
    i = 0
    while i < lines.length
      line = lines[i]
      if i + 1 < lines.length
        next_line      = lines[i + 1]
        combined_words = (line + ' ' + next_line).split.length
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

  # Extract mini name and collection name from a UNIT9 image via OCR
  # Returns { suggested_name: String|nil, collection_name: String|nil }
  def ocr_unit9_image(image_path)
    return { suggested_name: nil, collection_name: nil } unless File.exist?(image_path)

    orig = MiniMagick::Image.open(image_path)
    w    = orig.width
    h    = orig.height

    if w < MIN_OCR_WIDTH || h < MIN_OCR_WIDTH
      return { suggested_name: nil, collection_name: nil }
    end

    best_names = []
    best_score = 0

    OCR_CROP_ZONES.each do |zone|
      img    = MiniMagick::Image.open(image_path)
      crop_w = (w * zone[:w]).to_i
      crop_h = (h * zone[:h]).to_i
      crop_x = (w * zone[:x]).to_i
      crop_y = (h * zone[:y]).to_i

      img.crop "#{crop_w}x#{crop_h}+#{crop_x}+#{crop_y}"
      img.colorspace 'Gray'
      img.contrast
      img.contrast

      tmp = File.join(Dir.tmpdir, "unit9_ocr_#{Time.now.to_i}_#{rand(99999)}.jpg")
      img.write(tmp)

      raw   = RTesseract.new(tmp, psm: 6).to_s
      File.delete(tmp) if File.exist?(tmp)

      lines = raw.split("\n").map(&:strip).reject(&:empty?)
      names = lines.filter_map { |l| ocr_clean_line(l) }
      names = ocr_collapse_name_lines(names)
      names = ocr_join_split_name(names)
      score = ocr_zone_score(names)

      if score > best_score
        best_score = score
        best_names = names
      end
    end

    mini       = best_names[0]
    line1      = best_names[1]
    line2      = best_names[2]
    collection = if line2 && line1 && line1.split.length <= 3
      line2
    else
      line1
    end

    { suggested_name: mini, collection_name: collection }
  rescue => e
    warn "OCR failed for #{image_path}: #{e.message}"
    { suggested_name: nil, collection_name: nil }
  end

end
