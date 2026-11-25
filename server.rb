require "faye/websocket"
require "json"
require "digest"
require "puma"

ACCOUNTS_FILE = "accounts.json"
$accounts = File.exist?(ACCOUNTS_FILE) ? JSON.parse(File.read(ACCOUNTS_FILE)) : {}
$clients  = {} # ws => { user:, lobby:, map:, x:, y:, dir:, spr:, idx:, tag_latex: }
$lobbies  = {} # id => { id:, name:, mode:, host:, pass:, max:, members: [], switches: {}, self_sw: {} }

def save_accounts
  File.write(ACCOUNTS_FILE, JSON.pretty_generate($accounts))
end

def send_msg(ws, hash)
  ws.send(hash.to_json) rescue nil
end

def broadcast_lobby(lid, hash, except_ws = nil)
  lb = $lobbies[lid]
  return unless lb
  lb[:members].each do |m_ws|
    next if m_ws == except_ws
    send_msg(m_ws, hash)
  end
end

def lobby_list_payload
  $lobbies.values.map do |l|
    { id: l[:id], name: l[:name], mode: l[:mode], count: l[:members].size, max: l[:max], locked: !l[:pass].to_s.empty? }
  end
end

App = lambda do |env|
  if Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env, nil, ping: 15)
    $clients[ws] = { user: nil, lobby: nil, map: 1, x: 10, y: 10, dir: 2, spr: "$Colin", idx: 0 }

    ws.on :message do |event|
      data = JSON.parse(event.data) rescue next
      st = $clients[ws]
      case data["t"]
      when "register"
        u = data["u"].to_s.strip; p = data["p"].to_s
        if u.empty? || p.empty?
          send_msg(ws, { t: "auth_err", msg: "Username/password required" })
        elsif $accounts.key?(u)
          send_msg(ws, { t: "auth_err", msg: "Username already taken" })
        else
          $accounts[u] = { "hash" => Digest::SHA256.hexdigest(p), "spr" => data["spr"] || "$Colin" }
          save_accounts
          st[:user] = u; st[:spr] = $accounts[u]["spr"]
          send_msg(ws, { t: "auth_ok", user: u, spr: st[:spr], lobbies: lobby_list_payload })
        end

      when "login"
        u = data["u"].to_s.strip; p = data["p"].to_s
        acc = $accounts[u]
        if acc && acc["hash"] == Digest::SHA256.hexdigest(p)
          st[:user] = u; st[:spr] = acc["spr"] || "$Colin"
          send_msg(ws, { t: "auth_ok", user: u, spr: st[:spr], lobbies: lobby_list_payload })
        else
          send_msg(ws, { t: "auth_err", msg: "Invalid credentials" })
        end

      when "lobbies"
        send_msg(ws, { t: "lobby_list", lobbies: lobby_list_payload })

      when "create_lobby"
        next unless st[:user]
        lid = "L#{rand(1000..9999)}"
        $lobbies[lid] = {
          id: lid, name: data["name"].to_s.empty? ? "#{st[:user]}'s Room" : data["name"],
          mode: data["mode"] || "Co-Op Story", host: st[:user], pass: data["pass"].to_s,
          max: [[data["max"].to_i, 2].max, 16].min, members: [ws], switches: {}, self_sw: {}
        }
        st[:lobby] = lid
        send_msg(ws, { t: "joined_lobby", lobby: $lobbies[lid].slice(:id, :name, :mode, :host) })

      when "join_lobby"
        next unless st[:user]
        lb = $lobbies[data["id"]]
        if !lb
          send_msg(ws, { t: "lobby_err", msg: "Lobby not found" })
        elsif lb[:members].size >= lb[:max]
          send_msg(ws, { t: "lobby_err", msg: "Lobby full" })
        elsif !lb[:pass].empty? && lb[:pass] != data["pass"].to_s
          send_msg(ws, { t: "lobby_err", msg: "Wrong lobby password" })
        else
          lb[:members] << ws unless lb[:members].include?(ws)
          st[:lobby] = lb[:id]
          send_msg(ws, { t: "joined_lobby", lobby: lb.slice(:id, :name, :mode, :host), switches: lb[:switches], self_sw: lb[:self_sw] })
          broadcast_lobby(lb[:id], { t: "chat", user: "SYSTEM", msg: "#{st[:user]} joined!" })
        end

      when "pos"
        next unless st[:lobby]
        st.merge!(map: data["m"], x: data["x"], y: data["y"], dir: data["d"], spr: data["s"], idx: data["i"])
        broadcast_lobby(st[:lobby], { t: "p_pos", u: st[:user], m: st[:map], x: st[:x], y: st[:y], d: st[:dir], s: st[:spr], i: st[:idx] }, ws)

      when "sw"
        lb = $lobbies[st[:lobby]]; next unless lb
        lb[:switches][data["id"].to_s] = data["v"]
        broadcast_lobby(lb[:id], { t: "sw", id: data["id"], v: data["v"] }, ws)

      when "self_sw"
        lb = $lobbies[st[:lobby]]; next unless lb
        lb[:self_sw][data["k"]] = data["v"]
        broadcast_lobby(lb[:id], { t: "self_sw", k: data["k"], v: data["v"] }, ws)

      when "tag"
        lb = $lobbies[st[:lobby]]; next unless lb && lb[:mode] == "PvP Tag"
        broadcast_lobby(lb[:id], { t: "tagged", target: data["target"], by: st[:user] })

      when "chat"
        next unless st[:lobby] && st[:user]
        broadcast_lobby(st[:lobby], { t: "chat", user: st[:user], msg: data["msg"].to_s[0, 120] })
      end
    end

    ws.on :close do |_event|
      st = $clients.delete(ws)
      if st && st[:lobby] && (lb = $lobbies[st[:lobby]])
        lb[:members].delete(ws)
        broadcast_lobby(lb[:id], { t: "p_leave", u: st[:user] })
        broadcast_lobby(lb[:id], { t: "chat", user: "SYSTEM", msg: "#{st[:user]} left." })
        $lobbies.delete(lb[:id]) if lb[:members].empty?
      end
    end

    ws.rack_response
  else
    [200, { "Content-Type" => "text/plain" }, ["Changed MP Server Online | Lobbies: #{$lobbies.size} | Players: #{$clients.size}"]]
  end
end

port = (ENV["PORT"] || 3000).to_i
Puma::Server.new(App).tap { |s| s.add_tcp_listener("0.0.0.0", port) }.run.join
