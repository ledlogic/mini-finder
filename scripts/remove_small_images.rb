# scripts/remove_small_images.rb
#
# Finds catalog images whose width AND height are both below a threshold
# (default 500px) and removes them from the database (and optionally from
# disk).
#
# Usage:
#   bundle exec ruby scripts/remove_small_images.rb               # preview
#   bundle exec ruby scripts/remove_small_images.rb --delete      # remove from DB only
#   bundle exec ruby scripts/remove_small_images.rb --delete --delete-files
#                                                                   # also delete the files from disk
#   bundle exec ruby scripts/remove_small_images.rb --min 800      # custom threshold
#
# An image is considered "too small" only if BOTH its width and height are
# below the threshold. This avoids flagging legitimately tall/wide crops.

require 'sequel'
require 'mini_magick'

DB     = Sequel.sqlite(File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db'))
Images = DB[:images]

DELETE_MODE  = ARGV.include?('--delete')
DELETE_FILES = ARGV.include?('--delete-files')

min_idx = ARGV.index('--min')
MIN_SIZE = min_idx ? ARGV[min_idx + 1].to_i : 500

puts DELETE_MODE ? "Mode: DELETE (DB rows)" : "Mode: PREVIEW (run with --delete to remove from DB)"
puts "Also deleting files from disk: #{DELETE_FILES}" if DELETE_MODE
puts "Threshold: both width and height < #{MIN_SIZE}px"
puts ""

removed   = 0
checked   = 0
missing   = 0
to_remove = []

total = Images.count
puts "Scanning #{total} image(s)..."
puts ""

Images.each do |row|
  checked += 1
  if checked % 100 == 0 || checked == total
    print "\r  #{checked}/#{total} checked..."
    $stdout.flush
  end
  path = File.join(row[:source_folder], row[:filename])

  unless File.exist?(path)
    missing += 1
    next
  end

  begin
    img = MiniMagick::Image.open(path)
    w, h = img.width, img.height
  rescue => e
    puts "  ! Could not read #{path}: #{e.message}"
    next
  end

  next unless w < MIN_SIZE && h < MIN_SIZE

  to_remove << { id: row[:id], path: path, w: w, h: h, name: row[:mini_name] }
end

puts "" # finish the progress line

if to_remove.empty?
  puts "Nothing to remove (checked #{checked} images, #{missing} missing on disk)."
  exit
end

to_remove.each do |entry|
  label = entry[:name].to_s.empty? ? File.basename(entry[:path]) : entry[:name]
  puts "REMOVE: #{label}  (#{entry[:w]}x#{entry[:h]})  #{entry[:path]}"

  if DELETE_MODE
    Images.where(id: entry[:id]).delete
    removed += 1
    if DELETE_FILES
      begin
        File.delete(entry[:path])
        puts "  ✓ Deleted DB row + file"
      rescue => e
        puts "  ✓ Deleted DB row (file delete failed: #{e.message})"
      end
    else
      puts "  ✓ Deleted DB row (file left on disk)"
    end
  end
end

puts ""
puts "Checked #{checked} images (#{missing} missing on disk)."
puts "#{to_remove.length} image(s) under #{MIN_SIZE}px on both dimensions."
puts DELETE_MODE ? "#{removed} removed." : "Run with --delete to remove from DB (add --delete-files to also delete files)."