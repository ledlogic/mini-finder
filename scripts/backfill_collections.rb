# scripts/backfill_collections.rb
# Run this once to create collection records for all existing images
# that were scanned before the collections feature was added.
# Safe to run multiple times — skips folders that already have a collection.

require 'sequel'

DB          = Sequel.sqlite(File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db'))
Collections = DB[:collections]
Images      = DB[:images]

def parse_release_month(folder)
  base = File.basename(folder)
  if (m = base.match(/(\d{4})-(\d{2})/))
    "#{m[1]}-#{m[2]}"
  elsif (m = base.match(/(\d{4})(\d{2})/))
    "#{m[1]}-#{m[2]}"
  end
end

folders = Images.distinct.select_map(:source_folder).sort
puts "Backfilling #{folders.length} folders...\n\n"

created = 0
skipped = 0
linked  = 0

folders.each do |folder|
  if Collections.where(folder_path: folder).any?
    skipped += 1
    puts "  SKIP : #{File.basename(folder)}"
    next
  end

  col_id = Collections.insert(
    folder_path:   folder,
    release_month: parse_release_month(folder),
    created_at:    Time.now,
    updated_at:    Time.now
  )

  count = Images.where(source_folder: folder).update(collection_id: col_id)
  linked  += count
  created += 1
  puts "  OK   : #{File.basename(folder)} → #{count} images linked"
end

puts "\n─────────────────────────────────────"
puts "Collections created : #{created}"
puts "Collections skipped : #{skipped}"
puts "Images linked       : #{linked}"
puts "─────────────────────────────────────"
