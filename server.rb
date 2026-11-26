require "json"
require "digest"
require "net/http"
require "uri"
require "puma"

FB_URL = ENV["FIREBASE_URL"].to_s.sub(/\/+\z/, "")
ACCOUNTS_FILE = "accounts.json"
BANS_FILE     = "bans.json"
FRIENDS_FILE  = "friends.json"
PROGRESS_FILE = "progress.json"

$accounts = File.exist?(ACCOUNTS_FILE) ? (JSON.parse(File.read(ACCOUNTS_FILE)) rescue {}) : {}
$bans     = File.exist?(BANS_FILE)     ? (JSON.parse(File.read(BANS_FILE))     rescue {}) : {}
$friends  = File.exist?(FRIENDS_FILE)  ? (JSON.parse(File.read(FRIENDS_FILE))  rescue {}) : {}
$progress = File.exist?(PROGRESS_FILE) ? (JSON.parse(File.read(PROGRESS_FILE)) rescue {}) : {}
$sessions = {}
$lobbies  = {}

BAD_WORDS = /\b(fuck|shit|bitch|cunt|nigger|nigga|faggot|retard|kys|kill yourself)\b/i

def fb_req(method, path, body = nil)
  return nil if FB_URL.empty?
  uri = URI.parse("#{FB_URL}/#{path}.json")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = case method
        when :get    then Net::HTTP::Get.new(uri.request_uri)
        when :put    then Net::HTTP::Put.new(uri.request_uri)
        when :delete then Net::HTTP::Delete.new(uri.request_uri)
        end
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  JSON.parse(http.request(req).body) rescue nil
rescue
  nil
end

def get_account(u)
  return nil if u.to_s.empty?
  if !FB_URL.empty?
    res = fb_req(:get, "accounts/#{URI.encode_www_form_component(u)}")
    return res if res.is_a?(Hash)
  end
  $accounts[u]
end

def put_account(u, data)
  $accounts[u] = data
  File.write(ACCOUNTS_FILE, JSON.pretty_generate($accounts)) rescue nil
  fb_req(:put, "accounts/#{URI.encode_www_form_component(u)}", data) unless FB_URL.empty?
end

def is_admin_user?(u)
  return false if u.to_s.empty?
  return true if u.to_s.downcase == "admin"
  acc = get_account(u)
  acc.is_a?(Hash) && acc["admin"] == true
end

def sanitize_badge(user, badge)
  b = badge.to_s.upcase
  adm = is_admin_user?(user)
  return b if adm && (b == "DEV" || b == "ADMIN")
  return "PLAYER" if !adm && (b == "DEV" || b == "ADMIN")
  %w[PLAYER HOST VIP PURO SURVIVOR LATEX NEWBIE].include?(b) ? b : (adm ? "ADMIN" : "PLAYER")
end

def format_remaining(s)
  return "0m" if s <= 0
  d = s / 86400; h = (s % 86400) / 3600; m = (s % 3600) / 60
  return "#{d}d #{h}h" if d > 0
  return "#{h}h #{m}m" if h > 0
  "#{[m, 1].max}m"
end

def check_ban(u)
  return nil if u.to_s.empty? || u.to_s.downcase == "admin"
  key = u.to_s.downcase
  b = !FB_URL.empty? ? fb_req(:get, "bans/#{URI.encode_www_form_component(key)}") : $bans[key]
  b = $bans[key] unless b.is_a?(Hash)
  return nil unless b.is_a?(Hash)
  exp = b["until"].to_i
  if exp > 0 && Time.now.to_i >= exp
    $bans.delete(key)
    File.write(BANS_FILE, JSON.pretty_generate($bans)) rescue nil
    fb_req(:delete, "bans/#{URI.encode_www_form_component(key)}") unless FB_URL.empty?
    return nil
  end
  rem = exp == 0 ? "PERMANENT" : format_remaining(exp - Time.now.to_i)
  { "reason" => (b["reason"] || "Rule violation"), "by" => (b["by"] || "Admin"), "remaining" => rem, "until" => exp }
end

def apply_ban(target_u, sec, reason, by_u)
  return if target_u.to_s.empty? || target_u.to_s.downcase == "admin"
  key = target_u.to_s.downcase
  exp = sec.to_i <= 0 ? 0 : (Time.now.to_i + sec.to_i)
  rec = { "user" => target_u, "until" => exp, "reason" => reason.to_s, "by" => by_u.to_s }
  $bans[key] = rec
  File.write(BANS_FILE, JSON.pretty_generate($bans)) rescue nil
  fb_req(:put, "bans/#{URI.encode_www_form_component(key)}", rec) unless FB_URL.empty?
  rec
end
def save_progress(u, prog)
  return if u.to_s.empty?
  $progress[u] = prog
  File.write(PROGRESS_FILE, JSON.pretty_generate($progress)) rescue nil
  fb_req(:put, "progress/#{URI.encode_www_form_component(u)}", prog) unless FB_URL.empty?
end

def load_progress(u)
  return nil if u.to_s.empty?
  if !FB_URL.empty?
    res = fb_req(:get, "progress/#{URI.encode_www_form_component(u)}")
    return res if res.is_a?(Hash)
  end
  $progress[u]
end

def get_friends(u)
  key = URI.encode_www_form_component(u.to_s)
  data = !FB_URL.empty? ? fb_req(:get, "friends/#{key}") : $friends[u]
  data = $friends[u] unless data.is_a?(Hash)
  data.is_a?(Hash) ? data : { "list" => [], "reqs" => [] }
end

def put_friends(u, data)
  $friends[u] = data
  File.write(FRIENDS_FILE, JSON.pretty_generate($friends)) rescue nil
  fb_req(:put, "friends/#{URI.encode_www_form_component(u.to_s)}", data) unless FB_URL.empty?
end

def clean_chat(txt)
  txt.to_s.gsub(/[\r\n\t]+/, " ").strip[0, 80].to_s.gsub(BAD_WORDS) { |m| "*" * m.size }
end

def prune_stale!
  now = Time.now.to_i
  $sessions.each do |sid, st|
    if now - st[:seen].to_i > 25
      leave_lobby(sid)
      $sessions.delete(sid)
    end
  end
  $lobbies.delete_if { |_id, lb| lb[:members].empty? || !$sessions[lb[:host_sid]] }
end

def leave_lobby(sid)
  st = $sessions[sid]
  return unless st && st[:lobby]
  lb = $lobbies[st[:lobby]]
  if lb
    lb[:members].delete(sid)
    if lb[:host_sid] == sid || lb[:members].empty?
      lb[:members].each { |msid| $sessions[msid][:lobby] = nil if $sessions[msid] }
      $lobbies.delete(lb[:id])
    else
      lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "p_leave", u: st[:user] } if $sessions[msid] }
    end
  end
  st[:lobby] = nil
end

def lobby_list_payload
  prune_stale!
  $lobbies.values.map do |l|
    { id: l[:id], name: l[:name], mode: l[:mode], count: l[:members].size, max: l[:max] }
  end
end
App = lambda do |env|
  if env["PATH_INFO"] == "/api" && env["REQUEST_METHOD"] == "POST"
    data = JSON.parse(env["rack.input"].read) rescue {}
    sid = data["sid"] || "S#{rand(100000..999999)}"
    st = ($sessions[sid] ||= { user: nil, lobby: nil, map: 1, x: 10, y: 10, dir: 2, spr: "", idx: 0, badge: "PLAYER", seen: Time.now.to_i, last_chat: 0, inbox: [] })
    st[:seen] = Time.now.to_i
    reply = { sid: sid }

    case data["t"]
    when "register"
      u = data["u"].to_s.strip; p = data["p"].to_s
      if (ban = check_ban(u))
        reply = { sid: sid, t: "banned", ban: ban }
      elsif u.empty? || p.empty?
        reply = { sid: sid, t: "auth_err", msg: "Username/password required" }
      elsif u =~ BAD_WORDS
        reply = { sid: sid, t: "auth_err", msg: "Username blocked by filter" }
      elsif get_account(u)
        reply = { sid: sid, t: "auth_err", msg: "Username already taken" }
      else
        b = (u.downcase == "admin" ? "DEV" : "NEWBIE")
        put_account(u, { "hash" => Digest::SHA256.hexdigest(p), "badge" => b, "admin" => (u.downcase == "admin") })
        st[:user] = u; st[:badge] = b
        reply = { sid: sid, t: "auth_ok", user: u, badge: st[:badge], is_admin: is_admin_user?(u), lobbies: lobby_list_payload }
      end
    when "login"
      u = data["u"].to_s.strip; p = data["p"].to_s; acc = get_account(u)
      if (ban = check_ban(u))
        reply = { sid: sid, t: "banned", ban: ban }
      elsif acc && acc["hash"] == Digest::SHA256.hexdigest(p)
        st[:user] = u; st[:badge] = sanitize_badge(u, acc["badge"])
        reply = { sid: sid, t: "auth_ok", user: u, badge: st[:badge], is_admin: is_admin_user?(u), progress: load_progress(u), lobbies: lobby_list_payload }
      else
        reply = { sid: sid, t: "auth_err", msg: "Invalid login" }
      end
    when "save_progress"
      if st[:user]
        save_progress(st[:user], { "map" => data["m"], "x" => data["x"], "y" => data["y"], "d" => data["d"], "skin" => data["s"], "badge" => st[:badge], "switches" => data["sw"], "variables" => data["vars"], "items" => data["items"], "saved_at" => Time.now.to_i })
        reply = { sid: sid, t: "prog_saved" }
      end
    when "lobbies"
      reply = { sid: sid, t: "lobby_list", lobbies: lobby_list_payload }
    when "create_lobby"
      leave_lobby(sid)
      lid = "L#{rand(1000..9999)}"
      st[:badge] = sanitize_badge(st[:user], is_admin_user?(st[:user]) ? st[:badge] : "HOST")
      rname = clean_chat(data["name"].to_s)
      $lobbies[lid] = { id: lid, name: rname.empty? ? "#{st[:user]}'s Room" : rname, mode: data["mode"] || "Co-Op Story", host: st[:user], host_sid: sid, max: 8, members: [sid], switches: {}, scores: Hash.new(0) }
      st[:lobby] = lid
      reply = { sid: sid, t: "joined_lobby", lobby: $lobbies[lid].slice(:id, :name, :mode, :host) }
    when "join_lobby"
      leave_lobby(sid)
      lb = $lobbies[data["id"]]
      if lb
        lb[:members] << sid unless lb[:members].include?(sid)
        st[:lobby] = lb[:id]
        reply = { sid: sid, t: "joined_lobby", lobby: lb.slice(:id, :name, :mode, :host), switches: lb[:switches] }
        lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[SYSTEM]", msg: "#{st[:user]} joined the room." } if $sessions[msid] }
      else
        reply = { sid: sid, t: "lobby_err", msg: "Lobby closed or not found" }
      end
    when "leave_lobby"
      leave_lobby(sid)
      reply = { sid: sid, t: "lobby_list", lobbies: lobby_list_payload }
    when "kick"
      lb = $lobbies[st[:lobby]]
      if lb && (is_admin_user?(st[:user]) || lb[:host_sid] == sid)
        tgt = data["target"].to_s
        tsid = lb[:members].find { |msid| $sessions[msid] && $sessions[msid][:user] == tgt && msid != sid }
        if tsid
          $sessions[tsid][:inbox] << { t: "kicked", by: st[:user] }
          leave_lobby(tsid)
          lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[SYSTEM]", msg: "#{tgt} was kicked by #{st[:user]}." } if $sessions[msid] }
        end
      end
    when "ban"
      if is_admin_user?(st[:user])
        tgt = data["target"].to_s
        apply_ban(tgt, data["sec"].to_i, data["reason"].to_s.empty? ? "Banned by #{st[:user]}" : data["reason"].to_s, st[:user])
        binfo = check_ban(tgt)
        $sessions.each do |msid, mst|
          if mst[:user].to_s.downcase == tgt.downcase
            mst[:inbox] << { t: "banned", ban: binfo }
            leave_lobby(msid)
          end
        end
        lb = $lobbies[st[:lobby]]
        lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[SYSTEM]", msg: "#{tgt} was BANNED (#{binfo['remaining']}) by #{st[:user]}!" } if $sessions[msid] } if lb
      end
    when "promote"
      if st[:user].to_s.downcase == "admin"
        tgt = data["target"].to_s; acc = get_account(tgt)
        if acc
          acc["admin"] = true; acc["badge"] = "ADMIN"; put_account(tgt, acc)
          $sessions.each_value { |mst| (mst[:badge] = "ADMIN"; mst[:inbox] << { t: "promoted", admin: true, badge: "ADMIN" }) if mst[:user].to_s.downcase == tgt.downcase }
          lb = $lobbies[st[:lobby]]
          lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[SYSTEM]", msg: "#{tgt} was PROMOTED to Admin!" } if $sessions[msid] } if lb
        end
      end
    when "demote"
      if st[:user].to_s.downcase == "admin"
        tgt = data["target"].to_s; acc = get_account(tgt)
        if acc && tgt.downcase != "admin"
          acc["admin"] = false; acc["badge"] = "PLAYER"; put_account(tgt, acc)
          $sessions.each_value { |mst| (mst[:badge] = "PLAYER"; mst[:inbox] << { t: "promoted", admin: false, badge: "PLAYER" }) if mst[:user].to_s.downcase == tgt.downcase }
          lb = $lobbies[st[:lobby]]
          lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[SYSTEM]", msg: "#{tgt} was demoted from Admin." } if $sessions[msid] } if lb
        end
      end
    when "announce"
      if is_admin_user?(st[:user])
        msg = clean_chat(data["msg"])
        $sessions.each_value { |mst| mst[:inbox] << { t: "announce", user: st[:user], msg: msg } } unless msg.empty?
      end
    when "server_info"
      prune_stale!
      reply = { sid: sid, t: "server_info", players: $sessions.size, lobbies: $lobbies.size, accounts: $accounts.size, bans: $bans.size, firebase: !FB_URL.empty? }
    when "friend_add"
      tgt = data["target"].to_s.strip
      if st[:user] && !tgt.empty? && tgt.downcase != st[:user].downcase && get_account(tgt)
        tf = get_friends(tgt); tf["reqs"] ||= []; tf["list"] ||= []
        if !tf["list"].include?(st[:user]) && !tf["reqs"].include?(st[:user])
          tf["reqs"] << st[:user]; put_friends(tgt, tf)
          $sessions.each_value { |mst| mst[:inbox] << { t: "chat", user: "[FRIEND]", msg: "#{st[:user]} sent you a friend request!" } if mst[:user].to_s.downcase == tgt.downcase }
        end
        reply = { sid: sid, t: "friend_ok", msg: "Request sent to #{tgt}" }
      else
        reply = { sid: sid, t: "friend_err", msg: "Player not found" }
      end
    when "friend_accept"
      from_u = data["target"].to_s.strip
      if st[:user] && !from_u.empty?
        mf = get_friends(st[:user]); tf = get_friends(from_u)
        mf["reqs"] ||= []; mf["list"] ||= []; tf["list"] ||= []
        mf["reqs"].delete(from_u)
        mf["list"] << from_u unless mf["list"].include?(from_u)
        tf["list"] << st[:user] unless tf["list"].include?(st[:user])
        put_friends(st[:user], mf); put_friends(from_u, tf)
        reply = { sid: sid, t: "friend_ok", msg: "You and #{from_u} are now friends!" }
      end
    when "friends_list"
      if st[:user]
        mf = get_friends(st[:user])
        online_map = {}
        $sessions.each_value { |mst| online_map[mst[:user]] = mst[:lobby] if mst[:user] }
        flist = (mf["list"] || []).map { |fu| { "u" => fu, "online" => online_map.key?(fu), "lobby" => online_map[fu] } }
        reply = { sid: sid, t: "friends_data", friends: flist, reqs: (mf["reqs"] || []) }
      end
    when "pvp_tag"
      lb = $lobbies[st[:lobby]]
      if lb && lb[:mode] == "PvP Tag"
        tgt = data["target"].to_s
        tsid = lb[:members].find { |msid| $sessions[msid] && $sessions[msid][:user] == tgt && msid != sid }
        if tsid
          lb[:scores] ||= Hash.new(0)
          lb[:scores][st[:user]] = lb[:scores][st[:user]].to_i + 1
          $sessions[tsid][:inbox] << { t: "tagged", by: st[:user], score: lb[:scores][st[:user]] }
          lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[PVP]", msg: "#{st[:user]} transfurred #{tgt}! (Tags: #{lb[:scores][st[:user]]})" } if $sessions[msid] }
        end
      end
    when "sync"
      st.merge!(map: data["m"], x: data["x"], y: data["y"], dir: data["d"], spr: data["s"], idx: data["i"]) if data["m"]
      st[:badge] = sanitize_badge(st[:user], data["b"]) if data["b"]
      lb = $lobbies[st[:lobby]]
      if lb
        lb[:members].each do |msid|
          next if msid == sid || !$sessions[msid]
          $sessions[msid][:inbox] << { t: "p_pos", u: st[:user], b: st[:badge], m: st[:map], x: st[:x], y: st[:y], d: st[:dir], s: st[:spr], i: st[:idx] }
        end
      end
      reply = { sid: sid, msgs: st[:inbox].slice!(0, 50) }
    when "chat"
      lb = $lobbies[st[:lobby]]
      now = Time.now.to_f
      if lb && now - st[:last_chat].to_f >= 0.8
        st[:last_chat] = now
        msg = clean_chat(data["msg"])
        lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[#{st[:badge]}] #{st[:user]}", msg: msg } if $sessions[msid] } unless msg.empty?
      end
    when "sw"
      lb = $lobbies[st[:lobby]]
      if lb
        lb[:switches][data["id"].to_s] = data["v"]
        lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "sw", id: data["id"], v: data["v"] } if msid != sid && $sessions[msid] }
      end
    end

    [200, { "Content-Type" => "application/json" }, [reply.to_json]]
  else
    prune_stale!
    [200, { "Content-Type" => "text/plain" }, ["Changed MP Server Online (Firebase: #{!FB_URL.empty?}) | Lobbies: #{$lobbies.size} | Players: #{$sessions.size}"]]
  end
end

port = (ENV["PORT"] || 3000).to_i
Puma::Server.new(App).tap { |s| s.add_tcp_listener("0.0.0.0", port) }.run.join
