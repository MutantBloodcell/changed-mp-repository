module ChangedMP_Auth
  @last_error = ""
  def self.last_error; @last_error; end

  def self.json_kv(pairs)
    bs = 92.chr
    dq = 34.chr
    parts = pairs.map do |k, v|
      val = v.to_s.gsub(bs, bs + bs).gsub(dq, bs + dq)
      dq + k.to_s + dq + ":" + dq + val + dq
    end
    "{" + parts.join(",") + "}"
  end

  def self.extract_str(raw, key)
    dq = 34.chr
    bs = 92.chr
    pat = Regexp.new(dq + key + dq + '\s*:\s*' + dq + '((?:\\.|[^' + dq + '])*)' + dq)
    m = raw.to_s.match(pat)
    return "" unless m
    m.captures.first.to_s.gsub(bs + dq, dq).gsub(bs + bs, bs)
  end

  def self.call(path, u, p)
    @last_error = ""
    uname = u.to_s.strip.upcase
    if uname.empty? || p.to_s.empty?
      @last_error = "Username and password cannot be empty!"
      return false
    end
    pairs = Array.new
    pairs.push(Array.new(2) { |i| i == 0 ? "username" : uname })
    pairs.push(Array.new(2) { |i| i == 0 ? "password" : p.to_s })
    raw = ChangedMP.request(:post, ChangedMP.server_url + path, json_kv(pairs)).to_s
    if raw.empty?
      @last_error = "Server waking up, try again!"
      return false
    end
    unless raw.include?("ok") || raw.include?("true")
      err = extract_str(raw, "error")
      @last_error = err.empty? ? "Invalid username or password!" : err
      return false
    end
    tok = extract_str(raw, "token")
    role = extract_str(raw, "role")
    role = "player" if role.empty?
    return false if tok.empty?
    ChangedMP.save_auth(uname, tok, role)
    true
  rescue Exception => e
    @last_error = "Auth error: " + e.message.to_s
    false
  end
end

module ChangedMP
  class << self
    def login(u, p); ChangedMP_Auth.call("/api/login", u, p); end
    def register(u, p); ChangedMP_Auth.call("/api/register", u, p); end
  end
end
