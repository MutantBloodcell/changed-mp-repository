require "json"
require "digest"
require "puma"

ACCOUNTS_FILE = "accounts.json"
$accounts = File.exist?(ACCOUNTS_FILE) ? JSON.parse(File.read(ACCOUNTS_FILE)) : {}
$sessions = {} # sid => { user:, lobby:, map:, x:, y:, dir:, spr:, idx:, inbox: [] }
$lobbies  = {} # id => { id:, name:, mode:, host:, max:, members: [], switches: {} }

def save_accounts
  File.write(ACCOUNTS_FILE, JSON.pretty_generate($accounts))
end

def lobby_list_payload
  $lobbies.values.map do |l|
    { id: l[:id], name: l[:name], mode: l[:mode], count: l[:members].size, max: l[:max] }
  end
end

App = lambda do |env|
  if env["PATH_INFO"] == "/api" && env["REQUEST_METHOD"] == "POST"
    data = JSON.parse(env["rack.input"].read) rescue {}
    sid = data["sid"] || "S#{rand(100000..999999)}"
    st = ($sessions[sid] ||= { user: nil, lobby: nil, map: 1, x: 10, y: 10, dir: 2, spr: "$Colin", idx: 0, inbox: [] })
    reply = { sid: sid }

    case data["t"]
    when "register"
      u = data["u"].to_s.strip; p = data["p"].to_s
      if u.empty? || p.empty?
        reply = { sid: sid, t: "auth_err", msg: "Username/password required" }
      elsif $accounts.key?(u)
        reply = { sid: sid, t: "auth_err", msg: "Username already taken" }
      else
        $accounts[u] = { "hash" => Digest::SHA256.hexdigest(p), "spr" => "$Colin" }
        save_accounts
        st[:user] = u
        reply = { sid: sid, t: "auth_ok", user: u, lobbies: lobby_list_payload }
      end
    when "login"
      u = data["u"].to_s.strip; p = data["p"].to_s; acc = $accounts[u]
      if acc && acc["hash"] == Digest::SHA256.hexdigest(p)
        st[:user] = u
        reply = { sid: sid, t: "auth_ok", user: u, lobbies: lobby_list_payload }
      else
        reply = { sid: sid, t: "auth_err", msg: "Invalid login" }
      end
    when "lobbies"
      reply = { sid: sid, t: "lobby_list", lobbies: lobby_list_payload }
    when "create_lobby"
      lid = "L#{rand(1000..9999)}"
      $lobbies[lid] = {
        id: lid, name: data["name"].to_s.empty? ? "#{st[:user]}'s Room" : data["name"],
        mode: data["mode"] || "Co-Op Story", host: st[:user], max: 8, members: [sid], switches: {}
      }
      st[:lobby] = lid
      reply = { sid: sid, t: "joined_lobby", lobby: $lobbies[lid].slice(:id, :name, :mode, :host) }
    when "join_lobby"
      lb = $lobbies[data["id"]]
      if lb
        lb[:members] << sid unless lb[:members].include?(sid)
        st[:lobby] = lb[:id]
        reply = { sid: sid, t: "joined_lobby", lobby: lb.slice(:id, :name, :mode, :host), switches: lb[:switches] }
      else
        reply = { sid: sid, t: "lobby_err", msg: "Lobby not found" }
      end
    when "sync"
      st.merge!(map: data["m"], x: data["x"], y: data["y"], dir: data["d"], spr: data["s"], idx: data["i"]) if data["m"]
      lb = $lobbies[st[:lobby]]
      if lb
        lb[:members].each do |msid|
          next if msid == sid || !$sessions[msid]
          $sessions[msid][:inbox] << { t: "p_pos", u: st[:user], m: st[:map], x: st[:x], y: st[:y], d: st[:dir], s: st[:spr], i: st[:idx] }
        end
      end
      reply = { sid: sid, msgs: st[:inbox].slice!(0, 50) }
    when "chat"
      lb = $lobbies[st[:lobby]]
      lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "chat", user: st[:user], msg: data["msg"] } if $sessions[msid] } if lb
    when "sw"
      lb = $lobbies[st[:lobby]]
      if lb
        lb[:switches][data["id"].to_s] = data["v"]
        lb[:members].each { |msid| $sessions[msid][:inbox] << { t: "sw", id: data["id"], v: data["v"] } if msid != sid && $sessions[msid] }
      end
    end

    [200, { "Content-Type" => "application/json" }, [reply.to_json]]
  else
    [200, { "Content-Type" => "text/plain" }, ["Changed MP Server Online | Lobbies: #{$lobbies.size} | Players: #{$sessions.size}"]]
  end
end

port = (ENV["PORT"] || 3000).to_i
Puma::Server.new(App).tap { |s| s.add_tcp_listener("0.0.0.0", port) }.run.join
