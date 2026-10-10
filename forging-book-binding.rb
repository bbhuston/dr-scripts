# frozen_string_literal: true

# Opt-in individual book selection. Generic book names cannot distinguish two
# owned instruction tiers. Every binding uses a fresh complete native inventory search.
module ForgingBookBinding
  class Error < StandardError; end
  DISCIPLINES = %w[blacksmithing weaponsmithing armorsmithing].freeze unless const_defined?(:DISCIPLINES, false)
  TOKEN = /\Abook=([1-9]\d*):([1-9]\d*):journeyman:(blacksmithing|weaponsmithing|armorsmithing)\z/.freeze unless const_defined?(:TOKEN, false)
  POLLS = 30 unless const_defined?(:POLLS, false)

  def self.tier(settings, discipline)
    tiers = settings.forging_book_tiers
    return nil if tiers.nil?

    unless tiers.is_a?(Hash) && !tiers.empty? && tiers.all? { |key, value| DISCIPLINES.include?(key) && value == 'journeyman' }
      raise Error, 'Invalid explicit forging book tiers'
    end
    tiers[discipline]
  end

  def self.valid?(object, discipline, id = nil)
    return false unless object && DISCIPLINES.include?(discipline)

    # Native held XML uses the generic discipline name even when the GET prose
    # identifies a journeyman copy. Never manufacture a tier in GameObj.name.
    names = ["#{discipline} book", "journeyman #{discipline} book", "book of journeyman #{discipline} instructions"]
    object.id.to_s.match?(/\A[1-9]\d*\z/) && object.noun.to_s == 'book' &&
      names.include?(object.name.to_s) && (id.nil? || object.id.to_s == id.to_s)
  end

  def self.held?(id, discipline)
    [GameObj.left_hand, GameObj.right_hand].compact.any? { |object| valid?(object, discipline, id) }
  end

  def self.poll
    POLLS.times do
      return true if yield

      pause 0.1
    end
    false
  end

  class SearchFrame
    attr_reader :entries

    def initialize
      @started = false
      @complete = false
      @invalid = false
      @entries = []
    end

    def feed(raw)
      raw.to_s.each_line do |line|
        line = line.strip
        # Native inventory search can put its roundTime tag on the header line.
        # Recognize only that exact optional tag; never strip arbitrary XML.
        if line.match?(/\A(?:<roundTime value=(["'])\d+\1\/>)?You rummage about your person, looking for book\.\.\.\z/)
          @invalid = true if @started
          @started = true
        elsif @started && !@complete && line.start_with?('<d cmd=')
          unless line.match?(/\A<d\b[^>]*>[^<]*<\/d>/)
            @invalid = true
            next
          end
          handler = Lich::DragonRealms::DRParser::InventoryItemSax.new
          Ox.sax_parse(handler, line, convert_special: false, symbolize: false, skip: :skip_none)
          command = handler.cmd.to_s.match(/\Aget #([1-9]\d*) in #([1-9]\d*)\z/)
          name = Lich::Common::XmlEntities.decode(handler.name.to_s).sub(/\A(?:a|an|some)\s/i, '').strip
          @entries << { id: command[1], container: command[2], name: name } if command
          @invalid = true unless command || (handler.cmd.to_s.match?(/\Aget #[1-9]\d*(?: in .+)?\z/) && !name.match?(/\Abook of (?:apprentice|journeyman|master) (?:blacksmithing|weaponsmithing|armorsmithing) instructions\z/))
        elsif @started && line.match?(/\A<output class=["']["']\/>/)
          @complete = true
        end
      end
    rescue StandardError
      @invalid = true
    end

    def complete?
      @started && @complete && !@invalid
    end
  end

  def self.search
    frame = SearchFrame.new
    hook = "forging-book-#{Thread.current.object_id}"
    waitrt?
    DownstreamHook.add(hook, proc { |raw| frame.feed(raw); raw }, persist: false)
    DRC.bput('inv search book', { 'timeout' => 3, 'ignore_rt' => true }, /You rummage about your person/, /You can't seem to find anything/)
    raise Error, 'Fresh complete instruction-book inventory search was not confirmed' unless poll { frame.complete? }

    frame.entries
  ensure
    DownstreamHook.remove(hook) if hook
  end

  def self.selected(entries, discipline)
    name = "book of journeyman #{discipline} instructions"
    matches = entries.select { |entry| entry[:name] == name }
    unless matches.length == 1 && entries.count { |entry| entry[:id] == matches.first[:id] } == 1
      raise Error, 'Selected instruction-book tier is missing, duplicated or ambiguous'
    end
    matches.first
  end

  def self.retrieve(settings, discipline, id)
    unless [GameObj.left_hand, GameObj.right_hand].all? { |object| object.nil? || (object.id.nil? && object.noun.nil? && object.name.to_s == 'Empty') }
      raise Error, 'Hands must be empty before retrieving an instruction book'
    end
    descriptor = /You get (?:a|your) book of (apprentice|journeyman|master) #{Regexp.escape(discipline)} instructions\b/
    result = DRC.bput("get ##{id} from my #{settings.crafting_container}", { 'timeout' => 3 },
                      descriptor, /You get/, /You are already holding/, /I could not find/, /You can't/)
    native_tier = result.to_s.match(descriptor)
    raise Error, 'Exact instruction book or its native tier was not confirmed' unless native_tier && poll { held?(id, discipline) }

    native_tier[1]
  end

  def self.stow(settings, binding)
    token = TOKEN.match(binding.to_s)
    raise Error, 'Invalid instruction-book binding' unless token && held?(token[1], token[3])

    DRC.bput("put ##{token[1]} in my #{settings.crafting_container}", { 'timeout' => 3 }, /You put/, /You stow/, /I could not find/, /You can't/)
    clear = poll { [GameObj.left_hand, GameObj.right_hand].compact.none? { |object| object.id.to_s == token[1] } }
    raise Error, 'Instruction book was not stowed' unless clear
    owned = selected(search, token[3])
    raise Error, 'Exact instruction book custody was not confirmed after stow' unless owned[:id] == token[1] && owned[:container] == token[2]

    true
  end

  def self.get(settings, discipline, expected = nil)
    raise Error, 'Explicit journeyman tier is not selected' unless tier(settings, discipline) == 'journeyman'
    raise Error, 'Individual book binding cannot use a master crafting book' if settings.master_crafting_book
    unless settings.crafting_container.is_a?(String) && settings.crafting_container.match?(/\A[\w -]+\z/)
      raise Error, 'Missing or invalid crafting container'
    end
    owned = selected(search, discipline)
    id = owned[:id]
    if expected
      token = TOKEN.match(expected.to_s)
      raise Error, 'Selected instruction book does not match the preflight binding' unless token && token[1] == id && token[2] == owned[:container] && token[3] == discipline
    end
    # Exact GET from the configured owned container must return the full native
    # tier descriptor, followed by raw hand ID/discipline/noun verification.
    raise Error, 'Selected instruction-book tier was not confirmed at retrieval' unless retrieve(settings, discipline, id) == 'journeyman'

    "book=#{id}:#{owned[:container]}:journeyman:#{discipline}"
  end

  # Set only after all methods loaded. Existing Error and unchanged constants
  # retain their identity during the one-time resident-process correction.
  remove_const(:VERSION) if const_defined?(:VERSION, false)
  VERSION = 2
end
