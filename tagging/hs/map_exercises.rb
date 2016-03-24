#!/usr/bin/env ruby

require 'roo'
require 'axlsx'
require 'httparty'
require_relative '../../cnx/lib/book'

OUTPUT_HEADERS = ['Exercises', 'CNXMOD Tags', 'LO Tags']

BOOK_MAPS = {
  'k12phys' => { col_name: 'stax-phys', col_uuid: '031da8d3-b525-429c-80cf-6c8ed997733a' },
  'apbio' => { col_name: 'stax-bio', col_uuid: '185cbf87-c72e-48f5-b51e-f14f21b5eabd' }
}

class Array
  alias_method :blank?, :empty?
end

if ARGV.length < 3 || ARGV.length > 4
  puts 'Usage: hs/map_exercises.rb hs_book_name input_spreadsheet output_spreadsheet [exercises_base_url]'
  puts 'Takes as input a spreadsheet with the following columns:'
  puts '1. Origin LO or book location (chapter.section)'
  puts '2. Target LO or book location'
  puts 'Writes an xlsx file with name output_spreadsheet containing a list of Exercise numbers'
  puts 'and the tags that will be associated with those exercises'
  abort
end

hs_book_name = ARGV[0]
book_map = BOOK_MAPS[hs_book_name]
raise "Invalid HS book name: #{hs_book_name}" if book_map.nil?

col_book_name = book_map[:col_name]
col_book_uuid = book_map[:col_uuid]

book_url = "https://archive.cnx.org/contents/#{col_book_uuid}"
book = CNX::Book.fetch(book_url)

input_filename = ARGV[1]
output_filename = ARGV[2]
exercises_base_url = ARGV[3] || 'https://exercises.openstax.org'

chapter_section_map = Hash.new do |hash, key|
  hash[key] = Hash.new{ |hash, key| hash[key] = SortedSet.new }
end
dest_uuid_map = Hash.new{ |hash, key| hash[key] = {} }

lo_map = Hash.new do |hash, key|
  hash[key] = Hash.new do |hash, key|
    hash[key] = Hash.new{ |hash, key| hash[key] = SortedSet.new }
  end
end

input_sheet = Roo::Excelx.new(input_filename)
input_sheet.each_row_streaming(offset: 1, pad_cells: true) do |row|
  values = 0.upto(row.size - 1).map{ |index| (row[index] || OpenStruct.new).value.to_s }
  next if values.compact.blank?

  origins = values[0].split(',')
  destinations = values[1].split(',')

  orig_matches = origins.map do |origin|
    /(\d+)-(\d+)-(\d+)/.match(origin) || /(\d+).(\d+)/.match(origin) || \
      raise("Invalid Origin: #{origin}")
  end

  dest_matches = destinations.map do |destination|
    /(\d+)-(\d+)-(\d+)/.match(destination) || /(\d+).(\d+)/.match(destination) || \
      raise("Invalid Destination: #{destination}")
  end

  orig_matches.each do |orig_match|
    orig_chapter = orig_match[1]
    orig_section = orig_match[2]
    orig_lo = orig_match[3]

    dest_matches.each do |dest_match|
      dest_chapter = dest_match[1]
      dest_section = dest_match[2]
      dest_lo = dest_match[3]

      dest_chapter_num = dest_chapter.to_i
      dest_section_num = dest_section.to_i

      section = book.chapters[dest_chapter_num].sections[dest_section_num]
      raise "No such chapter/section in #{col_book_name}: #{dest_match[0]}" if section.nil?

      dest_uuid = section.id.split('@').first

      chapter_section_map[orig_chapter][orig_section] << [dest_chapter_num, dest_section_num]
      dest_uuid_map[dest_chapter_num][dest_section_num] = dest_uuid

      next if orig_lo.nil? || dest_lo.nil?

      lo_map[orig_chapter][orig_section][orig_lo] << [dest_chapter_num,
                                                      dest_section_num,
                                                      dest_lo.to_i]
    end
  end
end

Axlsx::Package.new do |package|
  package.workbook.add_worksheet(name: 'Map') do |output_sheet|
    bold = output_sheet.styles.add_style b: true
    output_sheet.add_row OUTPUT_HEADERS, style: bold

    chapter_section_map.each do |chapter_num, section_map|
      chapter_lo_map = lo_map[chapter_num]
      section_map.each do |section_num, dest_sections|
        dest_sections = dest_sections.to_a
        last_section = dest_sections.last

        section_lo_map = chapter_lo_map[section_num]
        section_tag = "#{hs_book_name}-ch%02d-s%02d" % [chapter_num, section_num]
        lo_regex = Regexp.new "\\A#{section_tag}-(?:ap)?lo-?([\\d-]+)\\z"
        exercises_hash = HTTParty.get("#{exercises_base_url}/api/exercises?q=tag:#{section_tag}")
                                 .to_hash
        grouped_exercises = exercises_hash['items'].group_by do |exercise_hash|
          tags = exercise_hash['tags']
          lo_numbers = tags.map do |tag|
            matches = lo_regex.match(tag)
            matches[1].reverse.chomp('0').reverse unless matches.nil?
          end.compact.sort
          puts "WARNING: No LO matching the section tag found in: #{tags.inspect}" \
            if lo_numbers.empty?
          lo_numbers
        end

        grouped_exercises.each do |lo_numbers, exercises|
          exercise_numbers = exercises.map{ |exercise| exercise['number'] }.join(',')
          los = lo_numbers.map{ |lo_number| section_lo_map[lo_number] }.reduce(:+).to_a
          last_lo = los.last

          cnxmod_tags = []
          lo_tags = []
          if last_lo.nil?
            last_chapter_num = last_section[0]
            last_section_num = last_section[1]

            cnxmod_tags = dest_sections.map do |chapter_num, section_num|
              prefix = (chapter_num == last_chapter_num && section_num == last_section_num) ? \
                         '' : 'alternate-'
              uuid = dest_uuid_map[chapter_num][section_num]
              "#{prefix}cnxmod:#{uuid}"
            end
          else
            last_chapter_num = last_lo[0]
            last_section_num = last_lo[1]

            los.group_by do |chapter_num, section_num, lo_num|
              [chapter_num, section_num]
            end.each do |(chapter_num, section_num), los|
              prefix = (chapter_num == last_chapter_num && section_num == last_section_num) ? \
                         '' : 'alternate-'
              cnxmod_tags << "#{prefix}cnxmod:#{dest_uuid_map[chapter_num][section_num]}"
              lo_tags += los.map do |_, _, lo_num|
                "#{prefix}lo:#{col_book_name}:#{chapter_num}-#{section_num}-#{lo_num}"
              end
            end
          end

          output_sheet.add_row [exercise_numbers, cnxmod_tags.join(','), lo_tags.join(',')]
        end
      end
    end
  end

  if package.serialize(output_filename)
    puts "Wrote exercise mapping file #{output_filename}"
  else
    puts "ERROR: Failed to write exercises mapping file #{output_filename}"
  end
end
