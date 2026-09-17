# frozen_string_literal: true

# State and classification only. The caller owns single-send, fresh complete
# response framing. No transcript string can prove transport causality by itself.
class CombatTrainerAnalyzeSequence
  VERBS = %w[jab slam feint swing slice chop thrust lunge sweep draw bash punch kick elbow knee claw bite butt gouge pummel].freeze
  UNSUPPORTED = /You (?:can not|cannot|can't) \w+ with that|Wouldn't it be better if you used a melee weapon|You need two hands to wield this weapon|You need to hold/i
  ROUND_TIME = /\A(?:Roundtime(?:\s*:|\s+\d)|\[Roundtime\s+\d+\s+sec\.\]\z)/i

  attr_reader :target, :target_id, :selector, :deadline

  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                 max_misses: 2, window: 30.0, strike_budget: 5.0, cooldown: 30.0)
    raise ArgumentError, 'invalid sequence bounds' unless max_misses.is_a?(Integer) && max_misses >= 1 &&
                                                        [window, strike_budget, cooldown].all? { |n| n.is_a?(Numeric) && n.finite? && n.positive? }

    @clock, @max_misses, @window, @strike_budget, @cooldown = clock, max_misses, window, strike_budget, cooldown
    @steps = []
    @resets = 0
    @misses = 0
    @stopped = false
    @reset_pending = false
    @cooldown_until = 0.0
    @attempt = nil
  end

  def active?
    !@stopped && !@steps.empty?
  end

  def remaining
    @steps.length
  end

  def reset_pending?
    @reset_pending
  end

  def capturing_allowed?
    !@stopped && now >= @cooldown_until && (!active? || @reset_pending) && @attempt.nil?
  end

  def capture(lines, context:, kind: :enemy)
    return false unless kind == :enemy && capturing_allowed?

    frame = text_lines(lines)
    normalized_context = snapshot(context)
    started = normalized_context&.delete('analyze_started_at')
    headers = frame.filter_map do |line|
      match = line.match(/\A(?:You reveal .+|Your analysis reveals .+) in (.+?)'s defenses?\.\z/i)
      noun(match[1]) if match
    end
    matches = normalized_context && headers.length == 1 ? normalized_context['roster'].select { |entry| target_matches?(headers.first, entry) } : []
    recipes = frame.filter_map { |line| line.match(/\bby landing an? (.+)\.\z/i)&.[](1) }
    id_bound = normalized_context && normalized_context['selector'] == "##{normalized_context['target_id']}"
    target_valid = if id_bound
                     expected = normalized_context['target_noun']
                     expected.is_a?(String) && !matches.empty? && target_matches?(headers.first, expected)
                   else
                     matches.length == 1 &&
                       (!normalized_context['selector'] || normalized_context['selector'] == matches.first)
                   end
    if !complete?(frame) || !normalized_context || headers.length != 1 || recipes.length != 1 ||
       !target_valid ||
       (@reset_pending && normalized_context != @context)
      abandon!
      return false
    end

    steps = recipes.first.split(/\s*,\s*(?:and\s+)?|\s+and\s+/i).map { |part| noun(part) }
    unless (2..4).cover?(steps.length) && steps.all? { |step| VERBS.include?(step) }
      abandon!
      return false
    end

    @resets = 0 unless @reset_pending
    @reset_pending = false
    @context = normalized_context
    @target = headers.first
    @target_id = normalized_context['target_id']
    @selector = normalized_context['selector'] || matches.first
    @steps = steps
    @misses = 0
    @attempt = nil
    # Caller may include conservative ANALYZE send time, not response receipt.
    started = now unless started.is_a?(Numeric) && started.finite? && started <= now
    @deadline = started + @window
    true
  end

  def needs_reset?(context:)
    return false unless matching_context?(context)
    return true if @reset_pending
    return false unless active? && @attempt.nil? && !enough_time?

    if @resets >= 1
      abandon!
      return false
    end
    @resets += 1
    @reset_pending = true
    @steps = []
    @attempt = nil
    true
  end

  def next_verb(context:)
    return nil unless matching_context?(context) && active? && @attempt.nil? && enough_time?

    @steps.first
  end

  def begin_attempt(command:, context:)
    verb = next_verb(context: context)
    return nil unless verb

    # Native dispatch uses a bare verb or the fresh observed selector.
    allowed = /\A#{Regexp.escape(verb)}(?: #{Regexp.escape(@selector)})?\z/i
    unless command.is_a?(String) && command.match?(allowed)
      abandon!
      return nil
    end
    token = Object.new.freeze
    @attempt = { token: token, verb: verb }
    token
  end

  def resolve(token, lines:, context:)
    # Stale or replayed tokens cannot alter a later sequence.
    return :unknown unless @attempt && @attempt[:token].equal?(token)
    return :unknown unless matching_context?(context)

    expected = @attempt[:verb]
    @attempt = nil
    frame = text_lines(lines)
    if frame.any? { |line| line.match?(UNSUPPORTED) }
      abandon!
      return :unsupported
    end
    unless active? && now < @deadline && complete?(frame)
      abandon!
      return :unknown
    end

    attacks = frame.filter_map { |line| own_attack(line) }
    if attacks.length != 1 || attacks.first[:verb] != expected ||
       noun(attacks.first[:weapon]) != @context['weapon'] || noun(attacks.first[:target]) != @target
      abandon!
      return :unknown
    end

    attack = attacks.first
    short_weapon = @context['weapon'].split.last
    landed = attack[:resolution].match?(/\bThe #{Regexp.escape(short_weapon)} lands an?\s/i)
    if landed
      @steps.shift
      @misses = 0
      :landed
    elsif attack[:resolution].match?(/\b(?:dodges|evades|parries|blocks|knocks aside|turns aside|deflects|avoids|misses|failing to heft)\b/i)
      @misses += 1
      abandon! if @misses >= @max_misses
      :missed
    else
      abandon!
      :unknown
    end
  end

  def abandon!
    @steps = []
    @attempt = nil
    @reset_pending = false
    @target = nil
    @target_id = nil
    @selector = nil
    @context = nil
    @deadline = nil
    @misses = 0
    @cooldown_until = now + @cooldown
    nil
  end

  def stop!
    abandon!
    @stopped = true
    nil
  end

  private

  def now
    @clock.call
  end

  def enough_time?
    @deadline && @deadline - now > @steps.length * @strike_budget
  end

  def matching_context?(context)
    return false if @stopped || @context.nil?

    current = snapshot(context)
    current&.delete('analyze_started_at')
    return true if current == @context

    abandon!
    false
  end

  def snapshot(context)
    return nil unless context.is_a?(Hash)

    value = plain_copy(context)
    return nil unless value['room'] && value['roster'].is_a?(Array) && value['roster'].all? { |n| n.is_a?(String) } &&
                      value['weapon'].is_a?(String) && !noun(value['weapon']).empty? &&
                      value['target_id'].is_a?(String) && value['target_id'].match?(/\A[1-9]\d*\z/) &&
                      value['live_ids'].is_a?(Array) && value['live_ids'].all? { |id| id.is_a?(String) && id.match?(/\A[1-9]\d*\z/) } &&
                      value['live_ids'].uniq.length == value['live_ids'].length && value['live_ids'].include?(value['target_id']) &&
                      value['room_generation'].is_a?(Integer)

    value['weapon'] = noun(value['weapon'])
    value
  rescue ArgumentError
    nil
  end

  def plain_copy(value)
    case value
    when Hash
      value.to_h { |key, item| [key.to_s, plain_copy(item)] }
    when Array
      value.map { |item| plain_copy(item) }
    when String
      value.dup
    when Symbol
      value.to_s
    when Numeric, NilClass, TrueClass, FalseClass
      value
    else
      raise ArgumentError, 'context must contain plain values'
    end
  end

  def noun(text)
    text.strip.downcase.sub(/\A(?:a|an|the)\s+/, '')
  end

  def roster_noun(text)
    noun(text).sub(/\A(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth)\s+/, '')
  end

  def target_matches?(header, entry)
    observed = roster_noun(entry)
    header == observed || header.end_with?(" #{observed}")
  end

  def text_lines(lines)
    Array(lines).flat_map { |line| line.to_s.lines.map(&:strip) }.reject(&:empty?)
  end

  def complete?(frame)
    frame.last&.match?(ROUND_TIME) && frame.count { |line| line.match?(ROUND_TIME) } == 1
  end

  def own_attack(line)
    # Own attacks use '< ... you VERB WEAPON at TARGET. ...'; hostile '*'
    # and other-player frames must never contribute a landing marker.
    line.match(/\A<\s*(?:[^<>*]*,\s*)?you (?<verb>[a-z]+) (?<weapon>.+?) at (?<target>.+?)(?:\.\s+|\s{2,})(?<resolution>.+)\z/i)
  end
end
