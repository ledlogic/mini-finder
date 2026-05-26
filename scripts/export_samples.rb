# scripts/export_samples.rb
# Picks N random images from each folder and zips them up for sharing.
# Usage:
#   bundle exec ruby scripts/export_samples.rb           # 2 per folder (default)
#   bundle exec ruby scripts/export_samples.rb 3         # 3 per folder

require 'sequel'
require 'zip'    # rubyzip gem
require 'fileutils'

SAMPLES_PER_FOLDER = (ARGV[0] || 2).to_i
OUTPUT_ZIP = File.join(File.dirname(__FILE__), '..', 'sample_images.zip')

DB     = Sequel.sqlite(File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db'))
Images = DB[:images]

folders = Images.distinct.select_map(:source_folder).sort
puts "Folders: #{folders.length}"
puts "Samples per folder: #{SAMPLES_PER_FOLDER}"
puts "Output: #{OUTPUT_ZIP}\n\n"

File.delete(OUTPUT_ZIP) if File.exist?(OUTPUT_ZIP)

total = 0
missing = 0

Zip::File.open(OUTPUT_ZIP, Zip::File::CREATE) do |zip|
  folders.each do |folder|
    folder_name = File.basename(folder)

    # Get all images in this folder that exist on disk
    candidates = Images
      .where(source_folder: folder)
      .all
      .select { |img| File.exist?(File.join(img[:source_folder], img[:filename])) }

    if candidates.empty?
      puts "  SKIP #{folder_name} — no files on disk"
      missing += 1
      next
    end

    # Pick N random samples
    samples = candidates.sample(SAMPLES_PER_FOLDER)

    samples.each do |img|
      src  = File.join(img[:source_folder], img[:filename])
      dest = File.join(folder_name, img[:filename])
      zip.add(dest, src)
      total += 1
    end

    puts "  OK   #{folder_name} — #{samples.length} image(s) added"
  end
end

puts "\n─────────────────────────────────────"
puts "Total images zipped : #{total}"
puts "Folders skipped     : #{missing}"
puts "Zip saved to        : #{OUTPUT_ZIP}"
puts "─────────────────────────────────────"
