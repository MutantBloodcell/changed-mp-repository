require "json"
require "digest"
require "net/http"
require "uri"
require "puma"
FB_URL = ENV["FIREBASE_URL"].to_s.sub(/\/+\z/, "")
$accounts = File.exist?("accounts.json") ? (JSON.parse(File.read("accounts.json")) rescue {}) : {}
$bans     = File.exist?("bans.json")     ? (JSON.parse(File.read("bans.json"))     rescue {}) : {}
$friends  = File.exist?("friends.json")  ? (JSON.parse(File.read("friends.json"))  rescue {}) : {}
$progress = File.exist?("progress.json") ? (JSON.parse(File.read("progress.json")) rescue {}) : {}
$sessions = {}; $lobbies = {}
BAD_WORDS = /\b(profanity1|profanity2|slur1|slur2|harassment1)\b/i
def fb_req(m, path, body = nil)
  return nil if FB_URL.empty?
  u = URI.parse("#{FB_URL}/#{path}.json")
  h = Net::HTTP.new(u.host, u.port); h.use_ssl = true
  r = m == :get ? Net::HTTP::Get.new(u.request_uri) : (m == :put ? Net::HTTP::Put.new(u.request_uri) : Net::HTTP::Delete.new(u.request_uri))
  r["Content-Type"] = "application/json"; r.body = body.to_json if body
  JSON.parse(h.request(r).body) rescue nil
rescue; nil; end
def get_account(u)
  return nil if u.to_s.empty?
  if !FB_URL.empty?; r = fb_req(:get, "accounts/#{URI.encode_www_form_component(u)}"); return r if r.is_a?(Hash); end
  $accounts[u]
end
def put_account(u, d)
  $accounts[u] = d; File.write("accounts.json", JSON.pretty_generate($accounts)) rescue nil
  fb_req(:put, "accounts/#{URI.encode_www_form_component(u)}", d) unless FB_URL.empty?
end
def is_admin_user?(u)
  return false if u.to_s.empty?
  return true if u.to_s.downcase == "admin"
  a = get_account(u); a.is_a?(Hash) && a["admin"] == true
end
def sanitize_badge(u, b)
  b = b.to_s.upcase; adm = is_admin_user?(u)
  return b if adm && (b == "DEV" || b == "ADMIN")
  return "PLAYER" if !adm && (b == "DEV" || b == "ADMIN")
  %w[PLAYER HOST VIP PURO SURVIVOR LATEX NEWBIE].include?(b) ? b : (adm ? "ADMIN" : "PLAYER")
end
def check_ban(u)
  return nil if u.to_s.empty? || u.to_s.downcase == "admin"
  k = u.to_s.downcase
  b = !FB_URL.empty? ? fb_req(:get, "bans/#{URI.encode_www_form_component(k)}") : $bans[k]
  b = $bans[k] unless b.is_a?(Hash); return nil unless b.is_a?(Hash)
  exp = b["until"].to_i
  if exp > 0 && Time.now.to_i >= exp
    $bans.delete(k); File.write("bans.json", JSON.pretty_generate($bans)) rescue nil
    fb_req(:delete, "bans/#{URI.encode_www_form_component(k)}") unless FB_URL.empty?; return nil
  end
  s = exp - Time.now.to_i
  rem = exp == 0 ? "PERMANENT" : (s >= 86400 ? "#{s/86400}d #{(s%86400)/3600}h" : (s >= 3600 ? "#{s/3600}h #{(s%3600)/60}m" : "#{[s/60,1].max}m"))
  { "reason" => (b["reason"] || "Rule violation"), "by" => (b["by"] || "Admin"), "remaining" => rem, "until" => exp }
end
def apply_ban(tgt, sec, rsn, by)
  return if tgt.to_s.empty? || tgt.to_s.downcase == "admin"
  k = tgt.to_s.downcase; exp = sec.to_i <= 0 ? 0 : (Time.now.to_i + sec.to_i)
  rec = { "user" => tgt, "until" => exp, "reason" => rsn.to_s, "by" => by.to_s }
  $bans[k] = rec; File.write("bans.json", JSON.pretty_generate($bans)) rescue nil
  fb_req(:put, "bans/#{URI.encode_www_form_component(k)}", rec) unless FB_URL.empty?; rec
end
def save_progress(u, p)
  return if u.to_s.empty?
  $progress[u] = p; File.write("progress.json", JSON.pretty_generate($progress)) rescue nil
  fb_req(:put, "progress/#{URI.encode_www_form_component(u)}", p) unless FB_URL.empty?
end
def load_progress(u)
  return nil if u.to_s.empty?
  if !FB_URL.empty?; r = fb_req(:get, "progress/#{URI.encode_www_form_component(u)}"); return r if r.is_a?(Hash); end
  $progress[u]
end
def get_friends(u)
  k = URI.encode_www_form_component(u.to_s)
  d = !FB_URL.empty? ? fb_req(:get, "friends/#{k}") : $friends[u]
  d = $friends[u] unless d.is_a?(Hash); d.is_a?(Hash) ? d : { "list" => [], "reqs" => [] }
end
def put_friends(u, d)
  $friends[u] = d; File.write("friends.json", JSON.pretty_generate($friends)) rescue nil
  fb_req(:put, "friends/#{URI.encode_www_form_component(u.to_s)}", d) unless FB_URL.empty?
end
def clean_chat(t); t.to_s.gsub(/[\r\n\t]+/, " ").strip.to_s.gsub(BAD_WORDS) { |m| "*" * m.size }; end
def leave_lobby(sid)
  st = $sessions[sid]; return unless st && st[:lobby]
  lb = $lobbies[st[:lobby]]
  if lb
    lb[:members].delete(sid)
    if lb[:host_sid] == sid || lb[:members].empty?
      lb[:members].each { |m| $sessions[m][:lobby] = nil if $sessions[m] }; $lobbies.delete(lb[:id])
    else
      lb[:members].each { |m| $sessions[m][:inbox] << { t: "p_leave", u: st[:user] } if $sessions[m] }
    end
  end
  st[:lobby] = nil
end
def lobby_list_payload
  now = Time.now.to_i
  $sessions.each { |s, st| (leave_lobby(s); $sessions.delete(s)) if now - st[:seen].to_i > 25 }
  $lobbies.delete_if { |_i, lb| lb[:members].empty? || !$sessions[lb[:host_sid]] }
  $lobbies.values.map { |l| { id: l[:id], name: l[:name], mode: l[:mode], count: l[:members].size, max: l[:max] } }
end
App = lambda do |env|
  if env["PATH_INFO"] == "/api" && env["REQUEST_METHOD"] == "POST"
    d = JSON.parse(env["rack.input"].read) rescue {}
    sid = d["sid"] || "S#{rand(100000..999999)}"
    st = ($sessions[sid] ||= { user: nil, lobby: nil, map: 1, x: 10, y: 10, dir: 2, spr: "", idx: 0, badge: "PLAYER", seen: Time.now.to_i, last_chat: 0, inbox: [] })
    st[:seen] = Time.now.to_i; reply = { sid: sid }
    case d["t"]
    when "register"
      u = d["u"].to_s.strip; p = d["p"].to_s
      if (b = check_ban(u)); reply = { sid: sid, t: "banned", ban: b }
      elsif u.empty? || p.empty?; reply = { sid: sid, t: "auth_err", msg: "Username/password required" }
      elsif u =~ BAD_WORDS; reply = { sid: sid, t: "auth_err", msg: "Username blocked by filter" }
      elsif get_account(u); reply = { sid: sid, t: "auth_err", msg: "Username already taken" }
      else
        bg = u.downcase == "admin" ? "DEV" : "NEWBIE"
        put_account(u, { "hash" => Digest::SHA256.hexdigest(p), "badge" => bg, "admin" => (u.downcase == "admin") })
        st[:user] = u; st[:badge] = bg
        reply = { sid: sid, t: "auth_ok", user: u, badge: bg, is_admin: is_admin_user?(u), lobbies: lobby_list_payload }
      end
    when "login"
      u = d["u"].to_s.strip; p = d["p"].to_s; acc = get_account(u)
      if (b = check_ban(u)); reply = { sid: sid, t: "banned", ban: b }
      elsif acc && acc["hash"] == Digest::SHA256.hexdigest(p)
        st[:user] = u; st[:badge] = sanitize_badge(u, acc["badge"])
        reply = { sid: sid, t: "auth_ok", user: u, badge: st[:badge], is_admin: is_admin_user?(u), progress: load_progress(u), lobbies: lobby_list_payload }
      else; reply = { sid: sid, t: "auth_err", msg: "Invalid login" }; end
    when "save_progress"
      (save_progress(st[:user], { "map" => d["m"], "x" => d["x"], "y" => d["y"], "d" => d["d"], "skin" => d["s"], "badge" => st[:badge], "switches" => d["sw"], "variables" => d["vars"], "items" => d["items"] }); reply = { sid: sid, t: "prog_saved" }) if st[:user]
    when "lobbies"; reply = { sid: sid, t: "lobby_list", lobbies: lobby_list_payload }
    when "create_lobby"
      leave_lobby(sid); lid = "L#{rand(1000..9999)}"
      st[:badge] = sanitize_badge(st[:user], is_admin_user?(st[:user]) ? st[:badge] : "HOST")
      rn = clean_chat(d["name"].to_s)
      $lobbies[lid] = { id: lid, name: rn.empty? ? "#{st[:user]}'s Room" : rn, mode: d["mode"] || "Co-Op Story", host: st[:user], host_sid: sid, max: 8, members: [sid], switches: {}, scores: Hash.new(0) }
      st[:lobby] = lid; reply = { sid: sid, t: "joined_lobby", lobby: $lobbies[lid].slice(:id, :name, :mode, :host) }
    when "join_lobby"
      leave_lobby(sid); lb = $lobbies[d["id"]]
      if lb
        lb[:members] << sid unless lb[:members].include?(sid); st[:lobby] = lb[:id]
        reply = { sid: sid, t: "joined_lobby", lobby: lb.slice(:id, :name, :mode, :host), switches: lb[:switches] }
        lb[:members].each { |m| $sessions[m][:inbox] << { t: "chat", user: "[SYSTEM]", msg: "#{st[:user]} joined." } if $sessions[m] }
      else; reply = { sid: sid, t: "lobby_err", msg: "Lobby closed" }; end
    when "leave_lobby"; leave_lobby(sid); reply = { sid: sid, t: "lobby_list", lobbies: lobby_list_payload }
    when "kick"
      lb = $lobbies[st[:lobby]]
      if lb && (is_admin_user?(st[:user]) || lb[:host_sid] == sid)
        ts = lb[:members].find { |m| $sessions[m] && $sessions[m][:user] == d["target"].to_s && m != sid }
        ($sessions[ts][:inbox] << { t: "kicked", by: st[:user] }; leave_lobby(ts)) if ts
      end
    when "ban"
      if is_admin_user?(st[:user])
        tgt = d["target"].to_s; apply_ban(tgt, d["sec"].to_i, d["reason"].to_s, st[:user]); bi = check_ban(tgt)
        $sessions.each { |m, ms| (ms[:inbox] << { t: "banned", ban: bi }; leave_lobby(m)) if ms[:user].to_s.downcase == tgt.downcase }
      end
    when "promote", "demote"
      if st[:user].to_s.downcase == "admin"
        tgt = d["target"].to_s; acc = get_account(tgt); adm = (d["t"] == "promote")
        if acc && (adm || tgt.downcase != "admin")
          acc["admin"] = adm; acc["badge"] = adm ? "ADMIN" : "PLAYER"; put_account(tgt, acc)
          $sessions.each_value { |ms| (ms[:badge] = acc["badge"]; ms[:inbox] << { t: "promoted", admin: adm, badge: acc["badge"] }) if ms[:user].to_s.downcase == tgt.downcase }
        end
      end
    when "announce"
      (msg = clean_chat(d["msg"]); $sessions.each_value { |ms| ms[:inbox] << { t: "announce", user: st[:user], msg: msg } } unless msg.empty?) if is_admin_user?(st[:user])
    when "server_info"; reply = { sid: sid, t: "server_info", players: $sessions.size, lobbies: $lobbies.size, accounts: $accounts.size, bans: $bans.size, firebase: !FB_URL.empty? }
    when "friend_add"
      tgt = d["target"].to_s.strip
      if st[:user] && !tgt.empty? && tgt.downcase != st[:user].downcase && get_account(tgt)
        tf = get_friends(tgt); tf["reqs"] ||= []; tf["list"] ||= []
        (tf["reqs"] << st[:user]; put_friends(tgt, tf)) if !tf["list"].include?(st[:user]) && !tf["reqs"].include?(st[:user])
        reply = { sid: sid, t: "friend_ok", msg: "Sent to #{tgt}" }
      else; reply = { sid: sid, t: "friend_err", msg: "Not found" }; end
    when "friend_accept"
      fu = d["target"].to_s.strip
      if st[:user] && !fu.empty?
        mf = get_friends(st[:user]); tf = get_friends(fu); mf["reqs"] ||= []; mf["list"] ||= []; tf["list"] ||= []
        mf["reqs"].delete(fu); mf["list"] << fu unless mf["list"].include?(fu); tf["list"] << st[:user] unless tf["list"].include?(st[:user])
        put_friends(st[:user], mf); put_friends(fu, tf); reply = { sid: sid, t: "friend_ok", msg: "Accepted #{fu}" }
      end
    when "friends_list"
      if st[:user]
        mf = get_friends(st[:user]); om = {}; $sessions.each_value { |ms| om[ms[:user]] = ms[:lobby] if ms[:user] }
        fl = (mf["list"] || []).map { |fu| { "u" => fu, "online" => om.key?(fu), "lobby" => om[fu] } }
        reply = { sid: sid, t: "friends_data", friends: fl, reqs: (mf["reqs"] || []) }
      end
    when "pvp_tag"
      lb = $lobbies[st[:lobby]]
      if lb && lb[:mode] == "PvP Tag"
        ts = lb[:members].find { |m| $sessions[m] && $sessions[m][:user] == d["target"].to_s && m != sid }
        if ts
          lb[:scores][st[:user]] += 1; $sessions[ts][:inbox] << { t: "tagged", by: st[:user], score: lb[:scores][st[:user]] }
          lb[:members].each { |m| $sessions[m][:inbox] << { t: "chat", user: "[PVP]", msg: "#{st[:user]} transfurred #{d['target']}!" } if $sessions[m] }
        end
      end
    when "sync"
      st.merge!(map: d["m"], x: d["x"], y: d["y"], dir: d["d"], spr: d["s"], idx: d["i"]) if d["m"]
      st[:badge] = sanitize_badge(st[:user], d["b"]) if d["b"]
      lb = $lobbies[st[:lobby]]
      lb[:members].each { |m| $sessions[m][:inbox] << { t: "p_pos", u: st[:user], b: st[:badge], m: st[:map], x: st[:x], y: st[:y], d: st[:dir], s: st[:spr], i: st[:idx] } if m != sid && $sessions[m] } if lb
      reply = { sid: sid, msgs: st[:inbox].slice!(0, 50) }
    when "chat"
      lb = $lobbies[st[:lobby]]; now = Time.now.to_f
      if lb && now - st[:last_chat].to_f >= 0.8
        st[:last_chat] = now; msg = clean_chat(d["msg"])
        lb[:members].each { |m| $sessions[m][:inbox] << { t: "chat", user: "[#{st[:badge]}] #{st[:user]}", msg: msg } if $sessions[m] } unless msg.empty?
      end
    when "sw"
      lb = $lobbies[st[:lobby]]
      if lb; lb[:switches][d["id"].to_s] = d["v"]; lb[:members].each { |m| $sessions[m][:inbox] << { t: "sw", id: d["id"], v: d["v"] } if m != sid && $sessions[m] }; end
    end
    [200, { "Content-Type" => "application/json" }, [reply.to_json]]
  else
    lobby_list_payload
    [200, { "Content-Type" => "text/plain" }, ["Changed MP Server Online (Firebase: #{!FB_URL.empty?}) | Lobbies: #{$lobbies.size} | Players: #{$sessions.size}"]]
  end
end
Puma::Server.new(App).tap { |s| s.add_tcp_listener("0.0.0.0", (ENV["PORT"] || 3000).to_i) }.run.join
