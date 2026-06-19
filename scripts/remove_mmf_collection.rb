# scripts/remove_mmf_collection.rb
# Removes plain yyyy-mm collections when an MMF sibling exists.
# e.g. keeps 2024-06-mmf, removes 2024-06
#
# Usage:
#   bundle exec ruby scripts/remove_mmf_collection.rb           # preview
#   bundle exec ruby scripts/remove_mmf_collection.rb --delete  # actually delete

require 'sequel'

DB          = Sequel.sqlite(File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db'))
Images      = DB[:images]
Collections = DB[:collections]

DELETE_MODE = ARGV.include?('--delete')
puts DELETE_MODE ? "Mode: DELETE\n\n" : "Mode: PREVIEW (run with --delete to remove)\n\n"

all_folders = Collections.select_map(:folder_path)

to_remove = []

all_folders.each do |folder|
  base   = File.basename(folder)
  parent = File.dirname(folder)

  # Plain yyyy-mm that has an MMF sibling
  if base.match?(/^\d{4}-\d{2}$/)
    mmf_sibling = File.join(parent, base + '-mmf')
    if all_folders.include?(mmf_sibling)
      to_remove << { folder: folder, kept: mmf_sibling }
    end
  end
end

if to_remove.empty?
  puts "Nothing to remove."
  exit
end

to_remove.each do |entry|
  col   = Collections.where(folder_path: entry[:folder]).first
  count = col ? Images.where(collection_id: col[:id]).count : 0
  puts "REMOVE: #{File.basename(entry[:folder])} (#{count} images)"
  puts "  KEEP: #{File.basename(entry[:kept])}"
  puts ""

  if DELETE_MODE && col
    Images.where(collection_id: col[:id]).delete
    Collections.where(id: col[:id]).delete
    puts "  ✓ Deleted"
  end
end

puts DELETE_MODE ? "\nDone. Click Scan Folder to re-register from MMF folders." : "\nRun with --delete to remove."
