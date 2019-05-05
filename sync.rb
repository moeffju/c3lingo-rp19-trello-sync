#!/usr/bin/env ruby
# encoding: utf-8

require 'rubygems'
require 'bundler/setup'

require 'trello'
require 'active_support/time'
require 'httparty'
require 'toml-rb'

def log(s)
  STDERR.puts "[#{Time.now.iso8601[11..18]}] #{s}"
end

config = TomlRB.load_file('./config.toml', symbolize_keys: true)

Trello.configure do |setting|
  setting.developer_public_key = config[:trello][:developer_key]
  setting.member_token = config[:trello][:member_token]
end

MODE = ARGV.any? { |arg| arg =~ /--prod/ } ? 'prod' : 'test'
DRY_RUN = ARGV.any? { |arg| arg =~ /--dry-run|-n/ }

if MODE == 'prod'
  BOARD_ID = '5ccc5ac4a9ae524b9d9ad792'
else
  BOARD_ID = '5ccf0c16c3a66923be391671'
end

LINK_BASE = 'https://19.re-publica.com'
SESSIONS_URL = 'https://www.elfengleich.de/rp19/sessions19.json'

STAGE_FILTER = ['Stage 1', 'Stage 2']

SESSION_LANG_MAP = {
  'German' => 'DE',
  'English' => 'EN',
}
LANGUAGE_COLOR_MAP = {
  'German' => 'black',
  'English' => 'sky',
}
FORMAT_COLOR_MAP = {
  'Talk' => 'null',
  'Discussion' => 'null',
}

RUN = Time.now.iso8601[11..18]
UTC = Time.find_zone('UTC')

log "Run started: #{RUN}"
log "TEST MODE, using test board; pass `--prod` if you mean it" if MODE != 'prod'
log "DRY RUN, not creating or updating cards" if DRY_RUN

def convert_to_text(html, line_length = 65, from_charset = 'UTF-8')
  txt = html
  txt.gsub!(/<img.+?alt=\"([^\"]*)\"[^>]*\>/i, '\1')
  txt.gsub!(/<img.+?alt=\'([^\']*)\'[^>]*\>/i, '\1')
  txt.gsub!(/<a\s.*?href=["'](mailto:)?([^"']*)["'][^>]*>((.|\s)*?)<\/a>/i) do |s|
    if $3.empty?
      ''
    else
      $3.strip + ' ( ' + $2.strip + ' )'
    end
  end
  txt.gsub!(/(<\/h[1-6]>)/i, "\n\\1") # move closing tags to new lines
  txt.gsub!(/[\s]*<h([1-6]+)[^>]*>[\s]*(.*)[\s]*<\/h[1-6]+>/i) do |s|
    hlevel = $1.to_i
    htext = $2
    htext.gsub!(/<br[\s]*\/?>/i, "\n") # handle <br>s
    htext.gsub!(/<\/?[^>]*>/i, '') # strip tags
    hlength = 0
    htext.each_line { |l| llength = l.strip.length; hlength = llength if llength > hlength }
    hlength = line_length if hlength > line_length
    case hlevel
      when 1   # H1, asterisks above and below
        htext = ('*' * hlength) + "\n" + htext + "\n" + ('*' * hlength)
      when 2   # H1, dashes above and below
        htext = ('-' * hlength) + "\n" + htext + "\n" + ('-' * hlength)
      else     # H3-H6, dashes below
        htext = htext + "\n" + ('-' * hlength)
    end
    "\n\n" + htext + "\n\n"
  end
  txt.gsub!(/(<\/span>)[\s]+(<span)/mi, '\1 \2')
  txt.gsub!(/[\s]*(<li[^>]*>)[\s]*/i, '* ')
  txt.gsub!(/<\/li>[\s]*(?![\n])/i, "\n")
  txt.gsub!(/<\/p>/i, "\n\n")
  txt.gsub!(/<br[\/ ]*>/i, "\n")
  txt.gsub!(/<\/?[^>]*>/, '')
  txt = CGI.unescapeHTML(txt)
  txt.gsub!(/ {2,}/, " ")
  txt.gsub!(/\r\n?/, "\n")
  txt.gsub!(/[ \t]*\302\240+[ \t]*/, " ") # non-breaking spaces -> spaces
  txt.gsub!(/\n[ \t]+/, "\n") # space at start of lines
  txt.gsub!(/[ \t]+\n/, "\n") # space at end of lines
  txt.gsub!(/[\n]{3,}/, "\n\n")
  txt.gsub!(/\(([ \n])(http[^)]+)([\n ])\)/) do |s|
    ($1 == "\n" ? $1 : '' ) + '( ' + $2 + ' )' + ($3 == "\n" ? $1 : '' )
  end
  txt.strip
end

# get rp sessions
log "Getting sessions from #{SESSIONS_URL}"
req = HTTParty.get(SESSIONS_URL); nil
log "Parsing sessions"
sessions = req.parsed_response; nil
conference_dates = sessions.filter{ |x| x['live_translation'] == 'Yes' }.collect{ |x| x['datetime_start'][0..9] }.uniq
log "Conference dates: #{conference_dates.join(', ')}"

# prepare the Trello board
log "Preparing Trello board"
board = Trello::Board.find(BOARD_ID)

lists = board.lists
log "Lists found: [#{lists.map(&:name).join(', ')}]"
backlog = lists.select{ |l| l.name == 'Backlog' }.first || Trello::List.create(board_id: board.id, name: 'Backlog')
day_lists = {}
conference_dates.each_with_index do |date, i|
  list_name = "#{date} (Day #{i+1})"
  day_lists[date] = lists.select{ |l| l.name == list_name }.first || Trello::List.create(board_id: board.id, name: list_name)
  log "Day list for #{date}: #{day_lists[date].name}"
end
log "Created backlog and day lists"

labels = board.labels
log "Setting up labels"
language_labels = {}
unless DRY_RUN
  LANGUAGE_COLOR_MAP.keys.each do |lang|
    language_labels[lang] = labels.select{ |l| l.name == lang }.first || Trello::Label.create(board_id: board.id, name: lang, color: LANGUAGE_COLOR_MAP[lang])
  end
  log "Language labels: [#{language_labels.map{ |k,v| "#{v.name} (#{v.color})" }.join(', ')}]"
end
format_labels = {}
unless DRY_RUN
  FORMAT_COLOR_MAP.keys.each do |fmt|
    format_labels[fmt] = labels.select{ |l| l.name == fmt }.first || Trello::Label.create(board_id: board.id, name: fmt, color: FORMAT_COLOR_MAP[fmt])
    format_labels[fmt].color = FORMAT_COLOR_MAP[fmt]
  end
  log "Format labels: [#{format_labels.map{ |k,v| "#{v.name} (#{v.color})" }.join(', ')}]"
end

log "Getting cards"
cards = board.cards(filter: :open)
cards_map = {}
cards.each do |card|
  next unless card.name =~ /\(#(\d+)\)$/
  talk_id = $1
  cards_map[talk_id] = card
end

translated_sessions = sessions.filter{ |x| x['live_translation'] == 'Yes' && STAGE_FILTER.include?(x['room']) }

log "Syncing sessions…"
translated_sessions.each do |session|
  session['title'] =~ /href="([^"]+)"/
  session_link = LINK_BASE + $1
  session_title = CGI.unescapeHTML(session['title_text'])
  session_start = UTC.parse(session['datetime_start'])
  session_end = UTC.parse(session['datetime_end'])

  session_start_date = session_start.localtime.iso8601[0..9]
  session_start_time = session_start.localtime.iso8601[11..15]
  session_end_time = session_end.localtime.iso8601[11..15]
  session_speakers_list = CGI.unescapeHTML(session['speaker']).split(/,\s*/)
  session_speakers = case session_speakers_list.size
    when 0..3 then session_speakers_list.join(', ')
    when 4..8 then session_speakers_list.map{ |name| name.split(/\s+/)[-1] }.join(', ')
    else "#{session_speakers_list.size} speakers"
  end
  session_list = day_lists[session_start_date]

  data = {}
  data[:name] = "[#{session_start_time}–#{session_end_time}] #{session['room']}: #{session_title} (#{session_speakers}) (#{SESSION_LANG_MAP[session['language']]}) (\##{session['nid']})"
  if session['status'] == 'Cancelled'
    data[:name] = 'CANCELLED: ' + data[:name]
  end
  data[:desc] = <<-_EOF_
  **[#{session_title}](#{session_link})**

  *#{session['language']} #{session['format']}, #{session['room']} @ #{session_start_date}, #{session_start_time}–#{session_end_time}*
  #{CGI.unescapeHTML(session['track'])}, #{session['experience']}

  **Speakers**
  #{CGI.unescapeHTML(session['speaker'])}

  **Summary**
  #{CGI.unescapeHTML(session['short_thesis'])}

  #{convert_to_text(session['description'])}

  ----

  *Last updated: #{session['changed']} / #{RUN}*
  _EOF_
  data[:due] = session_start.iso8601

  if cards_map.has_key? session['nid']
    card = cards_map[session['nid']]
    # update_fields did not work for some reason, but this does
    data.each { |k,v| card.send(k.to_s+'=', v) }
    card.update! unless DRY_RUN
    card.move_to_list session_list unless DRY_RUN
    log "Card (updated): #{card.name}"
  else
    unless DRY_RUN
      card = Trello::Card.create(list_id: backlog.id, **data, list_id: session_list.id)
      log "Card (new): #{card.name}"
    else
      log "DRY RUN: Not saving Card (new): #{data[:name]}"
    end
  end
  unless DRY_RUN
    card.add_label format_labels[session['format']] rescue nil
    card.add_label language_labels[session['language']] rescue nil
    card.save
  else
    log "DRY RUN: Not saving card changes"
  end
end

log "Done!"
