# scripts/rename_collection_folder.rb
#
# Renames a collection folder on disk and updates all database references
# (collections.folder_path and images.source_folder) to match.
#
# Use this when you want to convert e.g. 2021-11 -> 2021-11-mmf while
# keeping all tagged names, print/paint counts, and linked images intact.
#
# Usage:
#   bundle exec ruby scripts/rename_collection_folder.rb <old_folder> <new_name>
#
# Examples:
#   # Convert to MMF (just give the new suffix, path is inferred):
#   bundle exec ruby scripts/rename_collection_folder.rb "G:/My Drive/STL/UNIT9/Cyberdreams/2021-11" "2021-11-mmf"
#
#   # Or give the full new path:
#   bundle exec ruby scripts/rename_collection_folder.rb "G:/My Drive/STL/UNIT9/Cyberdreams/2021-11" "G:/My Drive/STL/UNIT9/Cyberdreams/2021-11-mmf"
#
# Run without --rename first to preview. Add --rename to actually do it.

require 'sequel'
require 'fileutils'

DB          = Sequel.sqlite(File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db'))
Images      = DB[:images]
Collections = DB[:collections]

RENAME_MODE = ARGV.include?('--rename')

old_path = ARGV.reject { |a| a.start_with?('-') }[0]
new_arg  = ARGV.reject { |a| a.start_with?('-') }[1]

if old_path.nil? || new_arg.nil?
  puts "Usage: bundle exec ruby scripts/rename_collection_folder.rb <old_path> <new_name_or_path> [--rename]"
  puts ""
  puts "  <old_path>          Full path to the existing folder"
  puts "  <new_name_or_path>  Either just the new folder name (e.g. 2021-11-mmf)"
  puts "                      or the full new path"
  puts "  --rename            Actually perform the rename (default is preview only)"
  exit 1
end

# Normalize slashes
old_path = old_path.gsub('\\', '/').chomp('/')

# If new_arg looks like just a name (no slashes), build full path from old_path's parent
if new_arg.include?('/') || new_arg.include?('\\')
  new_path = new_arg.gsub('\\', '/').chomp('/')
else
  new_path = File.join(File.dirname(old_path), new_arg).gsub('\\', '/')
end

puts RENAME_MODE ? "Mode: RENAME\n\n" : "Mode: PREVIEW (run with --rename to apply)\n\n"
puts "  Old path : #{old_path}"
puts "  New path : #{new_path}"
puts ""

# ── Checks ────────────────────────────────────────────────────────────────────

unless Dir.exist?(old_path)
  puts "ERROR: Old folder does not exist on disk: #{old_path}"
  exit 1
end

if Dir.exist?(new_path)
  puts "ERROR: New folder already exists on disk: #{new_path}"
  puts "       Move or delete it first."
  exit 1
end

col = Collections.where(folder_path: old_path).first
unless col
  puts "ERROR: No collection found in DB with folder_path: #{old_path}"
  puts "       Run Scan Folder first to register it."
  exit 1
end

if Collections.where(folder_path: new_path).first
  puts "ERROR: A collection already exists in DB for: #{new_path}"
  exit 1
end

image_count = Images.where(collection_id: col[:id]).count

puts "  Collection : #{col[:name]} (id=#{col[:id]})"
puts "  Images     : #{image_count}"
puts ""

# ── Preview what will change ───────────────────────────────────────────────────

puts "Changes to make:"
puts "  1. Rename folder on disk:"
puts "       #{File.basename(old_path)}  ->  #{File.basename(new_path)}"
puts "  2. Update collections.folder_path"
puts "  3. Update #{image_count} rows in images.source_folder"
puts "  4. Rename companion PDF if it exists:"
pdf_old = old_path + ".pdf"
pdf_new = new_path + ".pdf"
if File.exist?(pdf_old)
  puts "       #{File.basename(pdf_old)}  ->  #{File.basename(pdf_new)}"
else
  puts "       (no PDF found at #{pdf_old})"
  pdf_old = nil
end
puts ""

unless RENAME_MODE
  puts "Run with --rename to apply these changes."
  exit
end

# ── Apply ─────────────────────────────────────────────────────────────────────

begin
  # 1. Rename folder on disk
  FileUtils.mv(old_path, new_path)
  puts "✓ Folder renamed on disk"

  # 2. Rename PDF if present
  if pdf_old && File.exist?(pdf_old)
    FileUtils.mv(pdf_old, pdf_new)
    puts "✓ PDF renamed"
  end

  # 3. Update DB inside a transaction so it's atomic
  DB.transaction do
    Collections.where(id: col[:id]).update(
      folder_path: new_path,
      updated_at:  Time.now
    )
    Images.where(collection_id: col[:id]).update(
      source_folder: new_path,
      updated_at:    Time.now
    )
  end
  puts "✓ Database updated (#{image_count} images)"

  puts ""
  puts "Done. All #{image_count} images retain their names, tags, print/paint counts,"
  puts "and cross-references. No re-scanning needed."

rescue => e
  puts ""
  puts "ERROR: #{e.message}"
  puts "The operation may be partially complete. Check folder and DB state carefully."
  exit 1
end
