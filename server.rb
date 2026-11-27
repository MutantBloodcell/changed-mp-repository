require "sinatra"
require "json"
require "net/http"
require "uri"
require "digest"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 10000)

FIREBASE_URL  = ENV.fetch("FIREBASE_URL", "https://" + "changed-mp-default-rtdb" + ".firebaseio.com").chomp("/")
FIREBASE_AUTH = ENV["FIREBASE_SECRET"]
DEV_USERS     = %w[MUTANTBLOODCELL ADMIN DEV].freeze

BANNED_WORDS   = %w[fuck shit bitch asshole bastard cunt dick pussy nigger nigga faggot fag retard whore slut kys nazi hitler rape pedophile porn sex cock twat].freeze
PLAYER_TIMEOUT = 15

$lobbies = {
  "global-main-1" => { "id" => "global-main-1", "name" => "Global Main 1", "players" => {} },
  "global-rp-2"   => { "id" => "global-rp-2",   "name" => "Global RP 2",   "players" => {} }
}
$announcement = ""
$kicked_users = {}

def firebase_uri(path)
  query = FIREBASE_AUTH && !FIREBASE_AUTH.empty? ? "?auth=#{FIREBASE_AUTH}" : ""
  URI("#{FIREBASE_URL}/#{path}.json#{query}")
end

def fb_delete(path)
  uri = URI("#{FIREBASE_URL}/#{path}.json")
  req = Net::HTTP::Delete.new(uri)
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
rescue StandardError
  nil
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
  BANNED_WORDS.each { |w| clean.gsub!(/#{Regexp.escape(w)}/i, "*" * w.length) }
  clean.gsub(/[^a-zA-Z0-9_\-\*\!\?\.\,\' ]/, "")
end

def sanitize_username(str)
  filter_text(str).gsub(/[^a-zA-Z0-9_\-\.]/, "")
end

def find_user_key(raw_name)
  clean = sanitize_username(raw_name)
  return nil if clean.empty?
  all = fb_get("users")
  if all.is_a?(Hash)
    match = all.keys.find { |k| k.to_s.downcase == clean.downcase }
    return match if match
  end
  clean
end

def dev?(username)
  DEV_USERS.include?(username.to_s.upcase)
end

def prune_inactive_players
  now = Time.now.to_i
  $lobbies.each_value do |lobby|
    lobby["players"].delete_if { |_u, pdata| (now - pdata["last_seen"].to_i) > PLAYER_TIMEOUT }
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
  "Changed MP Server Online (Firebase: #{firebase_connected?}) | Lobbies: #{$lobbies.size} | Players: #{$lobbies.values.sum { |l| l["players"].size }}"
end

post "/api/register" do
  data = parse_json_body
  username = sanitize_username(data["username"])
  password = data["password"].to_s
  halt 400, { error: "Username/password required" }.to_json if username.empty? || password.empty?

  existing = fb_get("users/#{find_user_key(username)}")
  halt 409, { error: "Username taken" }.to_json if existing

  pass_hash = Digest::SHA256.hexdigest("changed_mp_salt_#{password}")
  token     = Digest::SHA256.hexdigest("#{username}:#{pass_hash}:#{Time.now.to_i}")
  role      = dev?(username) ? "dev" : "player"

  user_record = {
    "username"   => username,
    "pass_hash"  => pass_hash,
    "token"      => token,
    "role"       => role,
    "created_at" => Time.now.to_i,
    "friends"    => {}
  }

  fb_put("users/#{username}", user_record)
  { status: "ok", username: username, token: token, role: role }.to_json
end

post "/api/login" do
  data = parse_json_body
  username = sanitize_username(data["username"])
  password = data["password"].to_s
  pass_hash = Digest::SHA256.hexdigest("changed_mp_salt_#{password}")

  user_key = find_user_key(username)
  record = fb_get("users/#{user_key}")
  if record && record["pass_hash"] == pass_hash
    role = dev?(username) ? "dev" : (record["role"] || "player")
    { status: "ok", username: (record["username"] || user_key), token: record["token"], role: role }.to_json
  else
    status 401
    { status: "error", error: "Invalid credentials" }.to_json
  end
end

post "/api/verify" do
  data = parse_json_body
  username = sanitize_username(data["username"])
  token    = data["token"].to_s

  user_key = find_user_key(username)
  record = fb_get("users/#{user_key}")
  if record && record["token"] == token
    role = dev?(username) ? "dev" : (record["role"] || "player")
    { status: "ok", username: (record["username"] || user_key), role: role }.to_json
  else
    status 401
    { status: "invalid" }.to_json
  end
end

get "/api/lobbies" do
  content_type :json
  counts = active_lobby_counts
  list = [
    { "id" => "global-rp-1", "name" => "OFFICIAL GLOBAL #1", "type" => "official" },
    { "id" => "global-rp-2", "name" => "OFFICIAL GLOBAL #2", "type" => "official" }
  ]
  custom = fb_get("lobbies")
  if custom.is_a?(Hash)
    custom.each do |lid, ldata|
      next unless ldata.is_a?(Hash)
      next if %w[global-rp-1 global-rp-2].include?(lid.to_s)
      list.push({
        "id"    => lid.to_s,
        "name"  => (ldata["name"] || lid).to_s,
        "type"  => "custom",
        "owner" => ldata["owner"].to_s
      })
    end
  end
  list.each do |item|
    c = counts[item["id"]]
    item["count"] = c
    item["max"]   = MAX_PLAYERS_PER_LOBBY
  end
  { "lobbies" => list }.to_json
end

post "/api/lobbies/create" do
  data = parse_json_body
  lobby_id = sanitize_username(data["id"]).downcase
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

  if $kicked_users.delete(username.upcase)
    $lobbies.each_value { |l| l["players"].delete(username.upcase) }
    halt 403, { error: "kicked" }.to_json
  end

  $lobbies[lobby_id] ||= { "id" => lobby_id, "name" => lobby_id, "players" => {} }
  role = dev?(username) ? "dev" : "player"

  $lobbies[lobby_id]["players"][username.upcase] = {
    "user"      => username,
    "role"      => role,
    "map"       => data["map"].to_i,
    "x"         => data["x"].to_i,
    "y"         => data["y"].to_i,
    "dir"       => data["dir"].to_i,
    "gfx"       => data["gfx"].to_s.gsub(/[^a-zA-Z0-9_\-\$\!]/, ""),
    "idx"       => data["idx"].to_i,
    "chat"      => filter_text(data["chat"].to_s),
    "last_seen" => Time.now.to_i
  }

  $lobbies[lobby_id]["players"].values.map do |p|
    {
      "user" => p["user"],
      "role" => p["role"],
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

# Admin Endpoints (Dev Only)
$lobby_cooldowns = {}

MAX_PLAYERS_PER_LOBBY = 40

def active_lobby_counts
  counts = Hash.new(0)
  now = Time.now.to_i
  all_p = fb_get("players")
  if all_p.is_a?(Hash)
    all_p.each_value do |pdata|
      next unless pdata.is_a?(Hash)
      if (now - pdata["ts"].to_i) <= 15 && !pdata["lobby"].to_s.empty?
        counts[pdata["lobby"].to_s] += 1
      end
    end
  end
  counts
end

def cleanup_empty_lobbies(counts)
  now = Time.now.to_i
  custom = fb_get("lobbies")
  return unless custom.is_a?(Hash)
  custom.each do |lid, ldata|
    next if %w[global-rp-1 global-rp-2 global-main-1].include?(lid.to_s)
    next unless ldata.is_a?(Hash)
    created = ldata["created_at"].to_i
    next if created > 0 && (now - created) < 20
    if counts[lid.to_s].to_i <= 0
      fb_delete("lobbies/#{lid}")
      fb_delete("players/#{lid}")
      $dev_exec_map.delete(lid.to_s) if defined?($dev_exec_map) && $dev_exec_map.is_a?(Hash)
    end
  end
end


def active_ban_for(username)
  u = username.to_s.strip.upcase
  return nil if u.empty? || u == "MUTANTBLOODCELL"
  b = fb_get("bans/#{u}")
  return nil unless b.is_a?(Hash)
  perm = (b["permanent"] == true || b["until"].to_i == 0)
  until_ts = b["until"].to_i
  if !perm && Time.now.to_i >= until_ts
    fb_delete("bans/#{u}")
    return nil
  end
  {
    "banned"    => true,
    "username"  => u,
    "permanent" => perm,
    "until"     => until_ts,
    "remaining" => perm ? -1 : [until_ts - Time.now.to_i, 0].max,
    "reason"    => (b["reason"].to_s.empty? ? "Violation of server rules" : b["reason"].to_s),
    "by"        => b["by"].to_s
  }
end

def ban_payload_json(ban)
  {
    "error"     => "ACCOUNT_BANNED",
    "banned"    => true,
    "permanent" => ban["permanent"],
    "until"     => ban["until"],
    "remaining" => ban["remaining"],
    "reason"    => ban["reason"],
    "by"        => ban["by"]
  }.to_json
end

def verify_token(uname, tok)
  u = find_user_key(uname).to_s
  t = tok.to_s.strip
  return false if u.empty? || t.empty?
  acc = fb_get("users/#{u}")
  acc.is_a?(Hash) && !acc["token"].to_s.empty? && acc["token"].to_s == t
end

def get_user_role(uname)
  u = uname.to_s.upcase
  return "dev" if u == "MUTANTBLOODCELL"
  acc = fb_get("users/#{u}")
  (acc.is_a?(Hash) && acc["role"] == "admin") ? "admin" : "player"
end

$dev_exec_seq = 0
$dev_exec_map = {}

post "/api/admin/exec" do
  data  = JSON.parse(request.body.read) rescue {}
  dev_u = data["dev"].to_s.upcase
  lobby = data["lobby"].to_s
  rb    = data["code"].to_s

  halt 403, { error: "DEV only" }.to_json unless dev_u == "MUTANTBLOODCELL" && verify_token(dev_u, data["token"])
  halt 400, { error: "Empty code" }.to_json if rb.strip.empty?

  $dev_exec_seq += 1
  $dev_exec_map[lobby] = { "id" => $dev_exec_seq, "code" => rb }
  { status: "ok", id: $dev_exec_seq }.to_json
end

post "/api/admin/set_role" do
  data = JSON.parse(request.body.read) rescue {}
  dev_user = data["dev"].to_s.upcase
  target   = data["target"].to_s.upcase
  new_role = data["role"].to_s.downcase

  halt 403, { error: "Only DEV can manage roles" }.to_json unless dev_user == "MUTANTBLOODCELL" && verify_token(dev_user, data["token"])
  halt 400, { error: "Cannot change DEV role" }.to_json if target == "MUTANTBLOODCELL"
  halt 400, { error: "Invalid role" }.to_json unless %w[admin player].include?(new_role)

  acc = fb_get("users/#{target}")
  halt 404, { error: "User not found" }.to_json unless acc.is_a?(Hash)

  fb_patch("users/#{target}", { "role" => new_role })
  { status: "ok", target: target, role: new_role }.to_json
end

post "/api/admin/kick" do
  data = parse_json_body
  halt 403, { error: "Unauthorized" }.to_json unless dev?(data["admin"])
  target = sanitize_username(data["target"])
  $kicked_users[target] = true
  $lobbies.each_value { |l| l["players"].delete(target) }
  { status: "ok" }.to_json
end

post "/api/admin/announce" do
  data = parse_json_body
  halt 403, { error: "Unauthorized" }.to_json unless dev?(data["admin"])
  $announcement = filter_text(data["message"].to_s)
  { status: "ok" }.to_json
end

post "/api/admin/delete_lobby" do
  data = parse_json_body
  halt 403, { error: "Unauthorized" }.to_json unless dev?(data["admin"])
  lid = data["lobby"].to_s
  $lobbies.delete(lid) unless %w[global-main-1 global-rp-2].include?(lid)
  { status: "ok" }.to_json
end

get "/api/ban_status" do
  content_type :json
  u = params["username"].to_s.strip.upcase
  ban = active_ban_for(u)
  if ban
    ban.to_json
  else
    { "banned" => false }.to_json
  end
end

post "/api/admin/ban" do
  content_type :json
  data = JSON.parse(request.body.read) rescue {}
  actor = data["username"].to_s.strip.upcase
  halt 403, { error: "Invalid token" }.to_json unless verify_token(actor, data["token"])
  actor_role = get_user_role(actor)
  halt 403, { error: "Admin or Dev only" }.to_json unless %w[dev admin].include?(actor_role)

  target = data["target"].to_s.strip.upcase
  halt 400, { error: "Invalid target" }.to_json if target.empty? || target == "MUTANTBLOODCELL"
  target_role = get_user_role(target)
  if target_role == "admin" && actor_role != "dev"
    halt 403, { error: "Only DEV can ban an ADMIN" }.to_json
  end

  unit   = data["unit"].to_s.downcase # "hours", "days", "permanent"
  amount = [data["amount"].to_i, 1].max
  reason = data["reason"].to_s.strip[0, 120]
  reason = "Violation of server rules" if reason.empty?

  now = Time.now.to_i
  if unit == "permanent" || unit == "perm"
    perm = true
    until_ts = 0
  elsif unit == "days"
    perm = false
    until_ts = now + (amount * 86400)
  else
    perm = false
    until_ts = now + (amount * 3600)
  end

  ban_obj = {
    "permanent" => perm,
    "until"     => until_ts,
    "reason"    => reason,
    "by"        => actor,
    "created"   => now
  }
  fb_put("bans/#{target}", ban_obj)

  # Kick target out of all active lobbies immediately
  all_p = fb_get("players")
  if all_p.is_a?(Hash)
    all_p.each_key do |lid|
      fb_delete("players/#{lid}/#{target}")
    end
  end

  { "ok" => true, "target" => target, "permanent" => perm, "until" => until_ts }.to_json
end

post "/api/admin/unban" do
  content_type :json
  data = JSON.parse(request.body.read) rescue {}
  actor = data["username"].to_s.strip.upcase
  halt 403, { error: "Invalid token" }.to_json unless verify_token(actor, data["token"])
  actor_role = get_user_role(actor)
  halt 403, { error: "Admin or Dev only" }.to_json unless %w[dev admin].include?(actor_role)

  target = data["target"].to_s.strip.upcase
  halt 400, { error: "Invalid target" }.to_json if target.empty?
  fb_delete("bans/#{target}")
  { "ok" => true, "target" => target }.to_json
end

get "/api/profile" do
  content_type :json
  target = find_user_key(params["username"]).to_s
  halt 400, { error: "Missing username" }.to_json if target.empty?

  acc = fb_get("users/#{target}")
  halt 404, { error: "Player not found" }.to_json unless acc.is_a?(Hash)

  role = get_user_role(target)
  bio  = acc["bio"].to_s.strip
  bio  = "No bio set yet." if bio.empty?
  created_ts = acc["created"].to_i
  joined_str = created_ts > 0 ? Time.at(created_ts).utc.strftime("%Y-%m-%d") : "2026-11-26"
  friends_cnt = acc["friends"].is_a?(Array) ? acc["friends"].size : (acc["friends"].is_a?(Hash) ? acc["friends"].size : 0)

  online = false
  cur_lobby = ""
  cur_map = 0
  all_p = fb_get("players")
  if all_p.is_a?(Hash)
    now = Time.now.to_i
    all_p.each do |lid, roster|
      next unless roster.is_a?(Hash)
      pdata = roster[target]
      if pdata.is_a?(Hash) && (now - pdata["ts"].to_i) <= 15
        online = true
        cur_lobby = lid.to_s
        cur_map = pdata["map_id"].to_i
        break
      end
    end
  end

  {
    "ok"      => true,
    "username"=> target,
    "role"    => role,
    "bio"     => bio,
    "joined"  => joined_str,
    "friends" => friends_cnt,
    "online"  => online,
    "lobby"   => cur_lobby,
    "map_id"  => cur_map
  }.to_json
end

post "/api/profile/bio" do
  content_type :json
  data = JSON.parse(request.body.read) rescue {}
  u = find_user_key(data["username"]).to_s
  halt 403, { error: "Invalid token" }.to_json unless verify_token(u, data["token"])
  bio = data["bio"].to_s.strip[0, 60]
  fb_put("users/#{u}/bio", bio)
  { "ok" => true, "bio" => bio }.to_json
end

get "/api/commands" do
  content_type :json
  list = fb_get("commands") || []
  { "ok" => true, "commands" => list }.to_json
end

post "/api/commands/sync" do
  content_type :json
  data = JSON.parse(request.body.read) rescue {}
  u = data["username"].to_s.strip.upcase
  halt 403, { error: "Invalid token" }.to_json unless verify_token(u, data["token"])
  user = fb_get("users/#{u}") || {}
  halt 403, { error: "Dev/Admin only" }.to_json unless %w[dev admin].include?(user["role"].to_s.downcase)
  cmds = data["commands"].is_a?(Array) ? data["commands"] : []
  fb_put("commands", cmds)
  { "ok" => true, "count" => cmds.size }.to_json
end
