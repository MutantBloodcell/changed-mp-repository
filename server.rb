require "sinatra"
require "json"
require "net/http"
require "uri"
require "digest"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 10000)

FIREBASE_URL  = ENV.fetch("FIREBASE_URL", "https://firebaseio.com").chomp("/")
FIREBASE_AUTH = ENV["FIREBASE_SECRET"]

BANNED_WORDS   = %w[badword1 badword2 slur1].freeze
PLAYER_TIMEOUT = 15

$lobbies = {
  "global-main-1" => { "id" => "global-main-1", "name" => "Global Main 1", "players" => {} },
  "global-rp-2"   => { "id" => "global-rp-2",   "name" => "Global RP 2",   "players" => {} }
}

def firebase_uri(path)
  query = FIREBASE_AUTH && !FIREBASE_AUTH.empty? ? "?auth=#{FIREBASE_AUTH}" : ""
  URI("#{FIREBASE_URL}/#{path}.json#{query}")
end

def fb_get(path)
  res = Net::HTTP.get_response(firebase_uri(path))
  return nil unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)
rescue
  nil
end

def fb_put(path, data)
  uri = firebase_uri(path)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Put.new(uri)
  req["Content-Type"] = "application/json"
  req.body = data.to_json
  res = http.request(req)
  res.is_a?(Net::HTTPSuccess)
rescue
  false
end

def firebase_connected?
  res = Net::HTTP.get_response(firebase_uri("server_health"))
  res.is_a?(Net::HTTPSuccess)
rescue
  false
end

def filter_text(str)
  clean = str.to_s.dup
  BANNED_WORDS.each do |word|
    clean.gsub!(/#{Regexp.escape(word)}/i, "*" * word.length)
  end
  clean.gsub(/[^a-zA-Z0-9_\-\*\!\?\.\,\' ]/, "")
end

def sanitize_username(str)
  filter_text(str).gsub(/[^a-zA-Z0-9_\-]/, "")[0, 16]
end

def prune_inactive_players
  now = Time.now.to_i
  $lobbies.each_value do |lobby|
    lobby["players"].delete_if { |_user, pdata| (now - pdata["last_seen"].to_i) > PLAYER_TIMEOUT }
  end
end

def parse_json_body
  request.body.rewind
  raw = request.body.read
  raw.empty? ? {} : JSON.parse(raw)
rescue
  {}
end

before do
  content_type :json unless request.path_info == "/"
end

get "/" do
  content_type :text
  prune_inactive_players
  fb_ok = firebase_connected?
  total_lobbies = $lobbies.size
  total_players = $lobbies.values.sum { |l| l["players"].size }
  "Changed MP Server Online (Firebase: #{fb_ok}) | Lobbies: #{total_lobbies} | Players: #{total_players}"
end

post "/api/register" do
  data = parse_json_body
  username = sanitize_username(data["username"])
  password = data["password"].to_s
  halt 400, { error: "Username/password required" }.to_json if username.empty? || password.empty?

  existing = fb_get("users/#{username}")
  halt 409, { error: "Username taken" }.to_json if existing

  pass_hash = Digest::SHA256.hexdigest("changed_mp_salt_#{password}")
  token     = Digest::SHA256.hexdigest("#{username}:#{pass_hash}:#{Time.now.to_i}")

  user_record = {
    "username"   => username,
    "pass_hash"  => pass_hash,
    "token"      => token,
    "created_at" => Time.now.to_i,
    "friends"    => {}
  }

  fb_put("users/#{username}", user_record)
  { status: "ok", username: username, token: token }.to_json
end

post "/api/login" do
  data = parse_json_body
  username = sanitize_username(data["username"])
  password = data["password"].to_s
  pass_hash = Digest::SHA256.hexdigest("changed_mp_salt_#{password}")

  record = fb_get("users/#{username}")
  if record && record["pass_hash"] == pass_hash
    { status: "ok", username: username, token: record["token"] }.to_json
  else
    status 401
    { status: "error", error: "Invalid credentials" }.to_json
  end
end

post "/api/verify" do
  data = parse_json_body
  username = sanitize_username(data["username"])
  token    = data["token"].to_s

  record = fb_get("users/#{username}")
  if record && record["token"] == token
    { status: "ok", username: username }.to_json
  else
    status 401
    { status: "invalid" }.to_json
  end
end

get "/api/lobbies" do
  prune_inactive_players
  list = $lobbies.values.map do |l|
    { "id" => l["id"], "name" => l["name"], "count" => l["players"].size }
  end
  { "lobbies" => list }.to_json
end

post "/api/lobbies/create" do
  data = parse_json_body
  lobby_id = sanitize_username(data["id"])
  lobby_id = "lobby-#{rand(1000..9999)}" if lobby_id.empty?

  $lobbies[lobby_id] ||= { "id" => lobby_id, "name" => lobby_id, "players" => {} }
  fb_put("lobbies/#{lobby_id}", { "id" => lobby_id, "created_at" => Time.now.to_i })
  { status: "ok", id: lobby_id }.to_json
end

post "/api/sync" do
  prune_inactive_players
  data = parse_json_body

  lobby_id = data["lobby"].to_s
  username = sanitize_username(data["user"])
  halt 400, { error: "Missing fields" }.to_json if lobby_id.empty? || username.empty?

  $lobbies[lobby_id] ||= { "id" => lobby_id, "name" => lobby_id, "players" => {} }

  $lobbies[lobby_id]["players"][username] = {
    "user"      => username,
    "map"       => data["map"].to_i,
    "x"         => data["x"].to_i,
    "y"         => data["y"].to_i,
    "dir"       => data["dir"].to_i,
    "gfx"       => data["gfx"].to_s.gsub(/[^a-zA-Z0-9_\-\$\!]/, ""),
    "idx"       => data["idx"].to_i,
    "chat"      => filter_text(data["chat"].to_s)[0, 48],
    "last_seen" => Time.now.to_i
  }

  $lobbies[lobby_id]["players"].values.map do |p|
    {
      "user" => p["user"],
      "map"  => p["map"],
      "x"    => p["x"],
      "y"    => p["y"],
      "dir"  => p["dir"],
      "gfx"  => p["gfx"],
      "idx"  => p["idx"],
      "chat" => p["chat"]
    }
  end.to_json
end

post "/api/friends/add" do
  data   = parse_json_body
  user   = sanitize_username(data["user"])
  friend = sanitize_username(data["friend"])
  halt 400, { error: "Invalid names" }.to_json if user.empty? || friend.empty?

  fb_put("users/#{user}/friends/#{friend}", true)
  { status: "ok", friend: friend }.to_json
end
