#!/usr/bin/env ruby
# One-time script: force ALL mini_name values to UPPERCASE in the DB
# Run from project root: ruby scripts/uppercase_names.rb

require 'dotenv/load'
require 'sequel'

DB_PATH = File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db')
DB = Sequel.sqlite(DB_PATH)

puts "mini-finder: UPPERCASE all mini names"
puts "DB: #{DB_PATH}"
puts ""

# SQLite supports UPPER() — do it in one SQL statement for speed
before = DB[:images].where(Sequel.~(mini_name: nil)).exclude(mini_name: '').count

updated = DB.run("UPDATE images SET mini_name = UPPER(mini_name), updated_at = datetime('now') WHERE mini_name IS NOT NULL AND mini_name != ''")

after_check = DB[:images].where(Sequel.~(mini_name: nil)).exclude(mini_name: '').count

puts "Images with names: #{before}"
puts "SQL UPDATE executed against all #{before} named images."
puts ""

# Verify a sample
samples = DB[:images].where(Sequel.~(mini_name: nil)).exclude(mini_name: '').limit(5).select_map(:mini_name)
puts "Sample names after update:"
samples.each { |n| puts "  #{n.inspect}" }

puts ""
puts "Done. Restart mini-finder to see changes."
