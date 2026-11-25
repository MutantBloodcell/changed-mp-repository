require "json"
require "digest"
require "net/http"
require "uri"
require "puma"

FB_URL = ENV["FIREBASE_URL"].to_s.sub(/\/+\z/, "")
ACCOUNTS_FILE = "accounts.json"
$accounts = File.exist?(ACCOUNTS_FILE) ? JSON.parse(File.read(ACCOUNTS_FILE)) : {}
$sessions = {} # sid => { user:, lobby:, map:, x:, y:, dir:, spr:, idx:, badge:, seen:, last_chat:, inbox: [] }
$lobbies  = {} # id => { id:, name:, mode:, host:, host_sid:, max:, members: [], switches: {} }

BAD_WORDS = /\b(fuck|shit|bitch|cunt|nigger|nigga|faggot|retard|kys|kill yourself)\b/i

def fb_req(method, path, body = nil)
  return nil if FB_URL.empty?
  uri = URI.parse("#{FB_URL}/#{path}.json")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = case method
        when :get then Net::HTTP::Get.new(uri.request_uri)
        when :put then Net::HTTP::Put.new(uri.request_uri)
        when :patch then Net::HTTP::Patch.new(uri.request_uri)
        end
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  res = http.request(req)
  JSON.parse(res.body) rescue nil
rescue
  nil
end

def get_account(u)
  if !FB_URL.empty?
    fb_req(:get, "accounts/#{URI.encode_www_form_component(u)}")
  else
    $accounts[u]
  end
end

def put_account(u, data)
  $accounts[u] = data
  File.write(ACCOUNTS_FILE, JSON.pretty_generate($accounts))
  fb_req(:put, "accounts/#{URI.encode_www_form_component(u)}", data) unless FB_URL.empty?
end

def save_progress(u, prog)
  return if u.to_s.empty?
  fb_req(:put, "progress/#{URI.encode_www_form_component(u)}", prog) unless FB_URL.empty?
end

def load_progress(u)
  return nil if u.to_s.empty? || FB_URL.empty?
  fb_req(:get, "progress/#{URI.encode_www_form_component(u)}")
end

def clean_chat(txt)
  txt.to_s.gsub(/[\r\n\t]+/, " ").strip[0, 80].to_s.gsub(BAD_WORDS) { |m| "*" * m.size }
end

def sanitize_badge(user, badge)
  b = badge.to_s.upcase
  is_admin = (user.to_s.downcase == "admin")
  return "DEV" if is_admin && b == "DEV"
  return "PLAYER" if !is_admin && (b == "DEV" || b == "ADMIN")
  %w[PLAYER HOST VIP PURO SURVIVOR LATEX NEWBIE].include?(b) ? b : (is_admin ? "DEV" : "PLAYER")
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
      if u.empty? || p.empty?
        reply = { sid: sid, t: "auth_err", msg: "Username/password required" }
      elsif u =~ BAD_WORDS
        reply = { sid: sid, t: "auth_err", msg: "Username blocked by filter" }
      elsif get_account(u)
        reply = { sid: sid, t: "auth_err", msg: "Username already taken" }
      else
        b = (u.downcase == "admin" ? "DEV" : "NEWBIE")
        put_account(u, { "hash" => Digest::SHA256.hexdigest(p), "badge" => b })
        st[:user] = u; st[:badge] = b
        reply = { sid: sid, t: "auth_ok", user: u, badge: st[:badge], lobbies: lobby_list_payload }
      end
    when "login"
      u = data["u"].to_s.strip; p = data["p"].to_s; acc = get_account(u)
      if acc && acc["hash"] == Digest::SHA256.hexdigest(p)
        st[:user] = u; st[:badge] = sanitize_badge(u, acc["badge"])
        prog = load_progress(u)
        reply = { sid: sid, t: "auth_ok", user: u, badge: st[:badge], progress: prog, lobbies: lobby_list_payload }
      else
        reply = { sid: sid, t: "auth_err", msg: "Invalid login" }
      end
    when "save_progress"
      if st[:user]
        save_progress(st[:user], { "map" => data["m"], "x" => data["x"], "y" => data["y"], "skin" => data["s"], "badge" => st[:badge], "switches" => data["sw"] })
        reply = { sid: sid, t: "prog_saved" }
      end
    when "lobbies"
      reply = { sid: sid, t: "lobby_list", lobbies: lobby_list_payload }
    when "create_lobby"
      leave_lobby(sid)
      lid = "L#{rand(1000..9999)}"
      st[:badge] = sanitize_badge(st[:user], st[:user].to_s.downcase == "admin" ? "DEV" : "HOST")
      rname = clean_chat(data["name"].to_s)
      $lobbies[lid] = {
        id: lid, name: rname.empty? ? "#{st[:user]}'s Room" : rname,
        mode: data["mode"] || "Co-Op Story", host: st[:user], host_sid: sid, max: 8, members: [sid], switches: {}
      }
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
      if lb && (st[:user].to_s.downcase == "admin" || lb[:host_sid] == sid)
        target_u = data["target"].to_s
        tsid = lb[:members].find { |msid| $sessions[msid] && $sessions[msid][:user] == target_u && msid != sid }
        if tsid
          $sessions[tsid][:inbox] << { t: "kicked", by: st[:user] }
          leave_lobby(tsid)
          lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[SYSTEM]", msg: "#{target_u} was kicked by #{st[:user]}." } if $sessions[msid] }
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
        unless msg.empty?
          lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: "[#{st[:badge]}] #{st[:user]}", msg: msg } if $sessions[msid] }
        end
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
