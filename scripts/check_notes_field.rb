#!/usr/bin/env ruby
# Check whether the notes field has any data in images or collections tables.
# If empty, optionally clears it (SQLite cannot DROP COLUMN without rebuilding table).
#
# Run from project root:
#   ruby scripts/check_notes_field.rb          # check only
#   ruby scripts/check_notes_field.rb --clear  # zero out all notes values

require 'dotenv/load'
require 'sequel'

DB_PATH = File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db')
DB = Sequel.sqlite(DB_PATH)

puts "mini-finder: notes field audit"
puts "DB: #{DB_PATH}"
puts ""

image_count      = DB[:images].where(Sequel.~(notes: nil)).exclude(notes: '').count
collection_count = DB[:collections].where(Sequel.~(notes: nil)).exclude(notes: '').count

puts "Images      with notes data: #{image_count}"
puts "Collections with notes data: #{collection_count}"
puts ""

if image_count == 0 && collection_count == 0
  puts "✓ Notes field is completely empty — safe to stop using."
  if ARGV.include?('--clear')
    puts "Nothing to clear (already empty)."
  else
    puts "Run with --clear to zero out the column values (no-op here)."
  end
else
  puts "⚠ Notes field has data — review before removing."
  if ARGV.include?('--clear')
    puts "Clearing all notes values..."
    n1 = DB[:images].update(notes: nil)
    n2 = DB[:collections].update(notes: nil)
    puts "Cleared #{n1} image(s) and #{n2} collection(s)."
    puts "Restart mini-finder to confirm."
  else
    puts "Run with --clear to wipe all notes data, or review it first:"
    puts ""
    puts "-- Images with notes:"
    DB[:images].where(Sequel.~(notes: nil)).exclude(notes: '').each do |img|
      puts "  id=#{img[:id]} filename=#{img[:filename]} notes=#{img[:notes].inspect}"
    end
    puts ""
    puts "-- Collections with notes:"
    DB[:collections].where(Sequel.~(notes: nil)).exclude(notes: '').each do |col|
      puts "  id=#{col[:id]} name=#{col[:name].inspect} notes=#{col[:notes].inspect}"
    end
  end
end

puts ""
puts "Note: SQLite cannot DROP COLUMN without rebuilding the table."
puts "If notes is empty, the recommended approach is to stop reading/writing"
puts "it in the app rather than attempting a table rebuild."
