# scripts/ocr_collections.rb
# Samples images per collection folder, runs improved multi-zone OCR,
# and suggests a collection name. Prints a preview — confirm before saving.
#
# Usage:
#   bundle exec ruby scripts/ocr_collections.rb           # preview only
#   bundle exec ruby scripts/ocr_collections.rb --save    # save to DB

require 'sequel'
require 'rtesseract'
require 'mini_magick'
require 'tmpdir'

DB          = Sequel.sqlite(File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db'))
Collections = DB[:collections]
Images      = DB[:images]

SAVE_MODE     = ARGV.include?('--save')
MIN_OCR_WIDTH = 400   # skip tiny thumbnails
SAMPLES_TO_TRY = 5   # try up to N images per folder until OCR succeeds

CROP_ZONES = [
  { label: 'name-block-high',  x: 0.38, y: 0.63, w: 0.62, h: 0.20 },
  { label: 'name-block-mid',   x: 0.38, y: 0.70, w: 0.62, h: 0.20 },
  { label: 'name-block-low',   x: 0.38, y: 0.76, w: 0.62, h: 0.18 },
  { label: 'name-block-wider', x: 0.30, y: 0.63, w: 0.70, h: 0.25 },
].freeze

def normalise_accents(str)
  str
    .gsub(/Ō/, 'O').gsub(/ō/, 'o')
    .gsub(/Ū/, 'U').gsub(/ū/, 'u')
    .gsub(/É/, 'E').gsub(/é/, 'e')
    .gsub(/Á/, 'A').gsub(/á/, 'a')
    .gsub(/Í/, 'I').gsub(/í/, 'i')
end

def clean_ocr_line(line)
  cleaned = line.gsub(/^[^A-Za-z]+/, '').strip
  cleaned = cleaned.gsub(/[|\\@#$%^&*_=<>{}]/, '').strip
  letter_ratio = cleaned.gsub(/[^A-Za-z]/, '').length.to_f / [cleaned.length, 1].max
  return nil if cleaned.length < 3 || letter_ratio < 0.5
  normalise_accents(cleaned)
end

def zone_score(names)
  names.sum { |n| n.split.length * n.length }
end

def collapse_name_lines(lines)
  return lines if lines.length < 2
  result = []
  i = 0
  while i < lines.length
    line = lines[i]
    if i + 1 < lines.length
      next_line = lines[i + 1]
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

def ocr_image(image_path)
  return nil unless File.exist?(image_path)

  orig = MiniMagick::Image.open(image_path)
  w    = orig.width
  h    = orig.height

  return { suggested_name: nil, collection_name: nil, skipped: 'too small' } if w < MIN_OCR_WIDTH

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
    img.contrast
    img.contrast

    tmp = File.join(Dir.tmpdir, "ocr_col_#{Time.now.to_i}_#{rand(99999)}.jpg")
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

  { suggested_name: best_names[0], collection_name: best_names[1] }
rescue => e
  { suggested_name: nil, collection_name: nil, error: e.message }
end

# ── Main ───────────────────────────────────────────────────────────────────
puts SAVE_MODE ? "Mode: SAVE\n\n" : "Mode: PREVIEW (run with --save to write to DB)\n\n"
printf "%-14s %-32s %-28s %s\n", 'Folder', 'OCR Mini Name', 'OCR Collection', 'Status'
puts '─' * 100

saved = skipped = failed = 0

Collections.order(:release_month).each do |col|
  folder_label = File.basename(col[:folder_path])

  # Try up to SAMPLES_TO_TRY images until one gives a result
  candidates = Images
    .where(source_folder: col[:folder_path])
    .order(:filename)
    .all
    .select { |img| File.exist?(File.join(img[:source_folder], img[:filename])) }

  if candidates.empty?
    printf "%-14s %-32s %-28s %s\n", folder_label, '—', '—', 'NO FILES ON DISK'
    failed += 1
    next
  end

  result = nil
  tried  = 0

  candidates.first(SAMPLES_TO_TRY).each do |img|
    tried += 1
    path = File.join(img[:source_folder], img[:filename])
    r = ocr_image(path)
    if r[:skipped]
      result = r
      break  # all images in folder will be same size, no point trying more
    end
    if r[:suggested_name] || r[:collection_name]
      result = r
      break
    end
    result = r  # keep last even if empty
  end

  mini_name = result[:suggested_name]  || '—'
  col_name  = result[:collection_name] || '—'

  if result[:skipped]
    status = "SKIP (#{result[:skipped]})"
    skipped += 1
  elsif result[:error]
    status = "ERROR: #{result[:error]}"
    failed += 1
  elsif SAVE_MODE && result[:collection_name]
    if col[:name].to_s.strip.empty?
      Collections.where(id: col[:id]).update(name: result[:collection_name], updated_at: Time.now)
      status = 'SAVED'
      saved += 1
    else
      status = "KEPT: #{col[:name]}"
      skipped += 1
    end
  elsif SAVE_MODE
    status = 'NO NAME FOUND'
    failed += 1
  else
    status = "preview (tried #{tried})"
    skipped += 1
  end

  printf "%-14s %-32s %-28s %s\n", folder_label, mini_name[0..31], col_name[0..27], status
end

puts '─' * 100
if SAVE_MODE
  puts "Saved: #{saved}  Skipped/kept: #{skipped}  Failed: #{failed}"
else
  puts "Run with --save to write collection names to DB."
end
