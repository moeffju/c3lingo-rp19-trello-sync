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

MODE = ARGV.any? { |arg| arg =~ /^--prod/ } ? 'prod' : 'test'
DRY_RUN = ARGV.any? { |arg| arg =~ /^--dry-run|^-n/ }
API = ARGV.any? { |arg| arg =~ /^--api=elfengleich/ } ? 'elfengleich' : 'csa'

if MODE == 'prod'
  BOARD_ID = '5ccc5ac4a9ae524b9d9ad792'
else
  BOARD_ID = '5ccf0c16c3a66923be391671'
end

LINK_BASE = 'https://19.re-publica.com'
SESSIONS_URL = {
  'elfengleich' => 'https://www.elfengleich.de/rp19/sessions19.json',
  'csa' => 'https://api.conference.systems/api/rp19/sessions',
}

STAGE_FILTER = ['Stage 1', 'Stage 2']

SESSION_LANG_MAP = {
  'German' => 'DE',
  'English' => 'EN',
}
LANGUAGE_COLOR_MAP = {
  'German' => 'black',
  'English' => 'sky',
}

RUN = Time.now.iso8601[11..18]
UTC = Time.find_zone('UTC')

log "Run started: #{RUN}"
log "TEST MODE, using test board; pass `--prod` if you mean it" if MODE != 'prod'
log "DRY RUN, not creating or updating cards" if DRY_RUN

def parse_sessions_csa(sessions)
  sessions['data'].filter do |session|
    session['track'] && session['lang'] && session['location'] && session['day'] && session['begin'] && session['end']
  end.map do |session|
    res = {
      id: session['id'],
      title: session['title'],
      abstract: session['abstract'],
      url: session['url'],
      description: session['description'],
      track: session['track']['label_en'],
      lang: session['lang']['label_en'],
      location: session['location']['label_en'],
      speakers: session['speakers'].map{ |x| x['name'] },
      status: session['cancelled'] ? 'cancelled' : 'scheduled',
      day: session['day']['date'],
      begin: UTC.parse(session['begin']),
      end: UTC.parse(session['end']),
    }
    res
  end
end

def parse_sessions_elfengleich(sessions)
  sessions.map do |session|
    session['title'] =~ /href="([^"]+)"/
    session_link = LINK_BASE + $1
    session_speakers_list = CGI.unescapeHTML(session['speaker']).split(/,\s*/)
    res = {
      id: session['nid'],
      title: CGI.unescapeHTML(session['title_text']),
      abstract: session['short_thesis'],
      url: session_link,
      description: convert_to_text(session['description']),
      track: CGI.unescapeHTML(session['track']),
      lang: session['language'],
      location: session['room'],
      speakers: session_speakers_list,
      status: session['status'] == 'Cancelled' ? 'cancelled' : 'scheduled',
      day: session['datetime_start'][0..9],
      begin: UTC.parse(session['datetime_start']),
      end: UTC.parse(session['datetime_end']),
    }
    res
  end
end

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
log "Getting sessions from #{API} api: #{SESSIONS_URL[API]}"
req = HTTParty.get(SESSIONS_URL[API]); nil
log "Parsing sessions"
sessions = req.parsed_response; nil
sessions = send("parse_sessions_#{API}".to_sym, sessions); nil
conference_dates = sessions.filter{ |x| STAGE_FILTER.include?(x[:location]) }.collect{ |x| x[:day] }.uniq.sort
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

log "Getting cards"
cards = board.cards(filter: :open)
cards_map = {}
cards.each do |card|
  next unless card.name =~ /\(#(\d+)\)$/
  talk_id = $1
  cards_map[talk_id] = card
end

# x['live_translation'] == 'Yes' && 
translated_sessions = sessions.filter{ |x| STAGE_FILTER.include?(x[:location]) }

count_new = 0
count_updated = 0
log "Syncing sessions…"
translated_sessions.each do |session|
  session_speakers = case session[:speakers].size
    when 0..3 then session[:speakers].join(', ')
    when 4..8 then session[:speakers].map{ |name| name.split(/\s+/)[-1] }.join(', ')
    else "#{session[:speakers].size} speakers"
  end
  session_list = day_lists[session[:day]]
  
  data = {}
  data[:name] = "[#{session[:begin].localtime.strftime('%H:%M')}–#{session[:end].localtime.strftime('%H:%M')}] #{session[:location]}: #{session[:title]} (#{session_speakers}) (#{SESSION_LANG_MAP[session[:lang]]}) (\##{session[:id]})"
  if session[:status] == 'cancelled'
    data[:name] = 'CANCELLED: ' + data[:name]
  end
  data[:desc] = <<-_EOF_
  **[#{session[:title]}](#{session[:url]})**

  *#{session[:lang]}, #{session[:location]} @ #{session[:day]}, #{session[:begin].localtime.strftime('%H:%M')}–#{session[:end].localtime.strftime('%H:%M')}*
  #{session[:location]}

  **Speakers**
  #{session[:speakers].join(', ')}

  **Summary**
  #{session[:abstract]}

  #{session[:description]}

  ----

  *Last synced: #{RUN}*
  _EOF_
  data[:due] = session[:begin].iso8601

  if cards_map.has_key? session[:id]
    card = cards_map[session[:id]]
    # update_fields did not work for some reason, but this does
    data.each { |k,v| card.send(k.to_s+'=', v) }
    unless DRY_RUN
      card.update!
      card.move_to_list session_list
      log "Existing: #{card.name}"
    else
      log "DRY RUN: Not updating: #{data[:name]}"
    end
    count_updated += 1
  else
    unless DRY_RUN
      card = Trello::Card.create(list_id: backlog.id, **data, list_id: session_list.id)
      log "Added: #{card.name}"
    else
      log "DRY RUN: Not adding: #{data[:name]}"
    end
    count_new += 1
  end
  unless DRY_RUN
    card.add_label language_labels[session[:lang]] unless card.labels.include? language_labels[session[:lang]]
    card.save
  end
end

log "Done - #{count_new} new and #{count_updated} existing!"
