# scripts/cleanup_bad_folders.rb
# Removes images and collections that were scanned from folders we no longer want:
#   - Folders ending in -cd
#   - Plain yyyy-mm folders that have an MMF sibling (yyyy-mm-mmf)
#
# Run in preview mode first, then with --delete to actually remove.
#
# Usage:
#   bundle exec ruby scripts/cleanup_bad_folders.rb           # preview
#   bundle exec ruby scripts/cleanup_bad_folders.rb --delete  # actually delete

require 'sequel'

DB          = Sequel.sqlite(File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db'))
Images      = DB[:images]
Collections = DB[:collections]

DELETE_MODE = ARGV.include?('--delete')

puts DELETE_MODE ? "Mode: DELETE\n\n" : "Mode: PREVIEW (run with --delete to remove)\n\n"

bad_folders = []

all_folders = Collections.select_map(:folder_path).sort

all_folders.each do |folder|
  base = File.basename(folder)
  parent = File.dirname(folder)

  # Rule 1: skip -cd folders
  if base.end_with?('-cd')
    bad_folders << { folder: folder, reason: 'ends in -cd' }
    next
  end

  # Rule 2: skip plain yyyy-mm if an MMF sibling exists
  if base.match?(/^\d{4}-\d{2}$/)
    mmf_sibling = File.join(parent, base + '-mmf')
    if all_folders.include?(mmf_sibling)
      bad_folders << { folder: folder, reason: "MMF sibling exists (#{File.basename(mmf_sibling)})" }
    end
  end
end

if bad_folders.empty?
  puts "No bad folders found — nothing to clean up."
  exit
end

puts "Found #{bad_folders.length} folder(s) to remove:\n\n"
printf "%-60s %s\n", 'Folder', 'Reason'
puts '-' * 90

total_images = 0
total_cols   = 0

bad_folders.each do |entry|
  folder = entry[:folder]
  col    = Collections.where(folder_path: folder).first
  count  = col ? Images.where(collection_id: col[:id]).count : 0

  printf "%-60s %s (%d images)\n", File.basename(folder), entry[:reason], count
  total_images += count
  total_cols   += 1

  if DELETE_MODE
    if col
      Images.where(collection_id: col[:id]).delete
      Collections.where(id: col[:id]).delete
    end
  end
end

puts '-' * 90
puts "Total: #{total_cols} collection(s), #{total_images} image(s)"
puts ""

if DELETE_MODE
  puts "✓ Deleted. Run 'Scan Folder' to re-register any images from correct folders."
else
  puts "Run with --delete to remove these from the database."
end
