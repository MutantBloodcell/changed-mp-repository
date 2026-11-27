module ChangedMP_Commands
  @registry = Array.new
  @synced_once = false

  def self.all; @registry; end

  def self.reply(text)
    ChangedMP.push_chat_notification("system", "SYSTEM", text.to_s)
  end

  def self.register(name, usage, desc, role = "player", &block)
    entry = Hash.new
    entry.store(:name, name.to_s.downcase)
    entry.store(:usage, usage.to_s)
    entry.store(:desc, desc.to_s)
    entry.store(:role, role.to_s.downcase)
    entry.store(:handler, block)
    @registry.reject! { |c| c.fetch(:name) == entry.fetch(:name) }
    @registry.push(entry)
  end

  def self.sync_to_api(silent = true)
    return false unless ChangedMP.admin?
    tok = defined?(ChangedMP_Profile) ? ChangedMP_Profile.current_token : ChangedMP.token.to_s
    return false if tok.empty?
    dq = 34.chr
    items = @registry.map do |c|
      ChangedMP_Auth.json_kv([
        ["name", c.fetch(:name)],
        ["usage", c.fetch(:usage)],
        ["desc", c.fetch(:desc)],
        ["role", c.fetch(:role)]
      ])
    end
    body = "{" + dq + "username" + dq + ":" + dq + ChangedMP.username.to_s.upcase + dq + "," +
           dq + "token" + dq + ":" + dq + tok + dq + "," +
           dq + "commands" + dq + ":[" + items.join(",") + "]}"
    raw = ChangedMP.request(:post, ChangedMP.server_url + "/api/commands/sync", body).to_s
    ok = raw.include?("true") || raw.include?("ok")
    reply("Synced " + @registry.size.to_s + " commands to API!") if ok && !silent
    ok
  rescue Exception
    false
  end

  def self.run(raw)
    line = raw.to_s.strip
    return false unless line.start_with?("/")
    if !@synced_once && ChangedMP.admin?
      @synced_once = true
      sync_to_api(true)
    end
    parts = line.split(" ", 2)
    cmd = parts.at(0).to_s.downcase
    arg = parts.at(1).to_s.strip
    entry = @registry.find { |c| c.fetch(:name) == cmd }
    unless entry
      reply("Unknown command: " + cmd + " (Type /help)")
      return true
    end
    if entry.fetch(:role) == "admin" && !ChangedMP.admin?
      reply("Admin/Dev only command.")
      return true
    end
    entry.fetch(:handler).call(arg)
    true
  end
end

# ==========================================================
# REGISTER COMMANDS BELOW (Auto-added to /help & API Sync!)
# ==========================================================

ChangedMP_Commands.register("/help", "/help", "Show all available commands", "player") do |arg|
  allowed = ChangedMP_Commands.all.select { |c| c.fetch(:role) != "admin" || ChangedMP.admin? }
  names = allowed.map { |c| c.fetch(:usage) }
  ChangedMP_Commands.reply("Commands (" + names.size.to_s + "): " + names.join(", "))
end

ChangedMP_Commands.register("/profile", "/profile <user>", "Open player profile card", "player") do |arg|
  target = arg.empty? ? ChangedMP.username.to_s : arg
  defined?(ChangedMP_Profile) ? ChangedMP_Profile.open(target, $scene) : ChangedMP_Commands.reply("Profile module missing.")
end

ChangedMP_Commands.register("/bio", "/bio <text>", "Update your profile bio", "player") do |arg|
  if arg.empty?
    ChangedMP_Commands.reply("Usage: /bio <your new bio>")
  elsif defined?(ChangedMP_Profile) && ChangedMP_Profile.update_bio(arg)
    ChangedMP.play_chime
    ChangedMP_Commands.reply("Bio updated to: " + arg)
  else
    ChangedMP.play_buzzer
    ChangedMP_Commands.reply("Failed to update bio.")
  end
end

ChangedMP_Commands.register("/players", "/players", "List online players in server", "player") do |arg|
  names = Array.new
  names.push(ChangedMP.username.to_s + " (You)")
  ChangedMP.remote_players.each_key { |k| names.push(k.to_s) } if ChangedMP.remote_players
  ChangedMP_Commands.reply("Online (" + names.size.to_s + "): " + names.join(", "))
end

ChangedMP_Commands.register("/rules", "/rules", "Show server rules reminder", "player") do |arg|
  ChangedMP_Commands.reply("Server Rules: Be respectful, no exploits, follow Discord #rules!")
end

ChangedMP_Commands.register("/clear", "/clear", "Clear your overhead chat bubble", "player") do |arg|
  ChangedMP.set_chat("")
  ChangedMP_Commands.reply("Cleared chat bubble.")
end

ChangedMP_Commands.register("/tp", "/tp <user>", "Teleport to an online player", "admin") do |arg|
  pdata = ChangedMP.remote_players ? ChangedMP.remote_players.fetch(arg.upcase, nil) : nil
  if pdata && ChangedMP.mp_mode
    $game_player.reserve_transfer(pdata.fetch(:map_id), pdata.fetch(:x), pdata.fetch(:y), pdata.fetch(:dir))
    ChangedMP_Commands.reply("Teleported to " + arg.upcase + "!")
  else
    ChangedMP_Commands.reply("Player not found in current server.")
  end
end

ChangedMP_Commands.register("/warp", "/warp <map_id>", "Warp to any Map ID", "admin") do |arg|
  m = arg.to_i
  if m > 0 && ChangedMP.mp_mode
    $game_player.reserve_transfer(m, $game_player.x, $game_player.y, $game_player.direction)
    ChangedMP_Commands.reply("Warped to Map " + m.to_s + "!")
  else
    ChangedMP_Commands.reply("Usage: /warp <map_id>")
  end
end

ChangedMP_Commands.register("/announce", "/announce <msg>", "Broadcast server announcement", "admin") do |arg|
  next if arg.empty?
  ChangedMP.request(:post, ChangedMP.server_url + "/api/admin/announce",
    ChangedMP_Auth.json_kv([["admin", ChangedMP.username], ["token", ChangedMP.token], ["message", arg]]))
  ChangedMP_Commands.reply("Announcement sent!")
end

ChangedMP_Commands.register("/kick", "/kick <user>", "Kick a player from server", "admin") do |arg|
  next if arg.empty?
  ChangedMP.request(:post, ChangedMP.server_url + "/api/admin/kick",
    ChangedMP_Auth.json_kv([["admin", ChangedMP.username], ["token", ChangedMP.token], ["target", arg.upcase]]))
  ChangedMP_Commands.reply("Kicked " + arg.upcase + "!")
end

ChangedMP_Commands.register("/sync_commands", "/sync_commands", "Force sync commands to API", "admin") do |arg|
  ChangedMP_Commands.reply("Sync failed!") unless ChangedMP_Commands.sync_to_api(false)
end

module ChangedMP
  class << self
    alias_method :_mp_orig_set_chat, :set_chat
    def set_chat(msg)
      return if ChangedMP_Commands.run(msg)
      _mp_orig_set_chat(msg)
    end
  end
end
