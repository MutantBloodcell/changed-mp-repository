module ChangedMP_ChatBox
  @history = Array.new
  @open = false
  @scroll = 0
  @dirty = true

  def self.history; @history; end
  def self.open?; @open; end
  def self.dirty?; @dirty; end
  def self.clear_dirty; @dirty = false; end

  def self.record(role, text, sender = "")
    line = text.to_s.strip
    return if line.empty?
    entry = Hash.new
    entry.store(:role, role.to_s.downcase)
    entry.store(:sender, sender.to_s.upcase)
    entry.store(:text, line)
    @history.push(entry)
    @history.shift while @history.size > 150
    @scroll = 0
    @dirty = true
  end

  def self.toggle
    @open = !@open
    @scroll = 0
    @dirty = true
    Sound.play_decision
  end

  def self.close
    if @open
      @open = false
      @dirty = true
      Sound.play_cancel
    end
  end

  def self.scroll_up
    max_off = @history.size > 5 ? (@history.size * 2) : 0
    if @scroll < max_off
      @scroll += 1
      @dirty = true
      Sound.play_cursor
    end
  end

  def self.scroll_down
    if @scroll > 0
      @scroll -= 1
      @dirty = true
      Sound.play_cursor
    end
  end
end

module ChangedMP
  class << self
    alias_method :_cb_orig_push_notif, :push_chat_notification
    def push_chat_notification(sender, role_str, msg)
      _cb_orig_push_notif(sender, role_str, msg)
      lb = 91.chr
      rb = 93.chr
      r = role_str.to_s.upcase
      prefix = (r.empty? || r == "PLAYER") ? "" : (lb + r + rb + " ")
      ChangedMP_ChatBox.record(role_str, prefix + sender.to_s + ": " + msg.to_s, sender.to_s)
    end

    alias_method :_cb_orig_push_feed, :push_chat_feed
    def push_chat_feed(msg)
      _cb_orig_push_feed(msg)
      ChangedMP_ChatBox.record("system", msg.to_s, "")
    end
  end
end

class Window_MPBigChat < Window_Base
  def initialize
    super(20, 24, 504, 292)
    self.z = 210
    self.opacity = 255
    self.back_opacity = 255
    refresh
  end

  def role_color(item)
    role = item.fetch(:role).to_s
    snd  = item.fetch(:sender, "").to_s
    return Color.new(255, 215, 70) if role == "dev"
    return Color.new(80, 235, 255) if role == "admin"
    if !snd.empty? && ChangedMP.friends && ChangedMP.friends.include?(snd)
      return Color.new(90, 255, 120)
    end
    return Color.new(180, 200, 225) if role == "system"
    Color.new(240, 240, 245)
  end

  def wrap_items(hist)
    wrapped = Array.new
    hist.each do |item|
      txt = item.fetch(:text).to_s
      max_len = 50
      if txt.length <= max_len
        wrapped.push(item)
      else
        rem = txt
        while rem.length > max_len
          cut = rem.rindex(" ", max_len)
          cut = max_len if !cut || cut < 18
          part = rem.slice(0, cut).to_s.strip
          rem = rem.slice(cut, rem.length - cut).to_s.strip
          row_item = item.dup
          row_item.store(:text, part)
          wrapped.push(row_item)
        end
        unless rem.empty?
          row_item = item.dup
          row_item.store(:text, rem)
          wrapped.push(row_item)
        end
      end
    end
    wrapped
  end

  def refresh
    ChangedMP_ChatBox.clear_dirty
    self.contents.clear
    self.contents.fill_rect(0, 0, self.contents.width, self.contents.height, Color.new(10, 12, 18, 240))
    hist = ChangedMP_ChatBox.history
    total = hist.size

    self.contents.font.size = 18
    self.contents.font.color = Color.new(130, 220, 255)
    lobby = ChangedMP.current_lobby.to_s
    self.contents.draw_text(4, 0, 464, 22, "SERVER CHAT (" + lobby + ") - " + total.to_s + " msgs")

    self.contents.font.size = 15
    self.contents.font.color = Color.new(175, 185, 200)
    self.contents.draw_text(4, 22, 464, 18, "Up/Down: Scroll Messages | F7 or X: Close")

    if total == 0
      self.contents.font.size = 18
      self.contents.font.color = Color.new(180, 180, 190)
      self.contents.draw_text(4, 54, 464, 24, "No messages yet.")
      return
    end

    wrapped = wrap_items(hist)
    rows = 10
    w_total = wrapped.size
    off = ChangedMP_ChatBox.instance_variable_get(:@scroll).to_i
    end_idx = w_total - off
    end_idx = 0 if end_idx < 0
    start_idx = end_idx > rows ? (end_idx - rows) : 0
    slice = wrapped.slice(start_idx, end_idx - start_idx) || Array.new

    self.contents.font.size = 17
    slice.each_with_index do |item, i|
      y = 46 + (i * 21)
      self.contents.font.color = role_color(item)
      self.contents.draw_text(4, y, 464, 21, item.fetch(:text).to_s)
    end
  end
end

if defined?(Scene_Map)
  class Scene_Map
    alias_method :_cb_orig_update, :update
    def update
      if ChangedMP.mp_mode
        ChangedMP_ChatBox.toggle if Input.trigger?(Input::F7)
        if ChangedMP_ChatBox.open?
          @mp_big_chat = Window_MPBigChat.new if !@mp_big_chat || @mp_big_chat.disposed?
          @mp_big_chat.update
          @mp_big_chat.refresh if ChangedMP_ChatBox.dirty?
          if Input.repeat?(Input::UP)
            ChangedMP_ChatBox.scroll_up
          elsif Input.repeat?(Input::DOWN)
            ChangedMP_ChatBox.scroll_down
          elsif Input.trigger?(Input::B)
            ChangedMP_ChatBox.close
          end
          return
        elsif @mp_big_chat && !@mp_big_chat.disposed?
          @mp_big_chat.dispose
          @mp_big_chat = nil
        end
      end
      _cb_orig_update
    end

    alias_method :_cb_orig_terminate, :terminate
    def terminate
      @mp_big_chat.dispose if @mp_big_chat && !@mp_big_chat.disposed?
      _cb_orig_terminate
    end
  end
end

if defined?(ChangedMP_Commands)
  ChangedMP_Commands.register("/chat", "/chat", "Toggle big scrollable chat box", "player") do |arg|
    ChangedMP_ChatBox.toggle
    $scene = Scene_Map.new unless $scene.is_a?(Scene_Map)
  end
end
