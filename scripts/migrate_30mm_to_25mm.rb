#!/usr/bin/env ruby
# One-time migration: convert mini_size 30mm -> 25mm
# Run from project root: ruby scripts/migrate_30mm_to_25mm.rb

require 'dotenv/load'
require 'sequel'

DB_PATH = File.join(File.dirname(__FILE__), '..', 'db', 'catalog.db')
DB = Sequel.sqlite(DB_PATH)

puts "Mini-finder: 30mm -> 25mm migration"
puts "DB: #{DB_PATH}"
puts ""

dry_run = ARGV.include?('--dry-run')
puts dry_run ? "DRY RUN — no changes will be saved" : "LIVE RUN — changes will be saved"
puts ""

count = DB[:images].where(mini_size: '30mm').count
puts "Found #{count} image(s) with mini_size = '30mm'"

if count > 0 && !dry_run
  updated = DB[:images].where(mini_size: '30mm').update(mini_size: '25mm', updated_at: Time.now)
  puts "Updated #{updated} image(s): 30mm -> 25mm"
else
  puts dry_run ? "Would update #{count} image(s)" : "Nothing to update"
end

puts ""
puts "Done. Restart mini-finder to see updated statistics."
