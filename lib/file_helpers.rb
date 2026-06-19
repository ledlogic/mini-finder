# file_helpers.rb
# Filesystem and path helpers — all things that touch disk paths.
# Loaded by app.rb via: require_relative 'file_helpers'

helpers do

  # ─── Image paths ─────────────────────────────────────────────────────────────

  # Full disk path to an image file from a DB row
  def file_image_path(row)
    File.join(row[:source_folder], row[:filename])
  end

  # Returns the source PDF path for a collection folder if it exists on disk
  def file_collection_pdf_path(folder_path)
    pdf = folder_path + ".pdf"
    File.exist?(pdf) ? pdf : nil
  end

  # ─── Folder / month parsing ────────────────────────────────────────────────

  # Parse a YYYY-MM release month from a folder name
  def file_parse_release_month(folder_name)
    base = File.basename(folder_name)
    if (m = base.match(/(\d{4})-(\d{2})/))
      "#{m[1]}-#{m[2]}"
    elsif (m = base.match(/(\d{4})(\d{2})/))
      "#{m[1]}-#{m[2]}"
    end
  end

  # Returns true if folder is an MMF folder (ends in -mmf)
  def file_mmf_folder?(folder_path)
    File.basename(folder_path).end_with?('-mmf')
  end

  # Extracts base month from MMF folder e.g. "2026-06-mmf" -> "2026-06"
  def file_mmf_base_month(folder_path)
    File.basename(folder_path).sub(/-mmf$/, '')
  end

  # Extract mini name from MMF filename by stripping prefix/suffix and splitting CamelCase
  # e.g. "0002_June24-adv-1080-XiuYing02.jpg" -> "Xiu Ying"
  def file_extract_mmf_name(filename)
    name  = File.basename(filename, '.*')
    name  = name.sub(/^\d+_/, '')
    raw   = name.split('-').last.to_s
    raw   = raw.sub(/\d+$/, '').strip
    return nil if raw.empty?
    return 'Bundle' if BUNDLE_WORDS.include?(raw.downcase)
    return nil if SKIP_NAME_WORDS.include?(raw.downcase)
    raw.gsub(/([A-Z])/, ' \1').strip
  end

end
