module ChangedMP_Profile
  @last_bio_err = ""
  def self.last_bio_err; @last_bio_err; end

  def self.extract_bool(raw, key)
    dq = 34.chr
    raw.to_s =~ Regexp.new(dq + key + dq + '\s*:\s*true', Regexp::IGNORECASE) ? true : false
  end

  def self.extract_int(raw, key)
    dq = 34.chr
    m = raw.to_s.match(Regexp.new(dq + key + dq + '\s*:\s*(\d+)'))
    m ? m.captures.first.to_i : 0
  end

  def self.current_token
    t = ChangedMP.token.to_s
    return t unless t.empty?
    if File.exist?("mp_auth.dat")
      d = Marshal.load(File.binread("mp_auth.dat")) rescue nil
      return d.fetch(:token).to_s if d.is_a?(Hash) && d.key?(:token)
    end
    ""
  end

  def self.fetch(target)
    u = target.to_s.strip.upcase
    return nil if u.empty?
    raw = ChangedMP.request(:get, ChangedMP.server_url + "/api/profile?username=" + u).to_s
    return nil unless (raw.include?("true") || raw.include?("ok")) && raw.include?("username")
    online = extract_bool(raw, "online")
    lobby  = ChangedMP_Auth.extract_str(raw, "lobby")
    map_id = extract_int(raw, "map_id")
    if u == ChangedMP.username.to_s.upcase && ChangedMP.mp_mode
      online = true
      lobby  = ChangedMP.current_lobby.to_s if lobby.empty?
      map_id = $game_map.map_id if map_id == 0 && $game_map
    elsif ChangedMP.remote_players && ChangedMP.remote_players.key?(u)
      rp = ChangedMP.remote_players.fetch(u)
      online = true
      lobby  = ChangedMP.current_lobby.to_s if lobby.empty?
      map_id = rp.fetch(:map_id) if map_id == 0
    end
    {
      :username => ChangedMP_Auth.extract_str(raw, "username"),
      :role     => ChangedMP_Auth.extract_str(raw, "role"),
      :bio      => ChangedMP_Auth.extract_str(raw, "bio"),
      :joined   => ChangedMP_Auth.extract_str(raw, "joined"),
      :friends  => extract_int(raw, "friends"),
      :online   => online,
      :lobby    => lobby,
      :map_id   => map_id
    }
  rescue Exception
    nil
  end

  def self.update_bio(new_bio)
    @last_bio_err = ""
    tok = current_token
    if tok.empty?
      @last_bio_err = "Not logged in (missing token)!"
      return false
    end
    pairs = Array.new
    pairs.push(Array.new(2) { |i| i == 0 ? "username" : ChangedMP.username.to_s.upcase })
    pairs.push(Array.new(2) { |i| i == 0 ? "token" : tok })
    pairs.push(Array.new(2) { |i| i == 0 ? "bio" : new_bio.to_s })
    raw = ChangedMP.request(:post, ChangedMP.server_url + "/api/profile/bio", ChangedMP_Auth.json_kv(pairs)).to_s
    if raw.include?("true") || raw.include?("ok")
      true
    else
      err = ChangedMP_Auth.extract_str(raw, "error")
      @last_bio_err = err.empty? ? ("Server rejected: " + raw.slice(0, 36).to_s) : err
      false
    end
  rescue Exception => e
    @last_bio_err = "Error: " + e.message.to_s
    false
  end

  def self.open(target, prev_scene = nil)
    $scene = Scene_MPProfile.new(target, prev_scene || $scene)
  end
end

class Scene_MPProfile < Scene_Base
  def initialize(target, prev_scene)
    @target = target.to_s.strip.upcase
    @prev_scene = prev_scene
  end

  def start
    super
    @bg = Sprite.new
    @bg.z = 50
    @bg.bitmap = Bitmap.new(Graphics.width, Graphics.height)
    @bg.bitmap.fill_rect(0, 0, Graphics.width, Graphics.height, Color.new(10, 12, 18, 255))
    @card = Window_Base.new(20, 16, 504, 210)
    @card.z = 100
    @status = Window_Base.new(20, 224, 504, 56)
    @status.z = 100
    @cmd = nil
    @input_win = nil
    @data = nil
    reload_profile
  end

  def terminate
    super
    @cmd.dispose if @cmd && !@cmd.disposed?
    @card.dispose if @card && !@card.disposed?
    @status.dispose if @status && !@status.disposed?
    @input_win.dispose if @input_win && !@input_win.disposed?
    @bg.dispose if @bg && !@bg.disposed?
  end

  def set_note(txt)
    return unless @status && !@status.disposed?
    @status.contents.clear
    @status.contents.font.size = 18
    @status.contents.draw_text(4, 0, 472, 24, txt.to_s)
  end

  def reload_profile
    @data = ChangedMP_Profile.fetch(@target)
    draw_card
    rebuild_commands
    set_note(@data ? ("Profile: " + @data.fetch(:username)) : ("Not found: " + @target))
  end

  def draw_card
    return unless @card && !@card.disposed?
    @card.contents.clear
    unless @data
      @card.contents.draw_text(8, 12, 460, 28, "No profile data for " + @target)
      return
    end
    lb = 91.chr
    rb = 93.chr
    role = @data.fetch(:role).to_s.upcase
    badge = role.empty? ? (lb + "PLAYER" + rb) : (lb + role + rb)
    @card.contents.font.size = 22
    @card.contents.draw_text(8, 4, 468, 28, badge + " " + @data.fetch(:username))
    @card.contents.font.size = 18
    is_on = @data.fetch(:online)
    @card.contents.font.color = is_on ? Color.new(90, 255, 120) : Color.new(255, 95, 95)
    st = is_on ? ("ONLINE | " + @data.fetch(:lobby) + " (Map " + @data.fetch(:map_id).to_s + ")") : "OFFLINE"
    @card.contents.draw_text(8, 36, 468, 24, st)
    @card.contents.font.color = Color.new(235, 235, 245)
    @card.contents.draw_text(8, 64, 468, 24, "Joined: " + @data.fetch(:joined) + " | Friends: " + @data.fetch(:friends).to_s)
    @card.contents.draw_text(8, 96, 468, 24, "Bio:")
    bio = @data.fetch(:bio).to_s
    @card.contents.draw_text(8, 122, 468, 24, bio.slice(0, 44).to_s)
    @card.contents.draw_text(8, 146, 468, 24, bio.slice(44, 44).to_s) if bio.length > 44
  end

  def rebuild_commands
    @cmd.dispose if @cmd && !@cmd.disposed?
    items = Array.new
    if @data && @target == ChangedMP.username.to_s.upcase
      items.push("Edit Bio")
      items.push("Search Another Player")
    elsif @data
      items.push("Send Friend Request")
    else
      items.push("Search Another Player")
    end
    items.push("Back")
    @cmd = Window_Command.new(504, items)
    @cmd.x = 20
    @cmd.y = 282
    @cmd.z = 100
  end

  def update
    super
    @poll_tick = (@poll_tick || 0) + 1
    if @poll_tick >= 180 && @input_win.nil?
      @poll_tick = 0
      reload_profile
    end
    if @input_win && !@input_win.disposed?
      @input_win.update
      if Input.trigger?(Input::C)
        val = @input_win.text.to_s
        @input_win.dispose
        @input_win = nil
        @cmd.active = true if @cmd
        @input_cb.call(val) if @input_cb
      elsif Input.trigger?(Input::B)
        @input_win.dispose
        @input_win = nil
        @cmd.active = true if @cmd
      end
      return
    end
    @cmd.update if @cmd
    if Input.trigger?(Input::B)
      Sound.play_cancel
      $scene = @prev_scene || Scene_Map.new
    elsif Input.trigger?(Input::C) && @cmd
      Sound.play_decision
      ch = @cmd.commands.at(@cmd.index).to_s
      if ch == "Edit Bio"
        @cmd.active = false
        @input_win = Window_MPProfileInput.new("New Bio (max 64 chars):")
        @input_win.z = 200
        @input_cb = Proc.new { |t| ChangedMP_Profile.update_bio(t) ? reload_profile : set_note(ChangedMP_Profile.last_bio_err.empty? ? "Bio update failed!" : ChangedMP_Profile.last_bio_err) }
      elsif ch == "Search Another Player"
        @cmd.active = false
        @input_win = Window_MPProfileInput.new("Enter Username:")
        @input_win.z = 200
        @input_cb = Proc.new { |u| next if u.strip.empty?; @target = u.strip.upcase; reload_profile }
      elsif ch == "Send Friend Request"
        ChangedMP.add_friend(@target)
        set_note("Friend request sent to " + @target + "!")
      else
        $scene = @prev_scene || Scene_Map.new
      end
    end
  end
end

if defined?(Scene_ChangedMP)
  class Scene_ChangedMP
    alias_method :_mp_orig_set_status, :set_status
    def set_status(txt)
      if (txt == "Login failed!" || txt == "Register failed!") && !ChangedMP_Auth.last_error.empty?
        _mp_orig_set_status(ChangedMP_Auth.last_error)
      else
        _mp_orig_set_status(txt)
      end
    end

    alias_method :_mp_orig_show_in_server_menu, :show_in_server_menu
    def show_in_server_menu
      _mp_orig_show_in_server_menu
      return unless @list_win && !@list_win.disposed?
      cmds = @list_win.commands.dup
      back_item = cmds.pop
      cmds.push("My Profile / Search")
      cmds.push(back_item) if back_item
      @list_win.dispose
      @list_win = Window_Command.new(504, cmds)
      @list_win.x = 20
      @list_win.y = 80
    end

    alias_method :_mp_orig_handle_selection, :handle_selection
    def handle_selection
      if @list_win && !@list_win.disposed?
        sel = @list_win.commands.at(@list_win.index).to_s
        if @mode == :in_server && sel == "My Profile / Search"
          ChangedMP_Profile.open(ChangedMP.username, self)
          return
        elsif @mode == :online_list && sel != "Back"
          lb = 91.chr
          rb = 93.chr
          uname = sel.split(" ").find { |w| !w.start_with?(lb) && !w.start_with?("(") && !w.end_with?(rb) }
          ChangedMP_Profile.open(uname.to_s, self) unless uname.to_s.empty?
          return
        end
      end
      _mp_orig_handle_selection
    end
  end
end

class Window_MPProfileInput < Window_Base
  attr_reader :text
  def initialize(label)
    super(40, 140, 464, 104)
    self.z = 220
    @label = label.to_s
    @text = ""
    @tick = 0
    Input.text_input = true if Input.respond_to?(:text_input=)
    refresh
  end

  def dispose
    Input.text_input = false if Input.respond_to?(:text_input=)
    super
  end

  def update
    super
    @tick += 1
    changed = false
    if Input.respond_to?(:gets)
      g = Input.gets.to_s.gsub(/[\r\n\x00-\x1f]/, "")
      unless g.empty?
        @text += g
        changed = true
      end
    end
    if Input.repeat?(Input::LEFT) || Input.trigger?(Input::CTRL)
      unless @text.empty?
        @text = @text.slice(0, @text.length - 1).to_s
        changed = true
      end
    end
    refresh if changed || (@tick % 20 == 0)
  end

  def refresh
    self.contents.clear
    self.contents.font.size = 18
    self.contents.draw_text(4, 0, 424, 24, @label)
    cur = ((@tick / 20) % 2 == 0) ? "_" : ""
    self.contents.draw_text(4, 34, 424, 28, @text + cur)
  end
end

class Scene_MPProfile
  alias_method :_prof_orig_start, :start
  def start
    _prof_orig_start
    @bg.z = 150 if @bg
    @card.z = 160 if @card
    @status.z = 160 if @status
    @cmd.z = 160 if @cmd
  end

  alias_method :_prof_orig_rebuild, :rebuild_commands
  def rebuild_commands
    _prof_orig_rebuild
    @cmd.z = 160 if @cmd
  end
end

if defined?(Sprite_LocalPlayerTag)
  class Sprite_LocalPlayerTag
    alias_method :_mp_orig_local_tag_update, :update
    def update
      _mp_orig_local_tag_update
      self.y -= 36 if self.visible
    end
  end
end

if defined?(Sprite_RemotePlayerTag)
  class Sprite_RemotePlayerTag
    alias_method :_mp_orig_remote_tag_update, :update
    def update
      _mp_orig_remote_tag_update
      self.y -= 36 if self.visible
    end
  end
end
