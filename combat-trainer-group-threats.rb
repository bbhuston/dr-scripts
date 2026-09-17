# frozen_string_literal: true
require 'cgi'

# A complete, single-command ASSESS frame can exclude a peer's opponents from
# the supervised group's personal retreat count and provide server ordinals
# for corpse-safe targeting. Retreat thresholds and room NPC census stay intact.
class CombatTrainerGroupThreats
  MEMBERS = %w[lanjefast thargrund vrakk].freeze
  HEADER = /<pushStream id=["']assess["']\/><clearStream id=["']assess["']\/>You assess your combat situation\.\.\./
  PROMPT = /<prompt\b[^>]*>[^<]*<\/prompt>/
  SEGMENT = /<pushStream id=["']assess["']\/>(.*?)<popStream\/>/m
  RELATION = 'moving to flank|moving behind|flanking|facing|behind|advancing on'
  ROW = /\A(?<name>.+?) \((?:(?<number>\d+): )?(?<status>[^)]*)\) (?:is|are) (?<relation>#{RELATION}) (?<target>.+?) at (?<range>melee|pole weapon|missile) range\.(?:\s+\| F)?\z/
  NOTE = /\A(?:You appear to be having difficulty targeting melee and ranged attacks\.|\(You are also defending against .+\.\))\z/

  class Frame
    attr_reader :text

    def initialize
      @text = +''
      @done = false
      @invalid = false
      @lock = Mutex.new
    end

    def feed(raw)
      @lock.synchronize do
        return if @done

        @text << raw.to_s
        @invalid = true if @text.bytesize > 65_536
        # Combat, group and other ambient output can finish with a prompt
        # before this command's ASSESS response begins. Neither acknowledge
        # nor reject the command until its header arrives; the caller retains
        # the same bounded deadline and producer/write-boundary checks.
        if (header = @text.match(HEADER))
          @text = @text[header.begin(0)..]
          if (prompt = @text.match(PROMPT))
            @text = @text[0...prompt.end(0)]
            @done = true
          end
        end
        @done = true if @invalid
      end
    end

    def invalidate!
      @lock.synchronize { @invalid = @done = true }
    end

    def finished?
      @lock.synchronize { @done }
    end

    def complete_text
      @lock.synchronize { @text.dup if @done && !@invalid }
    end
  end

  def self.entries(frame, before, after, complete: true)
    return nil unless frame && before && before == after
    return nil unless before[:room] && before[:self] &&
                      MEMBERS.include?(before[:self]) &&
                      before[:visible].is_a?(Array) &&
                      (before[:visible] - (MEMBERS - [before[:self]])).empty?
    return nil unless frame.scan(HEADER).length == 1 && frame.scan(PROMPT).length == 1

    # ASSESS consists only of complete stream segments, followed by its prompt.
    # Unknown raw content, a truncated row, or any intervening room update is
    # not a complete attribution census, even if cached entries look plausible.
    remainder = frame.gsub(SEGMENT, '').sub(PROMPT, '')
    return nil unless remainder.strip.empty?

    entries = []
    frame.scan(SEGMENT).flatten.each do |raw|
      return nil if raw.match?(/<(?:pushStream|popStream)\b/)

      text = CGI.unescapeHTML(raw.gsub(/<[^>]*>/, '')).strip.gsub(/\s+/, ' ')
      next if text.empty? || text == 'You assess your combat situation...' || text.match?(NOTE)

      match = text.match(ROW)
      return nil unless match

      ids = raw.scan(/<d cmd=["']look #(-?\d+)["']>/).flatten
      name = match[:name].downcase
      target = match[:target].sub(/ \(\d+\)\z/, '').downcase
      self_row = name == 'you'
      subject = self_row ? nil : ids.shift
      target_id = ids.shift
      return nil unless ids.empty? && (self_row || subject&.match?(/\A-?[1-9]\d*\z/))
      return nil unless target == 'you' ? target_id.nil? : target_id&.match?(/\A-?[1-9]\d*\z/)

      entries << { name: name, id: subject, target: target, target_id: target_id, self: self_row, range: match[:range] }
    end
    creatures = entries.select { |entry| !entry[:self] && !entry[:id].start_with?('-') }
    peers = entries.select { |entry| !entry[:self] && entry[:id].start_with?('-') }
    observed_ids = creatures.map { |entry| entry[:id] }
    return nil unless before[:ids].is_a?(Array) && before[:ids].uniq.length == before[:ids].length &&
                      before[:ids].all? { |id| id.match?(/\A[1-9]\d*\z/) }
    return nil unless observed_ids.uniq.length == observed_ids.length && (observed_ids - before[:ids]).empty?
    return nil if complete && observed_ids.sort != before[:ids]
    # Room XML may register IDs without names when corpse/live counts differ.
    # Corroborate names from this completed authoritative ASSESS, never require
    # a cached name before sending the command that can supply it.
    return nil unless before[:npcs].is_a?(Array) && before[:npcs].length == before[:ids].length
    observed_nouns = creatures.map { |entry| entry[:name].split.last }.tally
    room_nouns = before[:npcs].map { |name| name.split.last.downcase }.tally
    return nil unless observed_nouns.all? { |noun, count| count <= room_nouns.fetch(noun, 0) }
    return nil if complete && observed_nouns != room_nouns
    return nil unless (peers.map { |entry| entry[:name] } - (MEMBERS - [before[:self]])).empty?
    return nil unless peers.map { |entry| entry[:id] }.uniq.length == peers.length
    return nil unless peers.map { |entry| entry[:name] }.uniq.length == peers.length
    return nil unless entries.count { |entry| entry[:self] } <= 1

    { creatures: creatures, peers: peers, self: entries.find { |entry| entry[:self] } }
  rescue StandardError
    nil
  end

  def self.count(frame, before, after)
    return nil unless before && before[:group].is_a?(Hash) &&
                      before[:group][:names] == MEMBERS && before[:group][:room] == before[:room]

    parsed = entries(frame, before, after, complete: false)
    return nil unless parsed

    # Individual target proof never supplies peer exclusions. Only a separate,
    # complete current group proof can authorize this shared threat count.
    creatures, peers = parsed.values_at(:creatures, :peers)
    excluded = creatures.count do |creature|
      peer = peers.find { |entry| entry[:id] == creature[:target_id] }
      peer && peer[:name] == creature[:target] && before[:visible].include?(peer[:name])
    end
    # ASSESS omits idle creatures. Every current room creature remains a
    # threat unless this fresh frame positively proves a visible peer target.
    before[:ids].length - excluded
  rescue StandardError
    nil
  end
  # Prefer an opponent already within this character's melee, preserving the
  # server identity and noun-relative ordinal from the same complete frame.
  def self.personal_melee_selector(frame, before, after)
    parsed = entries(frame, before, after, complete: false)
    return nil unless parsed
    rows = parsed[:creatures]
    own = parsed[:self]
    own = nil unless own && own[:range] == 'melee'
    creature = rows.find { |row| !row[:self] && row[:id] == own&.dig(:target_id) && before[:ids].include?(row[:id]) }
    creature ||= rows.find { |row| !row[:self] && row[:target] == 'you' && row[:range] == 'melee' && before[:ids].include?(row[:id]) }
    return nil unless creature

    frame.scan(SEGMENT).flatten.each do |raw|
      next unless raw[/<d cmd=["']look #([1-9]\d*)["']>/, 1] == creature[:id]
      row = CGI.unescapeHTML(raw.gsub(/<[^>]*>/, '')).strip.gsub(/\s+/, ' ').match(ROW)
      next unless row && row[:name].downcase == creature[:name]
      number = row[:number].to_i
      return nil unless number.between?(1, ORDINALS.length)
      noun = creature[:name].split.last
      return [creature[:id], "##{creature[:id]}", noun]
    end
    nil
  rescue StandardError
    nil
  end

  ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth].freeze

  def self.selector(frame, before, after, target)
    return nil unless entries(frame, before, after)

    noun = target.to_s.split.last
    return nil unless noun&.match?(/\A[a-zA-Z][a-zA-Z'-]*\z/)

    frame.scan(SEGMENT).flatten.each do |raw|
      text = CGI.unescapeHTML(raw.gsub(/<[^>]*>/, '')).strip.gsub(/\s+/, ' ')
      row = text.match(ROW)
      next unless row && row[:name].split.last.casecmp?(noun)

      id = raw[/<d cmd=["']look #([1-9]\d*)["']>/, 1]
      next unless id && before[:ids].include?(id)

      number = row[:number].to_i
      return nil unless number.between?(1, ORDINALS.length)

      selector = number == 1 ? noun : "#{ORDINALS[number - 1]} #{noun}"
      return [id, selector]
    end
    nil
  rescue StandardError
    nil
  end

end
