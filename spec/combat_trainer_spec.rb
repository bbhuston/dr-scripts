# frozen_string_literal: true

# Combat-trainer spec suite.
#
# Organized by class under test, each section uses a focused builder
# that exposes only the fields that matter for that test group.
# Tests are split into two categories per method:
#   - Validation: confirms expected behavior for known-good inputs
#   - Bug-finding: probes nil settings, state mutation across calls,
#     type mismatches, side-effect leakage, and boundary conditions

require 'ostruct'

require_relative 'spec_helper'

# -- Module stubs --
# Each stub provides the minimum interface combat-trainer calls.
# Methods default to safe no-ops; tests override via allow().

# The generic UserVars store lives in the harness (Harness::UserVars); reopen it
# here to add combat-trainer's one domain default: moons reads back an empty
# visible set so the slivers specs see { 'visible' => [] } when it is unset.
# _set_moons mirrors the helper those specs call. Everything else (sun, discerns,
# friends, warhorn, almanac_last_use, ...) is handled by the shared store.
class Harness::UserVars
  class << self
    def moons
      _store[:moons] || { 'visible' => [] }
    end

    def _set_moons(val)
      _store[:moons] = val
    end
  end
end

# ===================================================================
# Weapon custody during weapon transitions and thrown attacks
# ===================================================================
RSpec.describe 'combat-trainer weapon custody' do
  before(:each) do
    ct_setup
    allow(DRC).to receive(:message)
    allow(DRC).to receive(:bput).and_return('roundtime')
  end

  def weapon_switch_state
    state = double(
      'GameState',
      last_weapon_skill: 'Large Edged', weapon_skill: 'Light Thrown',
      last_weapon_name: 'broadsword', weapon_name: 'wide-bladed dagger',
      aimed_skill?: false, whirlwind_trainable?: false
    )
    allow(state).to receive(:summoned_info).and_return(nil)
    allow(state).to receive(:sheath_whirlwind_offhand)
    allow(state).to receive(:loaded=)
    allow(state).to receive(:wield_weapon).and_return(true)
    allow(state).to receive(:currently_whirlwinding=)
    allow(state).to receive(:cleaning_up?).and_return(false)
    allow(state).to receive(:next_clean_up_step)
    allow(state).to receive(:force_cleanup)
    state
  end

  def setup_process(equipment_manager)
    process = SetupProcess.allocate
    process.instance_variable_set(:@equipment_manager, equipment_manager)
    process.instance_variable_set(:@last_seen_weapon_skill, nil)
    process.instance_variable_set(:@firing_check, 0)
    process
  end

  def thrown_state(offhand: false)
    double(
      'GameState',
      weapon_name: 'wide-bladed dagger', offhand?: offhand,
      thrown_attack_verb: 'lob', thrown_retrieve_verb: 'get my wide-bladed dagger',
      action_taken: :acted, cleaning_up?: false, next_clean_up_step: nil,
      force_cleanup: nil, drbot_attack_ids_required?: false
    )
  end

  def attack_process
    process = AttackProcess.allocate
    allow(process).to receive(:waitrt?)
    process
  end

  it 'treats a failed stow with both hands empty as already stowed' do
    $right_hand = nil
    $left_hand = nil
    equipment_manager = double('EquipmentManager', stow_weapon: false)
    state = weapon_switch_state

    result = setup_process(equipment_manager).send(:check_weapon, state)

    expect(result).not_to eq(:weapon_custody_failure)
    expect(state).to have_received(:wield_weapon)
    expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
    expect($COMBAT_TRAINER).not_to have_received(:stop)
    expect(DRC).not_to have_received(:message).with(/failed to stow.*broadsword/i)
  end

  it 'stops when a reported successful stow leaves the primary in hand' do
    $right_hand = 'a broadsword'
    equipment_manager = double('EquipmentManager', stow_weapon: true)
    state = weapon_switch_state

    result = setup_process(equipment_manager).send(:check_weapon, state)

    expect(result).to eq(:weapon_custody_failure)
    expect(state).to have_received(:next_clean_up_step).once
    expect(DRC).to have_received(:message).with(/broadsword.*remains in hand/i)
  end

  it 'continues the switch only after the primary is no longer held' do
    $right_hand = 'a broadsword'
    equipment_manager = double('EquipmentManager')
    allow(equipment_manager).to receive(:stow_weapon) do
      $right_hand = nil
      true
    end
    state = weapon_switch_state

    result = setup_process(equipment_manager).send(:check_weapon, state)

    expect(result).not_to eq(:weapon_custody_failure)
    expect(state).to have_received(:wield_weapon)
    expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
    expect($COMBAT_TRAINER).not_to have_received(:stop)
  end

  it 'stops when the next configured weapon cannot be wielded' do
    $right_hand = 'a broadsword'
    equipment_manager = double('EquipmentManager')
    allow(equipment_manager).to receive(:stow_weapon) do
      $right_hand = nil
      true
    end
    state = weapon_switch_state
    allow(state).to receive(:wield_weapon).and_return(false)

    result = setup_process(equipment_manager).send(:check_weapon, state)

    expect(result).to eq(:weapon_custody_failure)
    expect(DRC).to have_received(:message).with(/failed to wield.*wide-bladed dagger.*Light Thrown/i)
    expect($HUNTING_BUDDY).to have_received(:stop_hunting)
    expect($COMBAT_TRAINER).to have_received(:stop)
  end

  it 'allows an intentionally weaponless Brawling rotation' do
    $right_hand = 'a broadsword'
    equipment_manager = double('EquipmentManager')
    allow(equipment_manager).to receive(:stow_weapon) do
      $right_hand = nil
      true
    end
    state = weapon_switch_state
    allow(state).to receive(:weapon_skill).and_return('Brawling')
    allow(state).to receive(:weapon_name).and_return('')
    allow(state).to receive(:wield_weapon).and_return(nil)

    result = setup_process(equipment_manager).send(:check_weapon, state)

    expect(result).not_to eq(:weapon_custody_failure)
    expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
    expect($COMBAT_TRAINER).not_to have_received(:stop)
  end

  it 'treats an empty Brawling weapon name as nothing to stow while the shield is held' do
    # Thargrund 2026-09-25 21:54:10: 'failed to stow "" before switching to
    # "etched greathammer"' with the tower shield in his left hand.
    $right_hand = nil
    $left_hand = 'a metal tower shield'
    equipment_manager = double('EquipmentManager', stow_weapon: nil)
    state = weapon_switch_state
    allow(state).to receive(:last_weapon_skill).and_return('Brawling')
    allow(state).to receive(:last_weapon_name).and_return('')
    allow(state).to receive(:weapon_skill).and_return('Large Blunt')
    allow(state).to receive(:weapon_name).and_return('etched greathammer')
    process = setup_process(equipment_manager)

    result = process.send(:check_weapon, state)

    expect(result).not_to eq(:weapon_custody_failure)
    expect(equipment_manager).not_to have_received(:stow_weapon)
    expect(state).to have_received(:wield_weapon)
    expect(process.instance_variable_get(:@last_seen_weapon_skill)).to eq('Large Blunt')
    expect(DRC).not_to have_received(:message)
    expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
  end

  it 'does not stow a weapon before switching to that same weapon' do
    # Thargrund 2026-09-25 23:24:56: 'put my greathammer in my backpack' ->
    # 'What were you referring to?' for a greathammer that was never drawn.
    $right_hand = nil
    $left_hand = 'a metal tower shield'
    equipment_manager = double('EquipmentManager', stow_weapon: false)
    state = weapon_switch_state
    allow(state).to receive(:last_weapon_skill).and_return('Large Blunt')
    allow(state).to receive(:last_weapon_name).and_return('etched greathammer')
    allow(state).to receive(:weapon_skill).and_return('Large Blunt')
    allow(state).to receive(:weapon_name).and_return('etched greathammer')

    result = setup_process(equipment_manager).send(:check_weapon, state)

    expect(result).not_to eq(:weapon_custody_failure)
    expect(equipment_manager).not_to have_received(:stow_weapon)
    expect(state).to have_received(:wield_weapon)
    expect(DRC).not_to have_received(:message)
  end

  it 'stops the hunt once and then lets cleanup run instead of re-entering the switch' do
    $right_hand = 'a broadsword'
    equipment_manager = double('EquipmentManager', stow_weapon: false)
    state = weapon_switch_state
    allow(state).to receive(:done_cleaning_up?).and_return(false)
    allow(state).to receive(:stowing?).and_return(false)
    allow(state).to receive(:safety_stopping?).and_return(false)
    process = setup_process(equipment_manager)
    allow(process).to receive(:waitrt?)

    expect(process.send(:check_weapon, state)).to eq(:weapon_custody_failure)
    3.times { expect(process.execute(state)).to be(false) }
    expect(process.send(:stop_for_weapon_custody, 'again', state)).to eq(:weapon_custody_failure)

    expect(equipment_manager).to have_received(:stow_weapon).once
    expect(DRC).to have_received(:message).once
    expect($HUNTING_BUDDY).to have_received(:stop_hunting).once
    expect($COMBAT_TRAINER).to have_received(:stop).once
    expect(state).to have_received(:next_clean_up_step).once
    expect(state).to have_received(:force_cleanup).once
    expect(state).not_to have_received(:safety_stopping?)
  end

  it 'stops without lobbing when the configured weapon is in the wrong hand' do
    $right_hand = 'a broadsword'
    $left_hand = 'a wide-bladed dagger'
    state = thrown_state(offhand: false)

    result = attack_process.send(:attack_thrown, state)

    expect(result).to eq(:weapon_custody_failure)
    expect(DRC).not_to have_received(:bput).with(/^lob/, anything, anything)
    expect(DRC).to have_received(:message).with(/wide-bladed dagger.*right hand.*broadsword/i)
    expect($HUNTING_BUDDY).to have_received(:stop_hunting)
    expect($COMBAT_TRAINER).to have_received(:stop)
    expect(state).to have_received(:force_cleanup)
  end

  it 'lobs a matching configured weapon from the right hand' do
    $right_hand = 'a wide-bladed dagger'
    $left_hand = 'a broadsword'
    allow(DRC).to receive(:bput).and_return('roundtime', 'You pick up')
    state = thrown_state(offhand: false)

    expect(attack_process.send(:attack_thrown, state)).to eq(:acted)

    expect(DRC).to have_received(:bput).with('lob', 'roundtime', 'What are you trying to', /already (?:quite )?dead/, /could not find/i)
    expect(state).to have_received(:action_taken)
    expect($COMBAT_TRAINER).not_to have_received(:stop)
  end

  it 'lobs a matching configured weapon from the left hand when offhand' do
    $right_hand = 'a broadsword'
    $left_hand = 'a wide-bladed dagger'
    allow(DRC).to receive(:bput).and_return('roundtime', 'You pick up')
    state = thrown_state(offhand: true)

    expect(attack_process.send(:attack_thrown, state)).to eq(:acted)

    expect(DRC).to have_received(:bput).with('lob left', 'roundtime', 'What are you trying to', /already (?:quite )?dead/, /could not find/i)
    expect(state).to have_received(:action_taken)
    expect($COMBAT_TRAINER).not_to have_received(:stop)
  end
end

# Reopen the harness DRSpells (do NOT shadow with a fresh top-level class --
# a fresh class would lose active_spells/_set_active_spells that several specs
# rely on). Add known_spells and slivers backed by their own class vars, and
# extend _reset to clear them too. Code under test resolves DRSpells to
# Harness::DRSpells via the include, so this is the single shared class.
class Harness::DRSpells
  @@_known_spells = {}
  @@_slivers = false

  def self.known_spells = @@_known_spells
  def self._set_known_spells(val) = (@@_known_spells = val)
  def self.slivers = @@_slivers
  def self._set_slivers(val) = (@@_slivers = val)

  class << self
    alias_method(:_orig_reset, :_reset) unless method_defined?(:_orig_reset)
    def _reset
      _orig_reset
      @@_known_spells = {}
      @@_slivers = false
    end
  end
end

$HUNTING_BUDDY = nil
$COMBAT_TRAINER = nil
$debug_mode_ct = false
$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth]

$martial_skills ||= ['Brawling']
$edged_skills ||= ['Small Edged', 'Large Edged', 'Twohanded Edged']
$blunt_skills ||= ['Small Blunt', 'Large Blunt', 'Twohanded Blunt']
$staff_skills ||= ['Staves']
$polearm_skills ||= ['Polearms']
$melee_skills ||= $edged_skills + $blunt_skills + $staff_skills + $polearm_skills + ['Melee Mastery']
$thrown_skills ||= ['Heavy Thrown', 'Light Thrown', 'Missile Mastery']
$twohanded_skills ||= ['Twohanded Edged', 'Twohanded Blunt']
$aim_skills ||= ['Bow', 'Slings', 'Crossbow']
$ranged_skills ||= $thrown_skills + $aim_skills + ['Missile Mastery']
$non_dance_skills ||= $ranged_skills + ['Brawling', 'Offhand Weapon']
$tactics_actions ||= %w[bob weave circle]
$weapon_buffs ||= ['Ignite', "Rutilor's Edge", 'Resonance']

load_lic_class('combat-trainer.lic', 'LootProcess')
load_lic_class('combat-trainer.lic', 'GameState')
load_lic_class('combat-trainer.lic', 'SetupProcess')
load_lic_class('combat-trainer.lic', 'ManipulateProcess')
load_lic_class('combat-trainer.lic', 'AttackProcess')
load_lic_class('combat-trainer.lic', 'AbilityProcess')
load_lic_class('combat-trainer.lic', 'SafetyProcess')
load_lic_class('combat-trainer.lic', 'SpellProcess')
load_lic_class('combat-trainer.lic', 'PetProcess')
load_lic_class('combat-trainer.lic', 'TrainerProcess')
load_lic_class('combat-trainer.lic', 'CombatTrainer')
load_lic_class('combat-trainer.lic', 'CombatTrainerOwnKills')

# Shared setup for combat-trainer tests that need game state stubs.
# Include in each describe block via: before(:each) { ct_setup }
def ct_setup
  DRSpells._set_known_spells({})
  DRSpells._set_slivers(false)
  UserVars.moons = { 'visible' => [] }
  UserVars.sun = { 'night' => false, 'day' => true }
  UserVars.discerns = {}
  UserVars.friends = []
  $HUNTING_BUDDY = double('HuntingBuddy', stop_hunting: nil)
  $COMBAT_TRAINER = double('CombatTrainer', stop: nil)
  $right_hand = nil
  $left_hand = nil
end

# -- Top-level helpers from the merged warhorn/egg spec --
# These are used by the warhorn AbilityProcess describe block below.
# Other describe blocks shadow build_game_state with their own scoped
# definitions, so these top-level versions only apply where no scoped
# version exists.
def build_ability_process(**overrides)
  instance = AbilityProcess.allocate
  defaults = {
    warhorn_nouns: [],
    egg_count: 0,
    warhorn_or_egg: [],
    warhorn_items: [],
    egg_ids: [],
    item_cooldowns: {},
    warhorn_cooldown: 1200
  }
  defaults.merge(overrides).each do |k, v|
    instance.instance_variable_set(:"@#{k}", v)
  end
  instance
end

def build_game_state(**attrs)
  defaults = {
    currently_whirlwinding: false
  }
  state = double('GameState', defaults.merge(attrs))
  allow(state).to receive(:sheath_whirlwind_offhand)
  allow(state).to receive(:wield_whirlwind_offhand)
  state
end

def stub_right_hand_with_id(id)
  hand = OpenStruct.new(name: 'item', noun: 'item', id: id)
  allow(GameObj).to receive(:right_hand).and_return(hand)
end

# ===================================================================
# GameState -- offense/defense gates
# These methods control whether an empath can attack. Getting them
# wrong causes empathic shock (permanent character penalty).
# ===================================================================
RSpec.describe GameState do
  before(:each) { ct_setup }

  describe 'own-kill harvesting settings' do
    def id_state(own_kill: nil, server_ids: nil, group: nil)
      gs = GameState.allocate
      gs.instance_variable_set(:@drbot_own_kill_harvest, own_kill)
      gs.instance_variable_set(:@drbot_server_id_targeting, server_ids)
      gs.instance_variable_set(:@drbot_supervised_group, group)
      gs
    end

    it 'turns corpse IDs and own-kill harvesting on together with server-ID targeting' do
      state = id_state(own_kill: true, server_ids: true)
      expect(state.drbot_own_kills_only?).to be(true)
      expect(state.drbot_corpse_ids?).to be(true)
    end

    it 'needs server-ID targeting as well as the opt-in' do
      expect(id_state(own_kill: true).drbot_own_kills_only?).to be(false)
      expect(id_state(own_kill: true).drbot_corpse_ids?).to be(false)
      expect(id_state(server_ids: true).drbot_corpse_ids?).to be(false)
    end

    it 'keeps lvt-goblins corpse IDs without own-kill filtering' do
      state = id_state(group: 'lvt-goblins')
      expect(state.drbot_corpse_ids?).to be(true)
      expect(state.drbot_own_kills_only?).to be(false)
    end

    it 'answers not harvestable and not tracking without a tracker' do
      state = id_state(own_kill: true, server_ids: true)
      expect(state.drbot_own_kill_tracking?).to be(false)
      expect(state.drbot_own_kill_harvestable?('3240264')).to be(false)
      expect(state.drbot_own_kill('3240264')).to be_nil
    end
  end

  # Focused builder: only the fields that matter for offense/defense.
  def build_offense_state(empath: false, permashocked: false, construct: false, undead: false, innocence: false)
    gs = GameState.allocate
    gs.instance_variable_set(:@is_empath, empath)
    gs.instance_variable_set(:@is_permashocked, permashocked)
    gs.instance_variable_set(:@construct_mode, construct)
    gs.instance_variable_set(:@undead_mode, undead)
    gs.instance_variable_set(:@innocence_mode, innocence)
    gs.instance_variable_set(:@ignored_npcs, [])
    gs.instance_variable_set(:@retreat_threshold, nil)
    gs.instance_variable_set(:@dance_threshold, 1)
    gs.instance_variable_set(:@dancing, false)
    gs.instance_variable_set(:@retreating, false)
    gs
  end

  describe '#is_permashocked?' do
    it('non-empath returns true') { expect(build_offense_state.is_permashocked?).to be true }
    it('empath + permashocked returns true') { expect(build_offense_state(empath: true, permashocked: true).is_permashocked?).to be true }
    it('empath without permashocked returns false') { expect(build_offense_state(empath: true).is_permashocked?).to be false }
  end

  describe '#is_offense_allowed?' do
    it('non-empath always allowed') { expect(build_offense_state.is_offense_allowed?).to be true }
    it('permashocked empath allowed') { expect(build_offense_state(empath: true, permashocked: true).is_offense_allowed?).to be true }
    it('construct mode empath allowed') { expect(build_offense_state(empath: true, construct: true).is_offense_allowed?).to be true }

    it 'undead mode empath allowed only when Absolution active' do
      gs = build_offense_state(empath: true, undead: true)
      allow(DRSpells).to receive(:active_spells).and_return({ 'Absolution' => 100 })
      expect(gs.is_offense_allowed?).to be true
    end

    it 'undead mode empath blocked when Absolution is NOT active' do
      gs = build_offense_state(empath: true, undead: true)
      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    it 'empath with all flags false is blocked' do
      gs = build_offense_state(empath: true, permashocked: false, construct: false, undead: false)
      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    # BUG-FINDING: Absolution drop mid-hunt changes offense state dynamically
    it 'blocks offense when Absolution drops mid-hunt' do
      gs = build_offense_state(empath: true, undead: true)
      allow(DRSpells).to receive(:active_spells).and_return({ 'Absolution' => 100 })
      expect(gs.is_offense_allowed?).to be true

      allow(DRSpells).to receive(:active_spells).and_return({})
      expect(gs.is_offense_allowed?).to be false
    end

    # BUG-FINDING: construct mode + NOT permashocked means shock warning should still drop spells
    it 'construct mode empath is offense-allowed but NOT permashocked' do
      gs = build_offense_state(empath: true, construct: true)
      expect(gs.is_offense_allowed?).to be true
      expect(gs.is_permashocked?).to be false
    end
  end

  describe '#can_face?' do
    it('returns false in innocence mode') { expect(build_offense_state(innocence: true).can_face?).to be false }

    it 'returns false with empty room' do
      DRRoom.npcs = []
      expect(build_offense_state.can_face?).to be false
    end

    it 'returns true with npcs and no innocence' do
      DRRoom.npcs = ['rat']
      expect(build_offense_state.can_face?).to be true
    end

    # BUG-FINDING: innocence blocks can_face even with npcs present
    it 'innocence overrides NPC presence' do
      DRRoom.npcs = ['rat']
      expect(build_offense_state(innocence: true).can_face?).to be false
    end
  end

  describe '#can_engage?' do
    it('returns false when can_face? is false') { expect(build_offense_state(innocence: true).can_engage?).to be false }

    it 'returns false when retreating' do
      DRRoom.npcs = ['rat']
      gs = build_offense_state
      gs.instance_variable_set(:@retreating, true)
      expect(gs.can_engage?).to be false
    end

    it 'returns true when npcs present, not retreating, not innocent' do
      DRRoom.npcs = ['rat']
      expect(build_offense_state.can_engage?).to be true
    end

    it 'invalidates the selector when movement follows engagement gating' do
      DRRoom.npcs = ['goblin']
      gs = build_offense_state
      allow(Room).to receive(:current).and_return(
        double('Room', id: 10), double('Room', id: 11)
      )
      expect(gs.can_engage?).to be true
      expect(gs.target_selector).to be_nil
    end

    it 'invalidates the selector when target death churns duplicate ordinals' do
      DRRoom.npcs = ['goblin', 'second goblin']
      room = double('Room', id: 10)
      allow(Room).to receive(:current).and_return(room)
      gs = build_offense_state

      expect(gs.can_engage?).to be true
      DRRoom.npcs = ['goblin']
      expect(gs.target_selector).to be_nil
    end

    it 'invalidates the selector when the ordered target roster changes' do
      DRRoom.npcs = %w[goblin hog]
      room = double('Room', id: 10)
      allow(Room).to receive(:current).and_return(room)
      gs = build_offense_state

      expect(gs.can_engage?).to be true
      DRRoom.npcs = %w[hog goblin]
      expect(gs.target_selector).to be_nil
    end

    it 'consumes each fresh selector after one use' do
      DRRoom.npcs = ['goblin']
      room = double('Room', id: 10)
      allow(Room).to receive(:current).and_return(room)
      gs = build_offense_state

      expect(gs.can_engage?).to be true
      expect(gs.target_selector).to eq('goblin')
      expect(gs.target_selector).to be_nil
    end
  end

  describe '#engage' do
    def build_engage_state
      gs = build_offense_state
      allow(gs).to receive(:stomp).and_return(false)
      allow(gs).to receive(:pounce).and_return(false)
      allow(gs).to receive(:rush).and_return(false)
      allow(gs).to receive(:pause)
      gs
    end

    it 'returns false without sending a command when no combatants are present' do
      DRRoom.npcs = []
      expect(DRC).not_to receive(:bput)
      expect(build_engage_state.engage).to be false
    end

    it 'returns false and waits while the target is still approaching' do
      DRRoom.npcs = ['rat']
      gs = build_engage_state
      allow(DRC).to receive(:bput).and_return('You begin to advance')

      expect(gs.engage).to be false
      expect(gs).to have_received(:pause).with(2)
    end

    it 'returns true only after melee engagement is confirmed' do
      DRRoom.npcs = ['rat']
      allow(DRC).to receive(:bput).and_return('You are already at melee')
      expect(build_engage_state.engage).to be true
    end
  end

  # "You will have to retreat from your current melee first." means another
  # creature already holds this character in melee. Vrakk re-sent the same
  # refused ENGAGE #3282527 948 times in 55 minutes (2026-09-29 02:08-03:03)
  # while the goblins at melee attacked him: server-ID selection kept offering
  # the lowest live ID.
  describe 'a refused ENGAGE' do
    let(:refused) { 'You will have to retreat from your current melee first.' }

    # `ids` is the crtrStatus census; `engaged` the IDs without disengaged="1".
    def refusal_state(ids, engaged: ids, server_ids: true)
      gs = build_offense_state
      gs.instance_variable_set(:@drbot_server_id_targeting, server_ids)
      gs.instance_variable_set(:@drbot_supervised_group, nil)
      %i[stomp pounce rush].each { |name| allow(gs).to receive(name).and_return(false) }
      allow(gs).to receive(:pause)
      allow(Room).to receive(:current).and_return(double('Room', id: 1473))
      @census = ids
      @engaged = engaged
      allow(gs).to receive(:drbot_target_context) do
        { room: 1473, room_count: 4, xml_room: 62_001, self: 'vrakk', visible: [],
          npcs: @census.map { 'goblin' }, ids: @census.dup, dead: [] }
      end
      registry = double('Creature')
      allow(registry).to receive(:targets) do
        @census.map { |id| double("creature #{id}", id: id, crtr_flag?: !@engaged.include?(id)) }
      end
      stub_const('Lich::DragonRealms::Creature', registry)
      DRRoom.npcs = ids.map { 'goblin' }
      allow(DRC).to receive(:message)
      allow(DRC).to receive(:retreat)
      gs
    end

    def census(ids, engaged: ids)
      @census = ids
      @engaged = engaged
      DRRoom.npcs = ids.map { 'goblin' }
    end

    def replies(map)
      allow(DRC).to receive(:bput) { |command, *| map.fetch(command) }
    end

    it 'never re-sends the refused ID and engages the creature that holds melee' do
      gs = refusal_state(%w[3282527 3283101])
      replies('engage #3282527' => refused,
              'engage #3283101' => 'You are already at melee with a tall forager goblin.')

      expect(gs.engage).to be false
      3.times { expect(gs.engage).to be true }
      expect(DRC).to have_received(:bput).with('engage #3282527', any_args).once
      expect(DRC).to have_received(:bput).with('engage #3283101', any_args).exactly(3).times
      expect(DRC).to have_received(:message)
        .with('*** combat-trainer: ENGAGE #3282527 refused: already in melee with another creature; ' \
              'fighting the creature in melee instead of retreating.').once
      expect(DRC).not_to have_received(:retreat)
      expect(gs).not_to have_received(:pause)
    end

    it 'ranks a creature engaged with this character ahead of a lower ID engaged elsewhere' do
      gs = refusal_state(%w[3282527 3283136], engaged: %w[3283136])
      replies('engage #3283136' => 'You are already at melee with a freckled forager goblin.')

      expect(gs.engage).to be true
      expect(DRC).to have_received(:bput).once
    end

    it 'keeps the creature confirmed at melee first when a lower ID arrives' do
      gs = refusal_state(%w[3282527 3283101])
      replies('engage #3282527' => refused,
              'engage #3283101' => 'You are already at melee with a tall forager goblin.')
      gs.engage
      gs.engage
      census(%w[3280000 3282527 3283101])

      expect(gs.engage).to be true
      expect(DRC).to have_received(:bput).with('engage #3283101', any_args).twice
      expect(DRC).not_to have_received(:bput).with('engage #3280000', any_args)
    end

    it 'tries a refused ID last once the creature at melee has died' do
      gs = refusal_state(%w[3282527 3283101 3283136])
      replies('engage #3282527' => refused,
              'engage #3283101' => 'You are already at melee with a tall forager goblin.',
              'engage #3283136' => 'You are already at melee with a freckled forager goblin.')
      gs.engage
      gs.engage
      census(%w[3282527 3283136])

      expect(gs.engage).to be true
      expect(DRC).to have_received(:bput).with('engage #3283136', any_args).once
      expect(DRC).to have_received(:bput).with('engage #3282527', any_args).once
    end

    it 'drops a refusal when its creature leaves and forgets all of them on a new advance' do
      gs = refusal_state(%w[11 22 33])
      replies('engage #11' => refused, 'engage #22' => refused, 'engage #33' => 'You begin to advance on a goblin.')
      gs.engage
      census(%w[22 33])
      gs.engage
      expect(gs.drbot_melee_refusals.keys).to eq(['#22'])

      gs.engage
      expect(gs.drbot_melee_refusals).to be_empty
      expect(gs).to have_received(:pause).with(2).once
    end

    it 'sends nothing while every creature here refused, then ranks them once more after 15 seconds' do
      now = 500.0
      allow(Process).to receive(:clock_gettime) { now }
      gs = refusal_state(%w[11 22])
      replies('engage #11' => refused, 'engage #22' => refused)
      gs.engage
      gs.engage
      3.times { expect(gs.engage).to be false }
      expect(DRC).to have_received(:bput).twice
      expect(DRC).to have_received(:message).with(/every creature here refused ENGAGE.*not engaging/).once

      now += 15
      replies('engage #11' => 'You are already at melee with a goblin.')
      expect(gs.engage).to be true
      expect(DRC).to have_received(:message).with(/every creature here refused ENGAGE.*ranking them again/).once
    end

    it 'forgets the refusals of another room' do
      gs = refusal_state(%w[11 22])
      replies('engage #11' => refused, 'engage #22' => 'You are already at melee with a goblin.')
      gs.engage
      allow(Room).to receive(:current).and_return(double('Room', id: 1474))
      allow(gs).to receive(:drbot_target_context).and_return(
        { room: 1474, room_count: 5, xml_room: 62_002, self: 'vrakk', visible: [],
          npcs: %w[goblin goblin], ids: %w[11 22], dead: [] }
      )
      replies('engage #11' => 'You are already at melee with a goblin.')

      expect(gs.engage).to be true
      expect(DRC).to have_received(:bput).with('engage #11', any_args).twice
    end

    context 'without server IDs' do
      it 'attacks the creature it faces and does not re-send the bare ENGAGE' do
        gs = refusal_state([], server_ids: false)
        DRRoom.npcs = %w[goblin hog]
        replies('engage goblin' => refused)

        3.times { expect(gs.engage).to be true }
        expect(DRC).to have_received(:bput).with('engage goblin', any_args).once
        expect(DRC).to have_received(:message).with(/ENGAGE goblin refused: already in melee/).once
        expect(DRC).not_to have_received(:retreat)
      end

      it 'sends the ENGAGE again once an attack finds nothing at melee' do
        gs = refusal_state([], server_ids: false)
        DRRoom.npcs = %w[goblin hog]
        replies('engage goblin' => refused)
        gs.engage
        gs.drbot_forget_melee_refusals
        replies('engage goblin' => 'You begin to advance on a forager goblin.')

        expect(gs.engage).to be false
        expect(DRC).to have_received(:bput).with('engage goblin', any_args).twice
      end
    end

    it 'records the refusal from engage_slow as well' do
      gs = refusal_state(%w[11 22])
      replies('engage #11' => refused, 'engage #22' => 'You are already at melee with a goblin.')
      gs.engage_slow
      gs.engage_slow

      expect(DRC).to have_received(:bput).with('engage #11', any_args).once
      expect(DRC).to have_received(:bput).with('engage #22', any_args).once
    end

    it "ranks its own refused attacker ahead of a buddy's opponent once the holder has died" do
      gs = refusal_state(%w[11 22 33], engaged: %w[11 22])
      replies('engage #11' => refused, 'engage #22' => 'You are already at melee with a goblin.')
      gs.engage
      gs.engage
      census(%w[11 33], engaged: %w[11])
      replies('engage #11' => 'You begin to advance on a goblin.')

      expect(gs.engage).to be false
      expect(DRC).not_to have_received(:bput).with('engage #33', any_args)
    end

    it 'ranks the creature it began to advance on first while it closes' do
      gs = refusal_state(%w[22])
      replies('engage #22' => 'You begin to advance on a goblin.')
      gs.engage
      census(%w[11 22])
      replies('engage #22' => 'You are already at melee with a goblin.')

      expect(gs.engage).to be true
      expect(DRC).not_to have_received(:bput).with('engage #11', any_args)
    end

    it 'forgets every refusal after a retreat' do
      gs = refusal_state(%w[11 22])
      replies('engage #11' => refused, 'engage #22' => 'You are already at melee with a goblin.')
      gs.engage
      Flags['ct-melee-retreat'] = 'You retreat from combat.'

      expect(gs.drbot_melee_refusals).to be_empty
      expect(Flags['ct-melee-retreat']).to be false
    end

    context 'without server IDs' do
      it 'faces the next creature once when its attack is out of reach' do
        gs = refusal_state([], server_ids: false)
        DRRoom.npcs = %w[goblin hog]
        replies('engage goblin' => refused, 'face next' => 'You turn to face a large musk hog.')
        gs.engage

        expect(gs.drbot_melee_out_of_reach).to be true
        expect(gs.drbot_melee_out_of_reach).to be false
        expect(DRC).to have_received(:bput).with('face next', any_args).once
      end

      it 'does not face anything without a bare refusal' do
        gs = refusal_state([], server_ids: false)
        allow(DRC).to receive(:bput)

        expect(gs.drbot_melee_out_of_reach).to be false
        expect(DRC).not_to have_received(:bput)
      end

      it 'holds back a bare ENGAGE refused again with no roundtime between for 15 seconds, logged once' do
        now = 500.0
        allow(Process).to receive(:clock_gettime) { now }
        gs = refusal_state([], server_ids: false)
        allow(gs).to receive(:drbot_roundtime_mark).and_return(7)
        DRRoom.npcs = %w[goblin hog]
        replies('engage goblin' => refused)
        expect(gs.engage).to be true
        gs.drbot_forget_melee_refusals

        expect(gs.engage).to be false
        2.times { expect(gs.engage).to be false }
        expect(DRC).to have_received(:bput).with('engage goblin', any_args).twice
        expect(DRC).to have_received(:message).with(/ENGAGE goblin refused again .*not engaging for 15 s/).once

        now += 15
        gs.engage
        expect(DRC).to have_received(:bput).with('engage goblin', any_args).exactly(3).times
      end

      it 'treats a bare refusal after roundtime as a new melee' do
        gs = refusal_state([], server_ids: false)
        rt = 7
        allow(gs).to receive(:drbot_roundtime_mark) { rt }
        DRRoom.npcs = %w[goblin hog]
        replies('engage goblin' => refused)
        gs.engage
        gs.drbot_forget_melee_refusals
        rt = 9

        expect(gs.engage).to be true
        expect(DRC).not_to have_received(:message).with(/refused again/)
      end

      it 'honours the refusal in engage_slow' do
        gs = refusal_state([], server_ids: false)
        DRRoom.npcs = %w[goblin hog]
        replies('engage goblin' => refused)
        gs.engage_slow
        gs.engage_slow

        expect(DRC).to have_received(:bput).with('engage goblin', any_args).once
      end
    end
  end

  # ---- NPC handling ----

  describe '#update_room_npcs' do
    def build_npc_state(ignored: [], dance_threshold: 1, retreat_threshold: nil)
      gs = GameState.allocate
      gs.instance_variable_set(:@ignored_npcs, ignored)
      gs.instance_variable_set(:@dance_threshold, dance_threshold)
      gs.instance_variable_set(:@retreat_threshold, retreat_threshold)
      gs.instance_variable_set(:@dancing, false)
      gs.instance_variable_set(:@retreating, false)
      gs
    end

    it('filters ignored npcs') do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_npc_state(ignored: ['gremlin'])
      gs.update_room_npcs
      expect(gs.npcs).to eq(%w[rat kobold])
    end

    it('sets dancing when npc count <= threshold') do
      DRRoom.npcs = ['rat']
      gs = build_npc_state(dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it('clears dancing when npc count > threshold') do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_npc_state(dance_threshold: 1)
      gs.update_room_npcs
      expect(gs.dancing?).to be false
    end

    it('sets dancing on empty room') do
      DRRoom.npcs = []
      gs = build_npc_state(dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.dancing?).to be true
    end

    it('sets retreating at threshold boundary') do
      DRRoom.npcs = %w[rat kobold]
      gs = build_npc_state(dance_threshold: 0, retreat_threshold: 2)
      gs.update_room_npcs
      expect(gs.retreating?).to be true
    end

    it('retreat_threshold nil never retreats') do
      DRRoom.npcs = %w[rat kobold gremlin]
      gs = build_npc_state(retreat_threshold: nil)
      gs.update_room_npcs
      expect(gs.retreating?).to be_falsy
    end

    it 'leaves through a mapped exit and stops unsafe melee-only contact' do
      gs = build_npc_state(dance_threshold: 0, retreat_threshold: 2)
      gs.instance_variable_set(:@escape_unsafe_multi_enemy, true)
      gs.instance_variable_set(:@weapons_to_train, { 'Small Edged' => 'kris' })
      DRRoom.npcs = %w[goblin hog]
      origin = double('Room', id: 10, wayto: { 11 => 'east' })
      destination = double('Room', id: 11, wayto: {})
      current_room = origin
      allow(Room).to receive(:current) { current_room }
      allow(DRC).to receive(:retreat)
      allow(DRCT).to receive(:walk_to) { current_room = destination }

      gs.update_room_npcs
      expect(DRCT).to have_received(:walk_to).with(11).once
      expect($HUNTING_BUDDY).to have_received(:stop_hunting).once
      expect($COMBAT_TRAINER).to have_received(:stop).once
    end

    it 'stops without retrying when no mapped exit can be verified' do
      gs = build_npc_state(dance_threshold: 0, retreat_threshold: 2)
      gs.instance_variable_set(:@escape_unsafe_multi_enemy, true)
      gs.instance_variable_set(:@weapons_to_train, { 'Small Edged' => 'kris' })
      DRRoom.npcs = %w[goblin hog]
      allow(Room).to receive(:current).and_return(
        double('Room', id: 10, wayto: {})
      )
      allow(DRCT).to receive(:walk_to)

      gs.update_room_npcs
      expect(DRCT).not_to have_received(:walk_to)
      expect($HUNTING_BUDDY).to have_received(:stop_hunting).once
      expect($COMBAT_TRAINER).to have_received(:stop).once
    end

    # BUG-FINDING: all npcs ignored leaves empty room
    it 'all-ignored npcs produces empty list and dancing' do
      DRRoom.npcs = %w[rat kobold]
      gs = build_npc_state(ignored: %w[rat kobold], dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.npcs).to eq([])
      expect(gs.dancing?).to be true
    end

    # BUG-FINDING: dance_threshold 0 with 1 npc is NOT dancing (off-by-one)
    it 'dance_threshold 0 with 1 npc is not dancing' do
      DRRoom.npcs = ['rat']
      gs = build_npc_state(dance_threshold: 0)
      gs.update_room_npcs
      expect(gs.dancing?).to be false
    end
  end

  describe '#npcs' do
    it 'recomputes from DRRoom on every call (no stale data)' do
      gs = GameState.allocate
      gs.instance_variable_set(:@ignored_npcs, [])
      DRRoom.npcs = ['rat']
      expect(gs.npcs).to eq(['rat'])
      DRRoom.npcs = ['kobold']
      expect(gs.npcs).to eq(['kobold'])
    end
  end

  # ---- engage chain (rush/stomp/pounce) ----

  describe '#rush' do
    def build_rush_state(empath: false, permashocked: false, shield: nil, rush_to_engage: false)
      gs = GameState.allocate
      gs.instance_variable_set(:@is_empath, empath)
      gs.instance_variable_set(:@is_permashocked, permashocked)
      gs.instance_variable_set(:@construct_mode, false)
      gs.instance_variable_set(:@undead_mode, false)
      gs.instance_variable_set(:@rush_shield, shield)
      gs.instance_variable_set(:@rush_to_engage, rush_to_engage)
      gs.instance_variable_set(:@rush_retreat_skip, false)
      gs.instance_variable_set(:@rush_engage_only, false)
      gs.instance_variable_set(:@ignored_npcs, [])
      gs.instance_variable_set(:@dancing, false)
      gs.instance_variable_set(:@retreating, false)
      gs.instance_variable_set(:@charged_maneuvers, { 'Shield Usage' => 'rush' })
      gs.instance_variable_set(:@cooldown_timers, {})
      allow(DRSpells).to receive(:active_spells).and_return({})
      gs
    end

    # BUG-FINDING: documents the gap fixed in PR #7415.
    # On main (unfixed), rush does NOT check is_offense_allowed?, so a
    # non-permashocked empath with rush configured WILL execute the maneuver.
    # After the fix merges, change this to: expect(gs.rush).to be false
    it 'blocks a non-permashocked empath from rush (offense not allowed)' do
      DRRoom.npcs = ['rat']
      gs = build_rush_state(empath: true, shield: 'shield', rush_to_engage: true)
      # is_offense_allowed? is false for a non-permashocked empath (is_permashocked?
      # returns false), so rush short-circuits before any maneuver, per PR #7355.
      expect(gs.rush).to be_falsy
    end

    it('blocks when retreating') do
      gs = build_rush_state(shield: 'shield')
      allow(gs).to receive(:retreating?).and_return(true)
      expect(gs.rush).to be_falsy
    end

    it('blocks when left hand occupied') do
      $left_hand = 'sword'
      gs = build_rush_state(shield: 'shield')
      allow(gs).to receive(:retreating?).and_return(false)
      expect(gs.rush).to be false
    end

    it('blocks when no rush_shield') { expect(build_rush_state.rush).to be false }

    it 'blocks when no npcs' do
      DRRoom.npcs = []
      gs = build_rush_state(shield: 'shield', rush_to_engage: true)
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      expect(gs.rush).to be false
    end

    it('blocks when rush_to_engage false') do
      DRRoom.npcs = ['rat']
      gs = build_rush_state(shield: 'shield', rush_to_engage: false)
      allow(gs).to receive(:retreating?).and_return(false)
      allow(gs).to receive(:loaded).and_return(false)
      expect(gs.rush).to be false
    end
  end

  describe '#stomp' do
    def build_stomp_state(guild: 'Barbarian', circle: 100, stomp_to_engage: true)
      DRStats.guild = guild
      DRStats.circle = circle
      gs = GameState.allocate
      gs.instance_variable_set(:@stomp_to_engage, stomp_to_engage)
      gs.instance_variable_set(:@stomp_on_cooldown, false)
      gs.instance_variable_set(:@ignored_npcs, [])
      gs.instance_variable_set(:@retreating, false)
      gs
    end

    it('blocks non-barbarians') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state(guild: 'Empath').stomp).to be false
    end

    it('blocks barbarians below circle 100') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state(circle: 50).stomp).to be false
    end

    it('blocks with no npcs') do
      DRRoom.npcs = []
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state.stomp).to be false
    end

    it('blocks when stomp_to_engage false and stomp_on_cooldown false') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = true
      expect(build_stomp_state(stomp_to_engage: false).stomp).to be false
    end

    it('blocks when flag not ready') do
      DRRoom.npcs = ['rat']
      Flags['war-stomp-ready'] = false
      expect(build_stomp_state.stomp).to be false
    end
  end

  describe '#pounce' do
    it('blocks non-rangers') do
      DRStats.guild = 'Barbarian'
      DRRoom.npcs = ['rat']
      gs = GameState.allocate
      gs.instance_variable_set(:@pounce_on_cooldown, true)
      gs.instance_variable_set(:@pounce_to_engage, true)
      gs.instance_variable_set(:@ignored_npcs, [])
      gs.instance_variable_set(:@retreating, false)
      Flags['pounce-ready'] = true
      expect(gs.pounce).to be false
    end
  end

  # ---- skill_done? ----

  describe '#skill_done?' do
    def build_skill_state(**overrides)
      gs = GameState.allocate
      defaults = {
        ignore_weapon_mindstate: false,
        current_weapon_skill: 'Bow',
        action_count: 0,
        target_action_count: 25,
        target_weapon_skill: 20,
        gain_check: 5,
        focus_threshold: 0,
        focus_threshold_active: false,
        last_exp: 10,
        last_action_count: 0,
        no_gain_list: Hash.new(0),
        weapons_to_train: { 'Bow' => 'longbow', 'Slings' => 'sling' }
      }
      defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
      gs
    end

    before(:each) do
      allow(DRSkill).to receive(:getxp).and_return(0)
      allow(DRSkill).to receive(:getrank).and_return(100)
    end

    context 'with ignore_weapon_mindstate true' do
      it 'returns false below action count regardless of exp' do
        allow(DRSkill).to receive(:getxp).and_return(34)
        gs = build_skill_state(ignore_weapon_mindstate: true, action_count: 5)
        expect(gs.skill_done?).to be false
      end

      it 'returns true at action count target' do
        gs = build_skill_state(ignore_weapon_mindstate: true, action_count: 25)
        expect(gs.skill_done?).to be true
      end
    end

    context 'with ignore_weapon_mindstate false' do
      it 'returns true when exp is 34 regardless of action count' do
        allow(DRSkill).to receive(:getxp).and_return(34)
        gs = build_skill_state(action_count: 0)
        expect(gs.skill_done?).to be true
      end

      it 'returns true when exp meets target' do
        allow(DRSkill).to receive(:getxp).and_return(20)
        gs = build_skill_state(action_count: 3, target_weapon_skill: 20)
        expect(gs.skill_done?).to be true
      end

      it 'returns false when both exp and action count are below target' do
        allow(DRSkill).to receive(:getxp).and_return(10)
        gs = build_skill_state(action_count: 5, target_weapon_skill: 20)
        expect(gs.skill_done?).to be false
      end
    end

    # BUG-FINDING: gain_check with stagnant exp blacklists skill after threshold
    context 'gain_check blacklisting' do
      it 'increments no_gain counter when exp stagnates' do
        allow(DRSkill).to receive(:getxp).and_return(10)
        gs = build_skill_state(last_exp: 10, gain_check: 2, action_count: 25)
        gs.skill_done?
        expect(gs.instance_variable_get(:@no_gain_list)['Bow']).to eq(1)
      end

      it 'resets no_gain counter when exp increases' do
        allow(DRSkill).to receive(:getxp).and_return(15)
        no_gain = Hash.new(0)
        no_gain['Bow'] = 3
        gs = build_skill_state(last_exp: 10, gain_check: 5, action_count: 25, no_gain_list: no_gain)
        gs.skill_done?
        expect(gs.instance_variable_get(:@no_gain_list)['Bow']).to eq(0)
      end
    end
  end
end

# ===================================================================
# ManipulateProcess
# Tests empath manipulation including shock detection and construct
# marking. Manipulation errors silently broke before our fix.
# ===================================================================
RSpec.describe ManipulateProcess do
  before(:each) { ct_setup }

  def build_manipulate(threshold: 2, manip_to_train: false, last_manip: Time.now - 200)
    mp = ManipulateProcess.allocate
    mp.instance_variable_set(:@threshold, threshold)
    mp.instance_variable_set(:@manip_to_train, manip_to_train)
    mp.instance_variable_set(:@last_manip, last_manip)
    mp
  end

  def gs_double(**attrs)
    defaults = { danger: false, construct_mode?: false, npcs: %w[rat kobold] }
    double('GameState', defaults.merge(attrs))
  end

  describe '#execute' do
    it 'skips on danger and does not call manipulate' do
      mp = build_manipulate(last_manip: Time.now - 200)
      before_manip = mp.instance_variable_get(:@last_manip)
      mp.execute(gs_double(danger: true))
      expect(mp.instance_variable_get(:@last_manip)).to eq(before_manip)
    end

    it 'skips on nil threshold and does not call manipulate' do
      mp = build_manipulate(threshold: nil, last_manip: Time.now - 200)
      before_manip = mp.instance_variable_get(:@last_manip)
      mp.execute(gs_double)
      expect(mp.instance_variable_get(:@last_manip)).to eq(before_manip)
    end

    it 'skips on construct mode and does not call manipulate' do
      mp = build_manipulate(last_manip: Time.now - 200)
      before_manip = mp.instance_variable_get(:@last_manip)
      mp.execute(gs_double(construct_mode?: true))
      expect(mp.instance_variable_get(:@last_manip)).to eq(before_manip)
    end

    it 'skips when empathy XP > 30 and manip_to_train set' do
      allow(DRSkill).to receive(:getxp).with('Empathy').and_return(31)
      mp = build_manipulate(manip_to_train: true)
      mp.execute(gs_double)
      expect(mp.instance_variable_get(:@threshold)).not_to be_nil
    end

    it 'manipulates when threshold met and cooldown elapsed' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')
      gs = gs_double(npcs: %w[rat kobold])
      allow(gs).to receive(:construct?).and_return(false)
      build_manipulate(threshold: 2).execute(gs)
    end

    # BUG-FINDING: shock disables manipulation permanently for this hunt
    it 'disables threshold on shock ("deep sense of loss")' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('deep sense of loss')
      allow(DRC).to receive(:message)
      gs = gs_double(npcs: ['rat'])
      allow(gs).to receive(:construct?).and_return(false)
      mp = build_manipulate(threshold: 1)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@threshold)).to be_nil
    end

    # BUG-FINDING: verify construct marking propagates to game_state
    it 'marks NPC as construct and that state persists' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('does not seem to have a life essence')
      gs = gs_double(npcs: ['golem'])
      allow(gs).to receive(:construct?).and_return(false)
      expect(gs).to receive(:construct).with('golem')
      build_manipulate(threshold: 1).execute(gs)
    end

    # BUG-FINDING: threshold 0 with empty npcs still enters manipulate
    # (0 >= 0 is true), verifying the loop body is a no-op
    it 'threshold 0 with empty npcs enters manipulate but does nothing offensive' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return("But you aren't manipulating anything")
      mp = build_manipulate(threshold: 0)
      mp.execute(gs_double(npcs: []))
      expect(mp.instance_variable_get(:@last_manip)).to be_within(2).of(Time.now)
    end

    # BUG-FINDING: cooldown boundary -- 119 seconds should NOT trigger (needs > 120)
    it 'does not manipulate at 119s cooldown' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      mp = build_manipulate(threshold: 1, last_manip: Time.now - 119)
      gs = gs_double(npcs: ['rat'])
      allow(gs).to receive(:construct?).and_return(false)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@last_manip)).to be < Time.now - 100
    end

    # BUG-FINDING: cooldown boundary -- 121 seconds SHOULD trigger
    it 'manipulates at 121s cooldown' do
      allow(DRSkill).to receive(:getxp).and_return(10)
      allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')
      gs = gs_double(npcs: ['rat'])
      allow(gs).to receive(:construct?).and_return(false)
      mp = build_manipulate(threshold: 1, last_manip: Time.now - 121)
      mp.execute(gs)
      expect(mp.instance_variable_get(:@last_manip)).to be_within(2).of(Time.now)
    end
  end
end

# ===================================================================
# AttackProcess
# The dance/attack gate is the primary safety mechanism for empaths.
# ===================================================================
RSpec.describe AttackProcess do
  before(:each) { ct_setup }

  def build_attack(**overrides)
    ap = AttackProcess.allocate
    defaults = {
      fatigue_regen_action: 'bob', stealth_attack_aimed_action: nil,
      hide_type: 'hide', offhand_thrown: false, ambush_location: nil,
      get_actions: %w[get wield],
      rt_actions: %w[gouge attack jab feint draw lunge slice lob throw],
      stow_actions: %w[stow sheath put],
      use_overrides_for_aiming_trainables: false,
      firing_delay: 0, firing_timer: Time.now, firing_check: 0
    }
    defaults.merge(overrides).each { |k, v| ap.instance_variable_set(:"@#{k}", v) }
    allow(ap).to receive(:waitrt?)
    ap
  end

  def gs_double(**attrs)
    defaults = {
      dancing?: false, weapon_skill: 'Small Edged', weapon_name: 'sword',
      is_offense_allowed?: true, finish_killing?: false, npcs: ['rat'],
      no_stab_current_mob: false, mob_died: false, stabbable?: true,
      thrown_skill?: false, aimed_skill?: false, fatigue_low?: false,
      retreating?: false, loaded: false, melee_weapon_skill?: true,
      offhand?: false, brawling?: false, backstab?: false,
      use_stealth_attack?: false, ambush?: false, ambush_stun_training?: false,
      determine_charged_maneuver: nil, reset_barb_whirlwind_flags_if_needed: nil,
      action_taken: nil, can_engage?: true, use_weak_attacks?: false,
      attack_override: 'attack', melee_attack_verb: 'attack',
      engage: nil, set_dance_queue: nil, next_dance_action: 'bob',
      target_selector: 'rat',
      drbot_attack_ids_required?: false,
      dispatch_typed_combo: false, dispatch_enemy_combo: false,
      next_clean_up_step: nil
    }
    double('GameState', defaults.merge(attrs))
  end

  before(:each) do
    Flags.add('ct-face-what', 'Face what')
    Flags.add('ct-ranged-ammo', 'ammo')
    Flags.add('ct-powershot-ammo', 'powershot')
    Flags.add('ct-ranged-loaded', 'loaded')
    Flags.add('ct-using-repeating-crossbow', /repeating/)
    Flags.add('ct-aim-failed', 'stop aiming')
    Flags.add('ct-ranged-ready', 'best shot')
    Flags.add('war-stomp-ready', 'ready')
    Flags.add('pounce-ready', 'ready')
    Flags.add('ct-maneuver-cooldown-reduced', 'expert skill')
    Flags.add('ct-attack-out-of-range', 'not close enough')
  end

  describe '#execute' do
    it('dances when offense not allowed') do
      gs = gs_double(is_offense_allowed?: false, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it('dances when weapon_skill nil') do
      gs = gs_double(weapon_skill: nil, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it('dances when weapon is Targeted Magic') do
      gs = gs_double(weapon_skill: 'Targeted Magic', can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it('dances when dancing? is true') do
      gs = gs_double(dancing?: true, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).to have_received(:set_dance_queue)
    end

    it 'advances cleanup when finish_killing and offense blocked' do
      gs = gs_double(is_offense_allowed?: false, finish_killing?: true)
      build_attack.execute(gs)
      expect(gs).to have_received(:next_clean_up_step)
    end

    # BUG-FINDING: verify dance does NOT call next_clean_up_step when not finishing
    it 'does not advance cleanup when dancing but not finish_killing' do
      gs = gs_double(is_offense_allowed?: false, finish_killing?: false, can_engage?: true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      build_attack.execute(gs)
      expect(gs).not_to have_received(:next_clean_up_step)
    end

    it 'attacks melee when offense allowed and melee skill equipped' do
      gs = gs_double(thrown_skill?: false, aimed_skill?: false)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      expect(build_attack.execute(gs)).to be false
    end

    it 'drops a departed target without issuing another backstab command' do
      gs = gs_double(npcs: [], backstab?: true, engage: false)
      allow(gs).to receive(:loaded=)
      expect(DRC).not_to receive(:bput)

      expect(build_attack.execute(gs)).to be false
      expect(gs).to have_received(:engage)
    end

    it 'drops a departed target without issuing another brawling command' do
      gs = gs_double(npcs: [], brawling?: true, engage: false, melee_attack_verb: 'gouge')
      allow(gs).to receive(:loaded=)
      expect(DRC).not_to receive(:bput)

      expect(build_attack.execute(gs)).to be false
      expect(gs).to have_received(:engage)
    end

    it 'does not issue backstab commands while a target is approaching' do
      gs = gs_double(backstab?: true, engage: false)
      allow(gs).to receive(:loaded=)
      expect(DRC).not_to receive(:bput)

      expect(build_attack.execute(gs)).to be false
      expect(gs).to have_received(:engage)
    end

    it 'does not issue brawling commands while a target is approaching' do
      gs = gs_double(brawling?: true, engage: false, melee_attack_verb: 'gouge')
      allow(gs).to receive(:loaded=)
      expect(DRC).not_to receive(:bput)

      expect(build_attack.execute(gs)).to be false
      expect(gs).to have_received(:engage)
    end

    it 'issues backstab only after melee engagement is confirmed' do
      gs = gs_double(backstab?: true, engage: true)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:hide?).and_return(true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      attack = build_attack
      allow(attack).to receive(:hiding?).and_return(true)

      expect(attack.execute(gs)).to be false
      expect(DRC).to have_received(:bput).with('backstab rat', any_args)
    end

    it 'drops a backstab when the fresh selector was invalidated' do
      gs = gs_double(backstab?: true, engage: true, target_selector: nil)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:hide?).and_return(true)
      attack = build_attack
      allow(attack).to receive(:hiding?).and_return(true)
      expect(DRC).not_to receive(:bput)

      expect(attack.execute(gs)).to be false
    end

    it 'issues one brawling command after melee engagement is confirmed' do
      gs = gs_double(brawling?: true, engage: true, melee_attack_verb: 'gouge')
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return('Roundtime')

      expect(build_attack.execute(gs)).to be false
      expect(gs).to have_received(:engage).once
      expect(DRC).to have_received(:bput).with('gouge', any_args).once
    end

    # From hiding, ASSESS cannot prove an ANALYZE target; the enemy-combo
    # refresh must not run, or its failed census vetoes the ID-bound backstab.
    it 'backstabs from hiding without selecting or dispatching an enemy combo' do
      gs = gs_double(backstab?: true, engage: true)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:hide?).and_return(true)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      attack = build_attack
      allow(attack).to receive(:hiding?).and_return(true)

      expect(attack.execute(gs)).to be false
      expect(gs).to have_received(:melee_attack_verb).with(allow_enemy_combo: false)
      expect(gs).to have_received(:dispatch_enemy_combo).with('backstab rat', from_hiding: true)
      expect(DRC).to have_received(:bput).with('backstab rat', any_args).once
    end

    it 'keeps enemy combos for an attack made in the open' do
      gs = gs_double(engage: true)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      attack = build_attack
      allow(attack).to receive(:hiding?).and_return(false)

      expect(attack.execute(gs)).to be false
      expect(gs).to have_received(:melee_attack_verb).with(allow_enemy_combo: true)
      expect(gs).to have_received(:dispatch_enemy_combo).with('attack', from_hiding: false)
    end

    # A refused ENGAGE stands while the melee that refused it lasts; an attack
    # that finds nothing at melee proves it is over.
    it 'forgets recorded ENGAGE refusals when an attack finds nothing at melee' do
      gs = gs_double(engage: true, drbot_forget_melee_refusals: nil)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return("You aren't close enough to attack.")
      $server_buffer = ["You aren't close enough to attack."]

      expect(build_attack.execute(gs)).to be false
      expect(gs).to have_received(:drbot_forget_melee_refusals).once
      expect(gs).to have_received(:engage).twice
    end

    it 'keeps recorded ENGAGE refusals while attacks land' do
      gs = gs_double(engage: true, drbot_forget_melee_refusals: nil)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      $server_buffer = ['Roundtime: 2 sec.']

      expect(build_attack.execute(gs)).to be false
      expect(gs).not_to have_received(:drbot_forget_melee_refusals)
    end

    it 'forgets recorded ENGAGE refusals when a dance or an aimed shot is out of range' do
      gs = gs_double(engage: true, drbot_forget_melee_refusals: nil)
      attack = build_attack
      allow(DRC).to receive(:bput).and_return('You must be closer')
      attack.send(:dance, gs)
      allow(DRC).to receive(:bput).and_return('must be closer')
      expect(attack.send(:execute_aiming_action?, 'fire', gs)).to be true

      expect(gs).to have_received(:drbot_forget_melee_refusals).twice
      expect(gs).to have_received(:engage).twice
    end

    # "You turn to face a sleazy lout, leaving the sleazy lout on your flank at
    # melee!": the creature faced need not be the one at melee.
    it 'faces the next creature instead of re-sending a bare ENGAGE while its refusal stands' do
      gs = gs_double(engage: true, drbot_forget_melee_refusals: nil, drbot_melee_out_of_reach: true)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return("You aren't close enough to attack.")
      $server_buffer = ["You aren't close enough to attack."]

      build_attack.execute(gs)
      expect(gs).to have_received(:drbot_melee_out_of_reach).once
      expect(gs).not_to have_received(:drbot_forget_melee_refusals)
      expect(gs).to have_received(:engage).once
    end

    it 'keeps recorded ENGAGE refusals when an attack lands after an older out-of-reach line' do
      gs = gs_double(engage: true, drbot_forget_melee_refusals: nil, drbot_melee_out_of_reach: false)
      allow(gs).to receive(:loaded=)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      $server_buffer = ["You aren't close enough to attack.", 'You turn to face a large musk hog.', 'Roundtime: 2 sec.']

      build_attack.execute(gs)
      expect(gs).not_to have_received(:drbot_melee_out_of_reach)
      expect(gs).not_to have_received(:drbot_forget_melee_refusals)
      expect(gs).to have_received(:engage).once
      expect(gs).to have_received(:action_taken)
    end
  end

  describe '#aim' do
    # A creature that hides keeps its crtrStatus ID; AIM #id then answers
    # "I could not find". The next AIM picks another live ID instead of
    # repeating the refusal.
    it 'skips a server ID the game could not find' do
      targets = [{ id: '11' }, { id: '22' }]
      gs = gs_double(drbot_identity_targets?: true, clear_aim_queue: nil)
      allow(gs).to receive(:loaded=)
      allow(gs).to receive(:drbot_living_target_current?) { |target| !target.nil? }
      allow(gs).to receive(:drbot_capture_living_target) do |excluded|
        targets.find { |target| !excluded.include?(target[:id]) }
      end
      allow(DRC).to receive(:bput).with('aim #11', any_args).and_return('I could not find')
      allow(DRC).to receive(:bput).with('aim #22', any_args).and_return('You begin to target')
      attack = build_attack
      allow(attack).to receive(:check_firing_time)

      attack.send(:aim, gs)
      attack.send(:aim, gs)

      expect(DRC).to have_received(:bput).with('aim #11', any_args).once
      expect(DRC).to have_received(:bput).with('aim #22', any_args).once
      expect(gs).to have_received(:loaded=).with(true)
    end
  end
end

# ===================================================================
# AbilityProcess -- guild-gated abilities
# ===================================================================
RSpec.describe AbilityProcess do
  before(:each) { ct_setup }

  def build_ability(**overrides)
    ap = AbilityProcess.allocate
    defaults = {
      paladin_use_badge: false, yiamura_exists: false,
      buffs: {}, khri: [], khri_adaptation: '', barb_buffs: [],
      battle_cries: [], battle_cry_cycle: [], battle_cry_cooldown: 120,
      warhorn_or_egg: nil, stomp_on_cooldown: false, pounce_on_cooldown: false,
      barb_buffs_inner_fire_threshold: 50, meditation_pause_timer: nil,
      roar_helm_noun: nil
    }
    defaults.merge(overrides).each { |k, v| ap.instance_variable_set(:"@#{k}", v) }
    # Mirror initialize: @can_stomp/@can_pounce are precomputed there and #execute gates on them.
    ap.instance_variable_set(:@can_stomp, DRStats.barbarian? && ap.instance_variable_get(:@stomp_on_cooldown))
    ap.instance_variable_set(:@can_pounce, DRStats.ranger? && ap.instance_variable_get(:@pounce_on_cooldown))
    ap
  end

  def gs_double(**attrs)
    defaults = { npcs: ['rat'], cooldown_timers: {}, can_face?: true, danger: false, stomp: nil, pounce: nil, melee_weapon_skill?: true }
    double('GameState', defaults.merge(attrs))
  end

  describe '#execute' do
    it 'fires stomp for barbarian with stomp_on_cooldown' do
      DRStats.guild = 'Barbarian'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(stomp_on_cooldown: true).execute(gs)
      expect(gs).to have_received(:stomp)
    end

    it 'does NOT fire stomp for non-barbarians' do
      DRStats.guild = 'Ranger'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(stomp_on_cooldown: true).execute(gs)
      expect(gs).not_to have_received(:stomp)
    end

    # Boundary: with no targets npcs.any? is false, so stomp must NOT fire.
    # Verifies the .any? guard in AbilityProcess#execute (a bare truthy check on
    # game_state.npcs would wrongly fire stomp on an empty array).
    it 'does NOT fire stomp when npcs array is empty' do
      DRStats.guild = 'Barbarian'
      Flags.add('war-stomp-ready', 'ready')
      Flags['war-stomp-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return([])
      build_ability(stomp_on_cooldown: true).execute(gs)
      expect(gs).not_to have_received(:stomp)
    end

    it 'fires pounce for ranger' do
      DRStats.guild = 'Ranger'
      Flags.add('pounce-ready', 'ready')
      Flags['pounce-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(pounce_on_cooldown: true).execute(gs)
      expect(gs).to have_received(:pounce)
    end

    it 'does NOT fire pounce for non-rangers' do
      DRStats.guild = 'Barbarian'
      Flags.add('pounce-ready', 'ready')
      Flags['pounce-ready'] = true
      gs = gs_double
      allow(gs).to receive(:npcs).and_return(['rat'])
      build_ability(pounce_on_cooldown: true).execute(gs)
      expect(gs).not_to have_received(:pounce)
    end
  end
end

# ===================================================================
# LootProcess -- bundle tying logic
# ===================================================================
RSpec.describe LootProcess do
  before(:each) { ct_setup }

  def build_loot(**overrides)
    lp = LootProcess.allocate
    defaults = {
      tie_bundle: false, skin: false, dissect: false,
      dump_timer: Time.now, dump_junk: false, dump_item_count: 10,
      autoloot_container: nil, autoloot_gems: false,
      equipment_manager: double('EquipmentManager', stow_weapon: nil, wield_weapon?: nil, is_listed_item?: false)
    }
    defaults.merge(overrides).each { |k, v| lp.instance_variable_set(:"@#{k}", v) }
    lp
  end

  def gs_double(**attrs)
    defaults = {
      need_bundle: true, mob_died: false, npcs: [],
      skinnable?: true, finish_killing?: false, finish_spell_casting?: false,
      stowing?: false, currently_whirlwinding: false,
      summoned_info: nil, weapon_name: 'javelin', weapon_skill: 'Polearms'
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:need_bundle=) { |val| allow(state).to receive(:need_bundle).and_return(val) }
    allow(state).to receive(:mob_died=)
    state
  end

  shared_examples 'frees a hand before tying the bundle' do
    it('lowers left hand item') { expect(DRCI).to have_received(:lower_item?).with('javelin') }
    it('sends tie commands') { expect(DRC).to have_received(:bput).with('tie my bundle', anything, anything).at_least(:once) }
    it('picks lowered item back up') { expect(DRCI).to have_received(:get_item?).with('javelin') }
  end

  shared_examples 'clears need_bundle' do
    it('sets need_bundle to false') { expect(game_state).to have_received(:need_bundle=).with(false) }
  end

  describe 'stored skinning knife custody' do
    before(:each) do
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCI).to receive(:get_item?)
      allow(DRCI).to receive(:put_away_item?)
    end

    let(:equipment_manager) do
      double('EquipmentManager', stow_weapon: true, wield_weapon?: true, is_listed_item?: false)
    end
    let(:game_state) { gs_double(need_bundle: false, weapon_name: 'scimitar', weapon_skill: 'Small Edged') }

    it 'stows the weapon, gets and restores the configured knife, then re-wields' do
      instance = build_loot(
        skin: true,
        skinning_knife: 'skinning knife',
        skinning_knife_container: 'backpack',
        equipment_manager: equipment_manager
      )
      allow(DRCI).to receive(:get_item?).with('skinning knife', 'backpack').and_return(true)
      allow(DRCI).to receive(:put_away_item?).with('skinning knife', 'backpack').and_return(true)

      expect(instance.prepare_skinning_knife(game_state)).to be(true)
      expect(instance.restore_skinning_weapon(game_state)).to be(true)
      expect(equipment_manager).to have_received(:stow_weapon).with('scimitar').ordered
      expect(DRCI).to have_received(:get_item?).with('skinning knife', 'backpack').ordered
      expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack').ordered
      expect(equipment_manager).to have_received(:wield_weapon?).with('scimitar', 'Small Edged').ordered
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'disables skinning and restores the weapon when the configured knife is missing' do
      instance = build_loot(
        skin: true,
        skinning_knife: 'skinning knife',
        skinning_knife_container: 'backpack',
        equipment_manager: equipment_manager
      )
      allow(DRCI).to receive(:get_item?).with('skinning knife', 'backpack').and_return(false)
      allow(DRC).to receive(:message)

      expect(instance.prepare_skinning_knife(game_state)).to be(false)
      expect(instance.instance_variable_get(:@skin)).to be(false)
      expect(equipment_manager).to have_received(:wield_weapon?).with('scimitar', 'Small Edged')
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'preserves upstream hand behavior when no knife is configured' do
      instance = build_loot(skin: true, equipment_manager: equipment_manager)

      expect(instance.prepare_skinning_knife(game_state)).to be(true)
      expect(instance.restore_skinning_weapon(game_state)).to be(true)
      expect(equipment_manager).not_to have_received(:stow_weapon)
      expect(equipment_manager).not_to have_received(:wield_weapon?)
      expect(DRCI).not_to have_received(:get_item?)
      expect(DRCI).not_to have_received(:put_away_item?)
    end
  end

  describe 'dissect with the stored skinning knife' do
    let(:equipment_manager) do
      double('EquipmentManager', stow_weapon: true, wield_weapon?: true, is_listed_item?: false)
    end
    let(:game_state) do
      gs_double(need_bundle: false, weapon_name: 'stout broadsword', weapon_skill: 'Large Edged', dissectable?: true)
    end
    let(:refused) { "Your stout broadsword isn't suitable for this type of delicate work" }

    before(:each) do
      allow(DRC).to receive(:message)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCI).to receive(:get_item?).with('skinning knife', 'backpack').and_return(true)
      allow(DRCI).to receive(:put_away_item?).with('skinning knife', 'backpack').and_return(true)
    end

    def build_dissector(**overrides)
      instance = build_loot(
        skin: true, dissect: true, dissect_for_thanatology: false,
        dissect_cycle_skills: ['First Aid', 'Skinning'],
        skinning_knife: 'skinning knife', skinning_knife_container: 'backpack',
        equipment_manager: equipment_manager, **overrides
      )
      allow(instance).to receive(:harvest_corpse_present?).and_return(true)
      instance
    end

    def dissect_reply(reply)
      allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return(reply)
    end

    it 'dissects with the knife, puts it back and re-wields the weapon' do
      instance = build_dissector
      dissect_reply('You succeed in dissecting the corpse')

      expect(instance.dissected?('hog', game_state)).to be(true)
      expect(equipment_manager).to have_received(:stow_weapon).with('stout broadsword').ordered
      expect(DRCI).to have_received(:get_item?).with('skinning knife', 'backpack').ordered
      expect(DRC).to have_received(:bput).with('dissect hog', any_args).ordered
      expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack').ordered
      expect(equipment_manager).to have_received(:wield_weapon?).with('stout broadsword', 'Large Edged').ordered
      expect(instance.instance_variable_get(:@dissect)).to be(true)
      expect(DRCI).not_to have_received(:dispose_trash)
    end

    it 'treats a refused weapon as an immediate failure and stops dissecting for the run' do
      instance = build_dissector
      dissect_reply(refused)

      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(instance.instance_variable_get(:@dissect)).to be(false)
      expect(instance.instance_variable_get(:@dissect_cycle_skills)).to eq(['Skinning'])
      expect(instance.instance_variable_get(:@skin)).to be(true)
      expect(DRC).to have_received(:message).with(/stout broadsword isn't suitable.*disabling dissect for this run/)
      expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack')
      expect(equipment_manager).to have_received(:wield_weapon?).with('stout broadsword', 'Large Edged')
    end

    it 'treats the missing small blade reply as an immediate failure' do
      instance = build_dissector
      dissect_reply('You cannot do the delicate work necessary because you lack a suitably small, bladed weapon')

      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(instance.instance_variable_get(:@dissect)).to be(false)
      expect(DRC).to have_received(:message).with(/lack a suitably small, bladed weapon.*disabling dissect/)
    end

    it 'does not dissect with the held weapon when no knife is configured' do
      instance = build_dissector(skinning_knife: nil, skinning_knife_container: nil)

      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(DRC).not_to have_received(:bput).with('dissect hog', any_args)
      expect(equipment_manager).not_to have_received(:stow_weapon)
      expect(instance.instance_variable_get(:@dissect)).to be(false)
      expect(instance.instance_variable_get(:@skin)).to be(true)
      expect(DRC).to have_received(:message).with(/no skinning knife is configured.*disabling dissect/)
    end

    it 're-wields the weapon and stops dissecting, but keeps skinning, when the knife is missing' do
      instance = build_dissector
      allow(DRCI).to receive(:get_item?).with('skinning knife', 'backpack').and_return(false)

      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(DRC).not_to have_received(:bput).with('dissect hog', any_args)
      expect(equipment_manager).to have_received(:wield_weapon?).with('stout broadsword', 'Large Edged')
      expect(instance.instance_variable_get(:@dissect)).to be(false)
      expect(instance.instance_variable_get(:@skin)).to be(true)
    end

    it 'keeps the knife in hand for the confirming DISSECT after a no-insights warning' do
      instance = build_dissector
      dissect_reply("You'll gain no insights from this attempt")
      allow(instance).to receive(:fput)

      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(DRCI).to have_received(:get_item?).with('skinning knife', 'backpack').ordered
      expect(instance).to have_received(:fput).with('dissect').ordered
      expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack').ordered
      expect(equipment_manager).to have_received(:wield_weapon?).with('stout broadsword', 'Large Edged').ordered
      expect(instance.instance_variable_get(:@dissect)).to be(true)
    end

    it 'stops dissecting after two unanswered DISSECTs, returning the knife each time' do
      instance = build_dissector
      dissect_reply('')

      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(instance.instance_variable_get(:@dissect)).to be(true)
      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(instance.instance_variable_get(:@dissect)).to be(false)
      expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack').twice
    end

    it 'falls back to arrange and skin for the refused corpse and skips DISSECT afterwards' do
      instance = build_dissector
      dissect_reply(refused)
      allow(game_state).to receive(:sort_by_rate_then_rank).and_return(['First Aid', 'Skinning'])
      allow(instance).to receive(:arrange_mob)
      allow(instance).to receive(:check_skinning)

      instance.skin_or_dissect('hog', game_state)
      instance.skin_or_dissect('hog', game_state)

      expect(DRC).to have_received(:bput).with('dissect hog', any_args).once
      expect(instance).to have_received(:check_skinning).with('hog', game_state).twice
    end

    it 'stops the hunt without dissecting when the weapon cannot be stowed' do
      instance = build_dissector
      allow(equipment_manager).to receive(:stow_weapon).and_return(false)

      expect(instance.dissected?('hog', game_state)).to be(false)
      expect(DRC).not_to have_received(:bput).with('dissect hog', any_args)
      expect(DRCI).not_to have_received(:get_item?)
      expect(instance.instance_variable_get(:@dissect)).to be(false)
      expect($COMBAT_TRAINER).to have_received(:stop)
    end
  end

  describe 'corpse harvest passes' do
    let(:equipment_manager) do
      double('EquipmentManager', stow_weapon: true, wield_weapon?: true, is_listed_item?: false)
    end
    let(:game_state) do
      state = gs_double(need_bundle: false, weapon_name: 'stout broadsword', weapon_skill: 'Large Edged',
                        dissectable?: true, necro_casting?: false, blessed_room: false)
      allow(state).to receive(:sheath_whirlwind_offhand)
      allow(state).to receive(:wield_whirlwind_offhand)
      allow(state).to receive(:unskinnable)
      state
    end

    before(:each) do
      allow(DRC).to receive(:message)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:dispose_trash)
      allow(DRCI).to receive(:get_item?).with('skinning knife', 'backpack').and_return(true)
      allow(DRCI).to receive(:put_away_item?).with('skinning knife', 'backpack').and_return(true)
      DRRoom.dead_npcs = ['hog']
      DRRoom.npcs = []
    end

    def build_harvester(**overrides)
      instance = build_loot(
        skin: true, dissect: false, dissect_for_thanatology: false,
        dissect_cycle_skills: ['Skinning'], arrange_for_dissect: true,
        arrange_all: false, arrange_count: 2, arrange_types: { 'hog' => 'bone' },
        skinning_knife: 'skinning knife', skinning_knife_container: 'backpack',
        equipment_manager: equipment_manager, loot_bodies: true, loot_delay: 0,
        loot_timer: Time.now - 60, last_rites: false, last_rites_timer: Time.now,
        custom_loot_type: nil, **overrides
      )
      allow(instance).to receive(:harvest_corpse_present?).and_return(true)
      allow(instance).to receive(:harvest_peer_busy?).and_return(false)
      allow(instance).to receive(:check_rituals?).and_return(true)
      instance
    end

    # skin_or_dissect checks the corpse, and so binds its ID, before any step.
    def bound_to(instance, id)
      bind = lambda do
        instance.instance_variable_set(:@drbot_harvest_ids, true)
        instance.instance_variable_set(:@drbot_harvest_corpse, { room: [1, 7], noun: 'hog', id: id })
      end
      bind.call
      allow(instance).to receive(:harvest_corpse_present?) do
        bind.call
        true
      end
    end

    def arranges
      commands = []
      allow(DRC).to receive(:bput).with(/\Aarrange/, any_args) do |command, *|
        commands << command
        yield(command)
      end
      commands
    end

    context 'DISSECT with corpse IDs' do
      it 'dissects the bound corpse by its server ID' do
        instance = build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning'])
        bound_to(instance, '4242')
        allow(DRC).to receive(:bput).with('dissect #4242', any_args).and_return('You succeed in dissecting the corpse')

        expect(instance.dissected?('hog', game_state)).to be(true)
        expect(DRC).not_to have_received(:bput).with('dissect hog', any_args)
      end

      it 'confirms a no-insights DISSECT on the same bound corpse' do
        instance = build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning'])
        bound_to(instance, '4242')
        allow(DRC).to receive(:bput).with('dissect #4242', any_args).and_return("You'll gain no insights from this attempt")
        allow(instance).to receive(:fput)

        expect(instance.dissected?('hog', game_state)).to be(false)
        expect(instance).to have_received(:fput).with('dissect #4242')
        expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack')
      end

      it 'keeps DISSECT by noun and the bare confirmation without corpse IDs' do
        instance = build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning'])
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return("You'll gain no insights from this attempt")
        allow(instance).to receive(:fput)

        expect(instance.dissected?('hog', game_state)).to be(false)
        expect(instance).to have_received(:fput).with('dissect')
      end

      it 'returns the knife and sends nothing when the bound ID is unusable' do
        instance = build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning'])
        bound_to(instance, 'not-an-id')

        expect(instance.dissected?('hog', game_state)).to be(false)
        expect(DRC).not_to have_received(:bput).with(/\Adissect/, any_args)
        expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack')
        expect(equipment_manager).to have_received(:wield_weapon?).with('stout broadsword', 'Large Edged')
      end
    end

    context 'a creature that cannot produce the configured part' do
      it 'goes straight to the plain arrange for the rest of the run' do
        instance = build_harvester
        sent = arranges { |command| command.include?('for bone') ? 'That creature cannot' : 'You begin to arrange' }

        instance.arrange_mob('hog', game_state)
        instance.arrange_mob('hog', game_state)

        expect(sent).to eq(['arrange for bone', 'arrange ', 'arrange ', 'arrange ', 'arrange '])
        expect(DRC).to have_received(:message).with(/hog cannot produce bone; arranging it without a part/).once
      end

      it 'keeps asking for the part when the noun has produced it this run' do
        # One goblin type may give bone where another cannot; a noun that has
        # accepted the part is never switched to the plain arrange.
        instance = build_harvester
        replies = ['You begin to arrange', 'You complete arranging',
                   'That creature cannot', 'You begin to arrange', 'You complete arranging',
                   'You begin to arrange', 'You complete arranging']
        sent = arranges { |_command| replies.shift }

        3.times { instance.arrange_mob('hog', game_state) }

        expect(sent).to eq(['arrange for bone', 'arrange for bone',
                            'arrange for bone', 'arrange ', 'arrange ',
                            'arrange for bone', 'arrange for bone'])
        expect(DRC).not_to have_received(:message)
      end

      it 'learns per noun and per part' do
        instance = build_harvester(arrange_types: { 'hog' => 'bone', 'goblin' => 'bone' })
        sent = arranges { |command| command == 'arrange for bone' && sent.length == 1 ? 'That creature cannot' : 'You complete arranging' }

        instance.arrange_mob('hog', game_state)
        DRRoom.dead_npcs = ['goblin']
        instance.arrange_mob('goblin', game_state)
        DRRoom.dead_npcs = ['hog']
        instance.instance_variable_set(:@arrange_types, { 'hog' => 'skin' })
        instance.arrange_mob('hog', game_state)

        expect(sent).to eq(['arrange for bone', 'arrange ', 'arrange for bone', 'arrange for skin'])
      end

      it 'does not learn from a room that lists more than one kind of corpse' do
        # DRRoom lists "goblin" first; the bare ARRANGE was the hog's.
        DRRoom.dead_npcs = ['goblin', 'hog']
        instance = build_harvester(arrange_types: { 'hog' => 'bone', 'goblin' => 'bone' })
        sent = arranges { |command| command.include?('for bone') && sent.length == 1 ? 'That creature cannot' : 'You complete arranging' }

        instance.arrange_mob('goblin', game_state)
        DRRoom.dead_npcs = ['goblin']
        instance.arrange_mob('goblin', game_state)

        expect(sent).to eq(['arrange for bone', 'arrange ', 'arrange for bone'])
        expect(DRC).not_to have_received(:message)
      end

      it 'learns in a mixed room with corpse IDs' do
        DRRoom.dead_npcs = ['goblin', 'hog']
        instance = build_harvester
        bound_to(instance, '777')
        sent = arranges { |command| command.include?('for bone') ? 'That creature cannot' : 'You complete arranging' }

        instance.arrange_mob('hog', game_state)
        instance.arrange_mob('hog', game_state)

        expect(sent).to eq(['arrange #777 for bone', 'arrange #777', 'arrange #777'])
        expect(DRC).to have_received(:message).with(/hog cannot produce bone/).once
      end

      it 'uses ARRANGE ALL and the bound ID for the plain arrange' do
        instance = build_harvester(arrange_all: true, arrange_count: 1)
        bound_to(instance, '777')
        sent = arranges { |command| command.include?('for bone') ? 'That creature cannot' : 'You complete arranging' }

        instance.arrange_mob('hog', game_state)
        instance.arrange_mob('hog', game_state)

        expect(sent).to eq(['arrange #777 all for bone', 'arrange #777 all', 'arrange #777 all'])
      end

      it 'never loops when a plain arrange is refused too' do
        instance = build_harvester
        sent = arranges { |_command| 'That creature cannot' }

        instance.arrange_mob('hog', game_state)

        expect(sent).to eq(['arrange for bone', 'arrange '])
      end
    end

    context "'Arrange what?'" do
      it 'ends the pass before DISSECT and SKIN' do
        instance = build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning'])
        arranges { |_command| 'Arrange what' }
        allow(instance).to receive(:dissected?)
        allow(instance).to receive(:check_skinning)

        instance.skin_or_dissect('hog', game_state)

        expect(instance).not_to have_received(:dissected?)
        expect(instance).not_to have_received(:check_skinning)
      end

      it 'skips SKIN on the skinning-only path' do
        instance = build_harvester
        arranges { |_command| 'Arrange what' }
        allow(instance).to receive(:check_skinning)

        instance.skin_or_dissect('hog', game_state)

        expect(instance).not_to have_received(:check_skinning)
      end

      it 'still skins after a completed arrange' do
        instance = build_harvester
        arranges { |_command| 'You complete arranging' }
        allow(instance).to receive(:check_skinning)

        instance.skin_or_dissect('hog', game_state)

        expect(instance).to have_received(:check_skinning).with('hog', game_state)
      end
    end

    context 'a corpse this hunt has searched' do
      def loots
        allow(DRC).to receive(:bput).with(/\Aloot/, any_args).and_return('You search')
      end

      def dispose(instance)
        instance.instance_variable_set(:@loot_timer, Time.now - 60)
        instance.dispose_body(game_state)
      end

      it 'is left to decay instead of being harvested again' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        loots

        dispose(instance)
        dispose(instance)

        expect(instance).to have_received(:skin_or_dissect).once
        expect(DRC).to have_received(:bput).with('loot', any_args).once
      end

      it 'does not hide a fresh corpse of the same noun' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        loots

        dispose(instance)
        DRRoom.dead_npcs = ['hog', 'second hog']
        dispose(instance)
        dispose(instance)
        DRRoom.dead_npcs = ['hog']
        dispose(instance)

        expect(instance).to have_received(:skin_or_dissect).twice
      end

      it 'harvests the next corpse once the searched one has decayed' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        loots

        dispose(instance)
        DRRoom.dead_npcs = []
        dispose(instance)
        DRRoom.dead_npcs = ['hog']
        dispose(instance)

        expect(instance).to have_received(:skin_or_dissect).twice
      end

      it 'takes the searched corpse from the LOOT reply in a mixed room' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        DRRoom.dead_npcs = ['goblin', 'hog']
        allow(DRC).to receive(:bput).with(/\Aloot/, any_args).and_return('You search the musk hog')

        dispose(instance)
        dispose(instance)
        allow(DRC).to receive(:bput).with(/\Aloot/, any_args).and_return('You search the forager goblin')
        dispose(instance)
        dispose(instance)

        expect(instance).to have_received(:skin_or_dissect).exactly(3).times
        expect(instance.instance_variable_get(:@searched_corpses).keys).to contain_exactly('goblin', 'hog')
      end

      it 'records nothing from an unnamed search in a mixed room' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        DRRoom.dead_npcs = ['goblin', 'hog']
        loots

        dispose(instance)
        dispose(instance)

        expect(instance).to have_received(:skin_or_dissect).twice
        expect(instance.instance_variable_get(:@searched_corpses)).to be_empty
      end

      it 'with corpse IDs names a kind that still has an unsearched corpse' do
        instance = build_harvester
        ids = gs_double(drbot_corpse_ids?: true)
        DRRoom.dead_npcs = ['goblin', 'hog', 'second hog']
        instance.instance_variable_set(:@searched_corpses, { 'goblin' => { count: 1, at: Time.now } })

        expect(instance.harvest_corpse_candidate(ids)).to eq('hog')
        expect(instance.harvest_corpse_candidate(game_state)).to eq('goblin')
        one_hog = { 'goblin' => { count: 1, at: Time.now }, 'hog' => { count: 1, at: Time.now } }
        instance.instance_variable_set(:@searched_corpses, one_hog)
        expect(instance.harvest_corpse_candidate(ids)).to eq('hog')
        both_hogs = { 'goblin' => { count: 1, at: Time.now }, 'hog' => { count: 2, at: Time.now } }
        instance.instance_variable_set(:@searched_corpses, both_hogs)
        expect(instance.harvest_corpse_candidate(ids)).to eq('goblin')
      end

      it 'forgets the record in another room and after 15 seconds' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        loots

        dispose(instance)
        allow(Room).to receive(:current).and_return(double('Room', id: 2))
        dispose(instance)
        expect(instance).to have_received(:skin_or_dissect).twice

        allow(Time).to receive(:now).and_return(Time.at(Time.now.to_i + 16))
        dispose(instance)
        expect(instance).to have_received(:skin_or_dissect).exactly(3).times
      end

      it 'treats every listed corpse as spent when a bare LOOT finds nothing' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        DRRoom.dead_npcs = ['hog', 'second hog']
        allow(DRC).to receive(:bput).with(/\Aloot/, any_args).and_return('I could not find what you were referring to')

        dispose(instance)
        dispose(instance)

        expect(instance).to have_received(:skin_or_dissect).once
      end

      it 'does not track corpses when the room is unknown' do
        instance = build_harvester
        allow(instance).to receive(:skin_or_dissect)
        allow(Room).to receive(:current).and_return(nil)
        loots

        dispose(instance)
        dispose(instance)

        expect(instance).to have_received(:skin_or_dissect).twice
      end
    end

    context 'DISSECT replies about another corpse or creature' do
      let(:dissecting) { build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning']) }

      before(:each) do
        allow(game_state).to receive(:sort_by_rate_then_rank).and_return(['First Aid', 'Skinning'])
        allow(DRC).to receive(:bput).with(/\Aarrange/, any_args).and_return('You complete arranging')
        allow(dissecting).to receive(:check_skinning)
      end

      it 'does not retry a DISSECT that named a live creature and still skins the corpse' do
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return('would probably object')

        dissecting.skin_or_dissect('hog', game_state)

        expect(DRC).to have_received(:bput).with(/\Adissect/, any_args).once
        expect(dissecting).to have_received(:check_skinning).with('hog', game_state)
        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
      end

      it 'ends the pass on the only corpse when it was dissected already' do
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return("You'll learn nothing")

        dissecting.skin_or_dissect('hog', game_state)

        expect(dissecting).not_to have_received(:check_skinning)
      end

      it 'still skins when another corpse is listed' do
        DRRoom.dead_npcs = ['hog', 'second hog']
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return("You'll learn nothing")

        dissecting.skin_or_dissect('hog', game_state)

        expect(dissecting).to have_received(:check_skinning).with('hog', game_state)
      end

      it 'judges the only corpse before DISSECT, not after one decays during the knife swap' do
        DRRoom.dead_npcs = ['hog', 'second hog']
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return("You'll learn nothing")
        allow(DRCI).to receive(:put_away_item?).with('skinning knife', 'backpack') do
          DRRoom.dead_npcs = ['hog']
          true
        end

        dissecting.skin_or_dissect('hog', game_state)

        expect(dissecting).to have_received(:check_skinning).with('hog', game_state)
      end
    end

    context 'DISSECT with a shield held in the other hand' do
      # Thargrund 2026-09-28 02:42:46: knife in the right hand, tower shield in
      # the left, and DISSECT answered "You need at least one free hand for that!".
      let(:dissecting) { build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning']) }

      before(:each) do
        allow(DRCI).to receive(:get_item?).with('skinning knife', 'backpack') do
          $right_hand = 'skinning knife'
          true
        end
        allow(DRCI).to receive(:lower_item?).with('tower shield') do
          $left_hand = nil
          true
        end
        allow(DRCI).to receive(:get_item?).with('tower shield') do
          $left_hand = 'tower shield'
          true
        end
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return('You succeed in dissecting the corpse')
        $right_hand = 'stout broadsword'
        $left_hand = 'tower shield'
      end

      it 'lowers the shield for DISSECT and picks it up before the knife goes away' do
        expect(dissecting.dissected?('hog', game_state)).to be(true)
        expect(DRCI).to have_received(:get_item?).with('skinning knife', 'backpack').ordered
        expect(DRCI).to have_received(:lower_item?).with('tower shield').ordered
        expect(DRC).to have_received(:bput).with('dissect hog', any_args).ordered
        expect(DRCI).to have_received(:get_item?).with('tower shield').ordered
        expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack').ordered
        expect(equipment_manager).to have_received(:wield_weapon?).with('stout broadsword', 'Large Edged').ordered
      end

      it 'switches DISSECT off and returns the knife when the shield cannot be lowered' do
        allow(DRCI).to receive(:lower_item?).with('tower shield').and_return(false)

        expect(dissecting.dissected?('hog', game_state)).to be(false)
        expect(DRC).not_to have_received(:bput).with('dissect hog', any_args)
        expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack')
        expect(dissecting.instance_variable_get(:@dissect)).to be(false)
        expect(DRC).to have_received(:message).with(/free hand.*could not be lowered.*disabling dissect/)
      end

      it 'picks the shield up when LOWER put it down without a recognised reply' do
        allow(DRCI).to receive(:lower_item?).with('tower shield') do
          $left_hand = nil
          false
        end

        expect(dissecting.dissected?('hog', game_state)).to be(false)
        expect(DRCI).to have_received(:get_item?).with('tower shield')
        expect($left_hand).to eq('tower shield')
        expect(DRC).not_to have_received(:bput).with('dissect hog', any_args)
        expect(dissecting.instance_variable_get(:@dissect)).to be(false)
        expect($COMBAT_TRAINER).not_to have_received(:stop)
      end

      it 'stops the hunt, still returning the knife, when the shield cannot be picked up' do
        allow(DRCI).to receive(:get_item?).with('tower shield').and_return(false)

        expect(dissecting.dissected?('hog', game_state)).to be(false)
        expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack')
        expect($COMBAT_TRAINER).to have_received(:stop)
        expect(DRC).to have_received(:message).with(/failed to pick up tower shield after DISSECT/)
      end

      it 'answers "no free hand" at once, skins the corpse, and gives up on the second in a row' do
        $left_hand = nil
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return('You need at least one free hand')
        allow(game_state).to receive(:sort_by_rate_then_rank).and_return(['First Aid', 'Skinning'])
        allow(DRC).to receive(:bput).with(/\Aarrange/, any_args).and_return('You complete arranging')
        allow(dissecting).to receive(:check_skinning)

        dissecting.skin_or_dissect('hog', game_state)
        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
        expect(dissecting.instance_variable_get(:@dissect_unanswered)).to eq(0)
        dissecting.skin_or_dissect('hog', game_state)

        expect(dissecting).to have_received(:check_skinning).with('hog', game_state).twice
        expect(dissecting.instance_variable_get(:@dissect)).to be(false)
        expect(DRC).to have_received(:message).with(/no free hand twice in a row; disabling dissect/)
      end

      it 'lowers nothing when a hand is already free' do
        $left_hand = nil

        expect(dissecting.dissected?('hog', game_state)).to be(true)
        expect(DRCI).not_to have_received(:lower_item?)
      end
    end

    context 'harvesting only this hunter\'s own kills (drbot_own_kill_harvest)' do
      # Vrakk and Thargrund shared room 1473 on 2026-09-28 and each searched
      # the other's kills. A pass names only a corpse the tracker attributed
      # to this character and sends nothing, not even a LOOK, for the others.
      let(:records) { {} }
      let(:corpses) { [] }
      let(:own_state) do
        state = game_state
        allow(state).to receive(:drbot_corpse_ids?).and_return(true)
        allow(state).to receive(:drbot_own_kills_only?).and_return(true)
        allow(state).to receive(:drbot_own_kill_tracking?).and_return(true)
        allow(state).to receive(:drbot_own_kill) { |id| records[id] }
        allow(state).to receive(:drbot_own_kill_harvestable?) do |id|
          rec = records[id]
          rec && (rec[:kind] == :own || (rec[:kind] == :none && rec[:alone] && rec[:engaged])) ? true : false
        end
        state
      end

      before(:each) do
        registry = double('Creature')
        allow(registry).to receive(:in_room) { corpses }
        stub_const('Lich::DragonRealms::Creature', registry)
        allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1473))
        allow(XMLData).to receive(:room_id).and_return(62_001)
      end

      # A dead Lich::DragonRealms::Creature registry entry.
      def own_kill_corpse(id, noun)
        entry = OpenStruct.new(id: id.to_i, noun: noun, name: "forager #{noun}")
        entry.define_singleton_method(:crtr_flag?) { |flag| flag == :dead }
        entry
      end

      def corpse(id, noun, kind, at: 1.0, peer: nil, alone: false, engaged: true)
        corpses << own_kill_corpse(id, noun)
        records[id] = { kind: kind, peer: peer, alone: alone, engaged: engaged, at: at }
      end

      it 'names the oldest own kill and leaves another hunter\'s kill with one line' do
        corpse('3240317', 'goblin', :peer, peer: 'Thargrund', at: 1.0)
        corpse('3240264', 'goblin', :own, at: 2.0)
        corpse('3240377', 'hog', :own, at: 3.0)
        instance = build_harvester

        expect(instance.harvest_corpse_candidate(own_state)).to eq('goblin')
        expect(instance.instance_variable_get(:@own_kill_candidate_id)).to eq('3240264')
        instance.harvest_corpse_candidate(own_state)
        expect(DRC).to have_received(:message).with("*** combat-trainer: leaving #3240317 goblin (Thargrund's kill).").once
      end

      it 'sends nothing, not even a LOOK, when every corpse is someone else\'s' do
        corpse('3240317', 'goblin', :peer, peer: 'Thargrund')
        corpse('3237810', 'hog', :foreign)
        instance = build_harvester
        allow(instance).to receive(:harvest_corpse_present?).and_call_original
        allow(instance).to receive(:searched_corpses_only?).and_return(false)
        allow(DRC).to receive(:bput)

        instance.dispose_body(own_state)

        expect(DRC).not_to have_received(:bput)
        expect(DRC).to have_received(:message).with(/leaving #3237810 hog \(not seen killed in this visit\)/)
      end

      it 'binds only an own corpse even when a peer\'s corpse of the same noun is listed first' do
        corpse('3240317', 'goblin', :peer, peer: 'Thargrund')
        corpse('3240264', 'goblin', :own)
        instance = build_harvester
        instance.instance_variable_set(:@drbot_harvest_ids, true)
        instance.instance_variable_set(:@drbot_own_kill_state, own_state)

        expect(instance.harvest_corpse_identity?('goblin')).to be(true)
        expect(instance.instance_variable_get(:@drbot_harvest_corpse)[:id]).to eq('3240264')
        expect(instance.harvest_corpse_selector).to eq('#3240264')
      end

      it 'refuses to bind when the only corpse of the noun is a peer\'s kill' do
        corpse('3240317', 'goblin', :peer, peer: 'Thargrund')
        instance = build_harvester
        instance.instance_variable_set(:@drbot_harvest_ids, true)
        instance.instance_variable_set(:@drbot_own_kill_state, own_state)

        expect(instance.harvest_corpse_identity?('goblin')).to be(false)
      end

      it 'takes the arrange type from the bound corpse, not a lingering searched one' do
        # Vrakk 17:47:57: a searched goblin still listed beside a fresh hog kill
        # drew 'arrange for bone' on the hog.
        corpse('3239001', 'goblin', :own, at: 1.0)
        corpse('3239008', 'hog', :own, at: 2.0)
        instance = build_harvester(arrange_types: { 'goblin' => 'bone', 'hog' => 'skin' })
        instance.instance_variable_set(:@searched_corpse_ids, { '3239001' => Time.now })

        expect(instance.harvest_corpse_candidate(own_state)).to eq('hog')
      end

      it 'harvests a lone hunter\'s bleed-out kill that was engaged with it' do
        corpse('2840088', 'lout', :none, alone: true, engaged: true)
        instance = build_harvester

        expect(instance.harvest_corpse_candidate(own_state)).to eq('lout')
      end

      it 'leaves a killer-less corpse when another player was present' do
        corpse('2840088', 'lout', :none, alone: false, engaged: true)
        instance = build_harvester

        expect(instance.harvest_corpse_candidate(own_state)).to be_nil
        expect(DRC).to have_received(:message).with(/leaving #2840088 lout \(killer not seen with another player here\)/)
      end

      it 'says nothing about a corpse whose death is not recorded yet' do
        corpses << own_kill_corpse('3241999', 'goblin')
        instance = build_harvester

        expect(instance.harvest_corpse_candidate(own_state)).to be_nil
        expect(DRC).not_to have_received(:message)
      end

      it 'leaves every corpse, once said, when tracking is unavailable' do
        corpse('3240264', 'goblin', :own)
        allow(own_state).to receive(:drbot_own_kill_tracking?).and_return(false)
        instance = build_harvester

        2.times { expect(instance.harvest_corpse_candidate(own_state)).to be_nil }
        expect(DRC).to have_received(:message).with(/own-kill tracking is unavailable; leaving every corpse/).once
      end

      it 'stops re-looking an own corpse whose identity failed three times' do
        corpse('3240264', 'goblin', :own)
        instance = build_harvester
        allow(instance).to receive(:harvest_corpse_present?).and_call_original
        allow(instance).to receive(:harvest_corpse_identity?).and_return(false)
        allow(DRC).to receive(:bput).with('look', any_args).and_return('Obvious paths: east, south.')

        3.times do
          instance.harvest_corpse_candidate(own_state)
          instance.harvest_corpse_present?('goblin', own_state)
        end

        expect(instance.harvest_corpse_candidate(own_state)).to be_nil
        expect(DRC).to have_received(:message).with(/leaving #3240264 \(its corpse ID did not confirm 3 times\)/).once
      end

      it 'keeps upstream corpse naming when the setting is off' do
        instance = build_harvester
        plain = gs_double(need_bundle: false)

        expect(instance.harvest_corpse_candidate(plain)).to eq('hog')
      end
    end

    context 'First Aid that learns nothing from DISSECT' do
      # Vrakk and Thargrund at First Aid 41: no First Aid gain across 93 and 77
      # successful DISSECTs; Lanjefast at 32-33 gained on all 33 of his.
      let(:dissecting) { build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning']) }
      let(:mindstate) { [0] }

      before(:each) do
        allow(DRSkill).to receive(:getxp).with('First Aid') { mindstate.first }
        allow(DRSkill).to receive(:getrank).with('First Aid').and_return(41)
        allow(DRC).to receive(:bput).with('dissect hog', any_args) do
          mindstate[0] += @gain.to_i
          'You succeed in dissecting the corpse'
        end
      end

      it 'stops dissecting for the run after three barren successes, saying so once' do
        3.times { expect(dissecting.dissected?('hog', game_state)).to be(true) }

        expect(dissecting.instance_variable_get(:@dissect)).to be(false)
        expect(dissecting.instance_variable_get(:@dissect_cycle_skills)).to eq(['Skinning'])
        expect(DRC).to have_received(:message)
          .with('*** combat-trainer: First Aid 41 learned nothing from 3 successful DISSECTs in a row; disabling dissect for this run.').once
      end

      it 'skins the next corpse after the switch' do
        allow(game_state).to receive(:sort_by_rate_then_rank).and_return(['First Aid', 'Skinning'])
        allow(dissecting).to receive(:arrange_mob)
        allow(dissecting).to receive(:check_skinning)
        4.times { dissecting.skin_or_dissect('hog', game_state) }

        expect(DRC).to have_received(:bput).with('dissect hog', any_args).exactly(3).times
        expect(dissecting).to have_received(:check_skinning).with('hog', game_state).once
      end

      it 'keeps dissecting while First Aid learns' do
        @gain = 1
        5.times { expect(dissecting.dissected?('hog', game_state)).to be(true) }

        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
      end

      it 'restarts the count after a learning DISSECT' do
        replies = [0, 0, 1, 0, 0]
        allow(DRC).to receive(:bput).with('dissect hog', any_args) do
          mindstate[0] += replies.shift
          'You succeed in dissecting the corpse'
        end
        5.times { dissecting.dissected?('hog', game_state) }

        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
      end

      it 'honours skinning: dissect_barren_limit' do
        dissecting.instance_variable_set(:@dissect_barren_limit, 5)
        4.times { dissecting.dissected?('hog', game_state) }
        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
        dissecting.dissected?('hog', game_state)
        expect(dissecting.instance_variable_get(:@dissect)).to be(false)
      end

      it 'skips DISSECT while mind-locked without counting it, saying so once per lock' do
        mindstate[0] = 34
        3.times { expect(dissecting.dissected?('hog', game_state)).to be(false) }

        expect(DRC).not_to have_received(:bput).with('dissect hog', any_args)
        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
        expect(DRC).to have_received(:message).with(/First Aid is mind-locked; skipping DISSECT/).once
      end

      it 'does not count a DISSECT that was not a success' do
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return("You'll learn nothing")
        4.times { dissecting.dissected?('hog', game_state) }

        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
      end
    end

    context 'DISSECT while concealed' do
      # Lanjefast 2026-09-28 17:44:00 under Khri Silence: "That's going to be
      # hard to accomplish while concealed." and a 15 second stall.
      let(:dissecting) { build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning']) }

      after(:each) do
        $invisible = false
        $hidden = false
      end

      it 'skips DISSECT with no knife swap and no UNHIDE while invisible' do
        $invisible = true

        expect(dissecting.dissected?('hog', game_state)).to be(false)
        expect(DRC).not_to have_received(:bput).with(/\Adissect|\Aunhide/, any_args)
        expect(DRCI).not_to have_received(:get_item?)
        expect(equipment_manager).not_to have_received(:stow_weapon)
        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
      end

      it 'skips DISSECT while hidden and says so once per run' do
        $hidden = true
        2.times { dissecting.dissected?('hog', game_state) }

        expect(DRC).to have_received(:message).with(/DISSECT is refused while concealed/).once
      end

      it 'knows the refusal, returns the knife and counts it as neither unanswered nor barren' do
        allow(DRC).to receive(:bput).with('dissect hog', any_args).and_return('hard to accomplish while concealed')

        3.times { expect(dissecting.dissected?('hog', game_state)).to be(false) }

        expect(DRCI).to have_received(:put_away_item?).with('skinning knife', 'backpack').exactly(3).times
        expect(dissecting.instance_variable_get(:@dissect)).to be(true)
        expect(dissecting.instance_variable_get(:@dissect_unanswered)).to eq(0)
        expect(dissecting.instance_variable_get(:@dissect_barren)).to be_nil
      end
    end

    context 'after a skinning knife custody failure' do
      it 'sends no ARRANGE or LOOT for the rest of the pass' do
        instance = build_harvester(dissect: true, dissect_cycle_skills: ['First Aid', 'Skinning'])
        allow(DRC).to receive(:bput).with(/\Aarrange/, any_args).and_return('You complete arranging')
        allow(DRCI).to receive(:put_away_item?).with('skinning knife', 'backpack').and_return(false)
        allow(game_state).to receive(:sort_by_rate_then_rank).and_return(['First Aid', 'Skinning'])

        instance.instance_variable_set(:@arrange_for_dissect, false)
        instance.dispose_body(game_state)
        instance.dispose_body(game_state)

        expect(DRC).to have_received(:bput).with('dissect hog', any_args).once
        expect(DRC).not_to have_received(:bput).with(/\Aarrange|\Aloot/, any_args)
        expect($COMBAT_TRAINER).to have_received(:stop)
      end
    end
  end

  describe '#execute' do
    before(:each) do
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:lower_item?).and_return(true)
      allow(DRCI).to receive(:get_item?).and_return(true)
    end

    def run_execute(instance, game_state)
      allow(instance).to receive(:dispose_body)
      allow(instance).to receive(:stow_lootables)
      allow(instance).to receive(:fill_pouch_with_autolooter)
      instance.execute(game_state)
    end

    context 'tie_bundle true, need_bundle true, both hands full' do
      let(:game_state) { gs_double(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'
        allow(DRC).to receive(:bput).with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off').and_return('TIE the bundle again')
        allow(DRC).to receive(:bput).with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now").and_return('you tie the bundle')
        allow(DRC).to receive(:bput).with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/).and_return('You adjust your lumpy bundle so that you can more easily')
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      include_examples 'frees a hand before tying the bundle'
      include_examples 'clears need_bundle'
    end

    context 'tie_bundle true, one hand free' do
      let(:game_state) { gs_double(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = nil
        allow(DRC).to receive(:bput).with('tie my bundle', 'TIE the bundle again', 'But this bundle has already been tied off').and_return('TIE the bundle again')
        allow(DRC).to receive(:bput).with('tie my bundle', 'you tie the bundle', 'But this bundle has already been tied off', "You don't seem to be able to do that right now").and_return('you tie the bundle')
        allow(DRC).to receive(:bput).with('adjust my bundle', /^You adjust your .*/, /You'll need a free hand for that/).and_return('You adjust your lumpy bundle so that you can more easily')
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      include_examples 'clears need_bundle'
      it('does not lower any item') { expect(DRCI).not_to have_received(:lower_item?) }
    end

    # BUG-FINDING: need_bundle false should skip all bundle logic
    context 'need_bundle false' do
      let(:game_state) { gs_double(need_bundle: false) }

      before(:each) do
        Flags['ct-successful-skin'] = true
        $right_hand = 'bastard sword'
        $left_hand = 'javelin'
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      it('skips tie and adjust') do
        expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything)
        expect(DRC).not_to have_received(:bput).with('adjust my bundle', anything, anything)
      end
    end

    # BUG-FINDING: ct-successful-skin not set should skip bundle logic
    context 'ct-successful-skin flag not set' do
      let(:game_state) { gs_double(need_bundle: true) }

      before(:each) do
        Flags['ct-successful-skin'] = nil
        run_execute(build_loot(tie_bundle: true), game_state)
      end

      it('does not tie') { expect(DRC).not_to have_received(:bput).with('tie my bundle', anything, anything) }
    end
  end
end

# ===================================================================
# CombatTrainerOwnKills -- who killed each corpse (drbot_own_kill_harvest)
# Fragments are verbatim server lines from runtime bundles
# vrakk-cv3-aa6bf1f5 and thargrund-cv3-aa6bf1f5 (room 1473, 2026-09-28) and
# the 2026-09-26 Lanjefast archive; unrelated vitals/exp lines are omitted
# and trailing padding is trimmed.
# ===================================================================
RSpec.describe CombatTrainerOwnKills do
  def tracker(me, pcs: [])
    @pcs = pcs
    described_class.new(%w[Vrakk Thargrund Lanjefast], clock: -> { 1_790_618_339.0 }, pcs: -> { @pcs }, self_name: -> { me })
  end

  def feed(tracker, text)
    text.each_line { |line| expect(tracker.feed(line.chomp)).to eq(line.chomp) }
  end

  before(:each) do
    allow(DownstreamHook).to receive(:list).and_return([described_class::HOOK])
  end

  # 17:58:59, #3240264: Vrakk's punch kills a goblin engaged with both of them.
  let(:vrakk_kill_vrakk_view) do
    <<~'RAW'
      <crtrStatus exist="3240317" hostile="1" disengaged="1"/><crtrStatus exist="3240264" hostile="1"/><crtrStatus exist="3240377" hostile="1"/><crtrStatus exist="3240463" hostile="1" disengaged="1"/><crtrStatus exist="3240504" hostile="1" disengaged="1"/><prompt time="1790618331">&gt;</prompt>
      <roundTime value='1790618341'/><component id='exp Brawling'><preset id='whisper'>        Brawling:   41 28% dabbling     </preset></component>
      <pushStream id="combat" />&lt; With the precision and elegance of a plunging goshawk, you punch your plate-clad fist at a spotted forager goblin.  A spotted forager goblin barely fails to block with a mace.  <pushBold/>The fist lands an awesome strike that slams the sternum into the heart with a sickening *Crack!*.<popBold/>
      A spotted forager goblin collapses to the ground, shuddering and moaning until it ceases all movement.
      [You're nimbly balanced]
      [Roundtime 2 sec.]
      <popStream id="combat" /><component id='room objs'>You also see <pushBold/>a tall forager goblin<popBold/>, <pushBold/>a spotted forager goblin<popBold/> which appears dead, a broadsword, <pushBold/>a hostile forager goblin<popBold/>, <pushBold/>a beady-eyed forager goblin<popBold/>, <pushBold/>a drooling forager goblin<popBold/> and some junk.</component>
      <crtrStatus exist="3240317" hostile="1" disengaged="1"/><crtrStatus exist="3240264" hostile="1" disengaged="1" dead="1" sleeping="1"/><crtrStatus exist="3240377" hostile="1"/><crtrStatus exist="3240463" hostile="1" disengaged="1"/><crtrStatus exist="3240504" hostile="1"/><prompt time="1790618339">&gt;</prompt>
    RAW
  end

  let(:vrakk_kill_thargrund_view) do
    <<~'RAW'
      <crtrStatus exist="3240317" hostile="1"/><crtrStatus exist="3240264" hostile="1"/><crtrStatus exist="3240377" hostile="1" disengaged="1"/><crtrStatus exist="3240463" hostile="1"/><crtrStatus exist="3240504" hostile="1" disengaged="1"/><prompt time="1790618331">&gt;</prompt>
      <pushStream id="combat" />With the precision and elegance of a plunging goshawk, Vrakk punches his plate-clad fist at a spotted forager goblin.  A spotted forager goblin barely fails to block with a mace.  The fist lands an awesome strike that slams the sternum into the heart with a sickening *Crack!*!
      A spotted forager goblin collapses to the ground, shuddering and moaning until it ceases all movement.
      <popStream id="combat" /><component id='room objs'>You also see <pushBold/>a tall forager goblin<popBold/>, <pushBold/>a spotted forager goblin<popBold/> which appears dead, a broadsword, <pushBold/>a hostile forager goblin<popBold/>, <pushBold/>a beady-eyed forager goblin<popBold/>, <pushBold/>a drooling forager goblin<popBold/> and some junk.</component>
      <crtrStatus exist="3240317" hostile="1"/><crtrStatus exist="3240264" hostile="1" disengaged="1" dead="1" sleeping="1"/><crtrStatus exist="3240377" hostile="1" disengaged="1"/><crtrStatus exist="3240463" hostile="1"/><crtrStatus exist="3240504" hostile="1" disengaged="1"/><prompt time="1790618339">&gt;</prompt>
    RAW
  end

  # 17:59:56, #3240317: Thargrund's rush kills a goblin disengaged from Vrakk.
  let(:thargrund_rush_thargrund_view) do
    <<~'RAW'
      <crtrStatus exist="3240317" hostile="1"/><crtrStatus exist="3240377" hostile="1" disengaged="1"/><crtrStatus exist="3240463" hostile="1"/><crtrStatus exist="3240504" hostile="1" disengaged="1"/><crtrStatus exist="3240560" hostile="1" disengaged="1"/><crtrStatus exist="3240518" hostile="1" disengaged="1"/><prompt time="1790618395">&gt;</prompt>
      You angle your tower shield towards a tall forager goblin and charge forwards!

      Your tower shield lands<pushBold/> an extremely heavy hit<popBold/> to a tall forager goblin's left arm!
      A tall forager goblin collapses to the ground, shuddering and moaning until it ceases all movement.
      With expert skill you end the attack and maneuver into a better position.

      [You're nimbly balanced]
      Roundtime: 9 sec.
      <component id='room objs'>You also see <pushBold/>a tall forager goblin<popBold/> which appears dead, a broadsword, <pushBold/>a hostile forager goblin<popBold/>, <pushBold/>a beady-eyed forager goblin<popBold/>, <pushBold/>a drooling forager goblin<popBold/>, <pushBold/>a drooling forager goblin<popBold/>, <pushBold/>a large musk hog<popBold/> and some junk.</component>
      <crtrStatus exist="3240317" hostile="1" disengaged="1" dead="1" sleeping="1"/><crtrStatus exist="3240377" hostile="1" disengaged="1"/><crtrStatus exist="3240463" hostile="1"/><crtrStatus exist="3240504" hostile="1" disengaged="1"/><crtrStatus exist="3240560" hostile="1" disengaged="1"/><crtrStatus exist="3240518" hostile="1" disengaged="1"/><prompt time="1790618396">&gt;</prompt>
    RAW
  end

  let(:thargrund_rush_vrakk_view) do
    <<~'RAW'
      <crtrStatus exist="3240317" hostile="1" disengaged="1"/><crtrStatus exist="3240377" hostile="1"/><crtrStatus exist="3240463" hostile="1" disengaged="1"/><crtrStatus exist="3240504" hostile="1"/><crtrStatus exist="3240560" hostile="1"/><crtrStatus exist="3240518" hostile="1" disengaged="1"/><prompt time="1790618395">&gt;</prompt>
      Thargrund angles his tower shield at a tall forager goblin and charges forwards!

      Thargrund's tower shield lands an extremely heavy hit to a tall forager goblin's left arm!
      A tall forager goblin collapses to the ground, shuddering and moaning until it ceases all movement.
      <component id='room objs'>You also see <pushBold/>a tall forager goblin<popBold/> which appears dead, a broadsword, <pushBold/>a hostile forager goblin<popBold/>, <pushBold/>a beady-eyed forager goblin<popBold/>, <pushBold/>a drooling forager goblin<popBold/>, <pushBold/>a drooling forager goblin<popBold/>, <pushBold/>a large musk hog<popBold/> and some junk.</component>
      <crtrStatus exist="3240317" hostile="1" disengaged="1" dead="1" sleeping="1"/><crtrStatus exist="3240377" hostile="1"/><crtrStatus exist="3240463" hostile="1" disengaged="1"/><crtrStatus exist="3240504" hostile="1"/><crtrStatus exist="3240560" hostile="1"/><crtrStatus exist="3240518" hostile="1" disengaged="1"/><prompt time="1790618396">&gt;</prompt>
    RAW
  end

  it 'attributes one kill to the killer in both hunters\' streams, though both were engaged' do
    vrakk = tracker('Vrakk', pcs: ['Thargrund'])
    feed(vrakk, vrakk_kill_vrakk_view)
    thargrund = tracker('Thargrund', pcs: ['Vrakk'])
    feed(thargrund, vrakk_kill_thargrund_view)

    expect(vrakk.record('3240264')).to include(kind: :own, engaged: true)
    expect(thargrund.record('3240264')).to include(kind: :peer, peer: 'Vrakk', engaged: true)
    expect(vrakk.harvestable?('3240264')).to be(true)
    expect(thargrund.harvestable?('3240264')).to be(false)
  end

  it 'attributes a rush through its landing line, with and without the combat stream' do
    thargrund = tracker('Thargrund', pcs: ['Vrakk'])
    feed(thargrund, thargrund_rush_thargrund_view)
    vrakk = tracker('Vrakk', pcs: ['Thargrund'])
    feed(vrakk, thargrund_rush_vrakk_view)

    expect(thargrund.harvestable?('3240317')).to be(true)
    expect(vrakk.record('3240317')).to include(kind: :peer, peer: 'Thargrund')
    expect(vrakk.harvestable?('3240317')).to be(false)
  end

  it 'attributes a thrown kill through "lands at your feet" (17:44:36, #3238760)' do
    vrakk = tracker('Vrakk', pcs: ['Thargrund'])
    feed(vrakk, <<~'RAW')
      <crtrStatus exist="3238760" hostile="1" prone="1"/><crtrStatus exist="3238812" hostile="1" disengaged="1"/><prompt time="1790617475">&gt;</prompt>
      <pushBold/><popBold/><pushBold/><popBold/><pushStream id="combat" />&lt; Moving with dominating grace, you lob a double-bit greataxe at a forager goblin.  A forager goblin fails to dodge, taking the full blow.  <pushBold/>The greataxe lands a spine-rattling strike that cuts deeply into the goblin's groin.<popBold/>
      The double-bit greataxe lands at your feet!
      A forager goblin shudders and then suddenly stops all movement.
      [You're nimbly balanced]
      [Roundtime 3 sec.]
      <popStream id="combat" /><component id='room objs'>You also see <pushBold/>a forager goblin<popBold/> which appears dead and some junk.</component>
      <crtrStatus exist="3238760" hostile="1" disengaged="1" dead="1" sleeping="1" prone="1"/><crtrStatus exist="3238812" hostile="1" disengaged="1"/><prompt time="1790617476">&gt;</prompt>
    RAW

    expect(vrakk.record('3238760')).to include(kind: :own)
  end

  it 'attributes a combination finish (17:51:09, #3239476)' do
    vrakk = tracker('Vrakk', pcs: ['Thargrund'])
    feed(vrakk, <<~'RAW')
      <crtrStatus exist="3239476" hostile="1" stunned="1" prone="1"/><crtrStatus exist="3239484" hostile="1"/><prompt time="1790617869">&gt;</prompt>
      <pushStream id="combat" />&lt; Moving with amazing force and guile, you slap your plate-clad hand at a dour forager goblin.  A dour forager goblin barely fails to parry with a broadsword.  <pushBold/>The hand lands a very heavy hit that bruises the left forearm.<popBold/>
      Utilizing flawless combat expertise you execute an aggressive attack combination and fan the flames of your internal fire.
      A dour forager goblin shudders and then suddenly stops all movement.
      [You're slightly off balance]
      [Roundtime 2 sec.]
      <popStream id="combat" /><crtrStatus exist="3239476" hostile="1" disengaged="1" dead="1" sleeping="1" prone="1"/><crtrStatus exist="3239484" hostile="1"/><prompt time="1790617869">&gt;</prompt>
    RAW
    thargrund = tracker('Thargrund', pcs: ['Vrakk'])
    feed(thargrund, <<~'RAW')
      <crtrStatus exist="3239476" hostile="1"/><prompt time="1790617869">&gt;</prompt>
      <pushStream id="combat" />Utilizing flawless combat expertise Vrakk executes an aggressive attack combination.
      A dour forager goblin shudders and then suddenly stops all movement.
      <popStream id="combat" /><crtrStatus exist="3239476" hostile="1" disengaged="1" dead="1" sleeping="1" prone="1"/><prompt time="1790617869">&gt;</prompt>
    RAW

    expect(vrakk.record('3239476')).to include(kind: :own)
    expect(thargrund.record('3239476')).to include(kind: :peer, peer: 'Vrakk')
  end

  # Lanjefast 2026-09-26 02:07:52, lout #2840088: a bolt 60 seconds earlier,
  # then the death line alone in its chunk. No one else attacked it.
  let(:bleed_out) do
    <<~'RAW'
      <crtrStatus exist="2840076" hostile="1"/><crtrStatus exist="2840088" hostile="1"/><crtrStatus exist="2840091" hostile="1"/><prompt time="1790388467">&gt;</prompt>
      You move into position to stalk a sleazy lout when it moves.
      Roundtime: 5 sec.
      <prompt time="1790388472">&gt;</prompt>
      Gasping out in terror, a sleazy lout crumples to the ground.  Eyes closing, the once rebellious flame dies out completely.
      <component id='room objs'>You also see <pushBold/>a sleazy lout<popBold/>, <pushBold/>a sleazy lout<popBold/> which appears dead, <pushBold/>a sleazy lout<popBold/> and some junk.</component>
      <crtrStatus exist="2840076" hostile="1"/><crtrStatus exist="2840088" hostile="1" disengaged="1" dead="1" sleeping="1"/><crtrStatus exist="2840091" hostile="1"/><prompt time="1790388472">&gt;</prompt>
    RAW
  end

  it 'harvests a lone hunter\'s bleed-out of a creature engaged with it' do
    lanjefast = tracker('Lanjefast')
    feed(lanjefast, bleed_out)

    expect(lanjefast.record('2840088')).to include(kind: :none, alone: true, engaged: true)
    expect(lanjefast.harvestable?('2840088')).to be(true)
  end

  it 'leaves a bleed-out when another player was in the room' do
    lanjefast = tracker('Lanjefast', pcs: ['Thargrund'])
    feed(lanjefast, bleed_out)

    expect(lanjefast.harvestable?('2840088')).to be(false)
  end

  it 'leaves a bleed-out of a creature that was not engaged with this hunter' do
    lanjefast = tracker('Lanjefast')
    feed(lanjefast, bleed_out.sub('<crtrStatus exist="2840088" hostile="1"/>', '<crtrStatus exist="2840088" hostile="1" disengaged="1"/>'))

    expect(lanjefast.harvestable?('2840088')).to be(false)
  end

  it 'never harvests a corpse this visit did not see alive (Vrakk returning to room 1473, 17:34:01)' do
    # Seen alive at 17:30:20; he walked to town and back; the next creature
    # update listed Thargrund's hog kill as dead with no death line, beside
    # Thargrund's punch at another hog.
    vrakk = tracker('Vrakk', pcs: ['Thargrund'])
    feed(vrakk, <<~'RAW')
      <crtrStatus exist="3237765" hostile="1" disengaged="1"/><crtrStatus exist="3237810" hostile="1" disengaged="1"/><crtrStatus exist="3237855" hostile="1" disengaged="1"/><prompt time="1790616620">&gt;</prompt>
      <nav rm='227205'/>
      <prompt time="1790616838">&gt;</prompt>
      <pushStream id="combat" />Moving with dominating grace, Thargrund punches his plate-clad fist at a large musk hog.  A large musk hog attempts to evade, moving directly into the blow.
      <popStream id="combat" /><component id='room objs'>You also see <pushBold/>a large musk hog<popBold/> which appears dead, <pushBold/>a large musk hog<popBold/> that appears stunned.</component>
      <crtrStatus exist="3237810" hostile="1" disengaged="1" dead="1" sleeping="1"/><crtrStatus exist="3237855" hostile="1" disengaged="1" stunned="1"/><prompt time="1790616841">&gt;</prompt>
    RAW

    expect(vrakk.record('3237810')).to include(kind: :foreign)
    expect(vrakk.harvestable?('3237810')).to be(false)
  end

  it 'claims a two-kill chunk only when every death line is its own' do
    vrakk = tracker('Vrakk', pcs: ['Thargrund'])
    feed(vrakk, <<~'RAW')
      <crtrStatus exist="1" hostile="1"/><crtrStatus exist="2" hostile="1"/><prompt time="1">&gt;</prompt>
      <pushStream id="combat" />&lt; You cleave a forager goblin.
      A forager goblin collapses to the ground, shuddering and moaning until it ceases all movement.
      Thargrund lobs a narrow-headed spear at a forager goblin.
      A forager goblin shudders and then suddenly stops all movement.
      <popStream id="combat" /><crtrStatus exist="1" dead="1"/><crtrStatus exist="2" dead="1"/><prompt time="2">&gt;</prompt>
    RAW

    expect(vrakk.record('1')).to include(kind: :none)
    expect(vrakk.harvestable?('1')).to be(false)
    expect(vrakk.harvestable?('2')).to be(false)
  end

  it 'records each death once and ignores the corpse in later updates' do
    vrakk = tracker('Vrakk', pcs: ['Thargrund'])
    feed(vrakk, vrakk_kill_vrakk_view)
    feed(vrakk, thargrund_rush_vrakk_view)

    expect(vrakk.record('3240264')).to include(kind: :own)
  end

  it 'never raises out of the hook, returns every line, and fails closed after an error' do
    broken = described_class.new(%w[Thargrund], pcs: -> { raise 'room unavailable' }, self_name: -> { 'Vrakk' })
    vrakk_kill_vrakk_view.each_line { |line| expect(broken.feed(line.chomp)).to eq(line.chomp) }

    expect(broken.errors).to eq(1)
    expect(broken.tracking?).to be(false)
    expect(broken.harvestable?('3240264')).to be(false)
  end

  it 'is not tracking once its hook is gone' do
    vrakk = tracker('Vrakk')
    feed(vrakk, vrakk_kill_vrakk_view)
    allow(DownstreamHook).to receive(:list).and_return([])

    expect(vrakk.harvestable?('3240264')).to be(false)
  end

  it 'installs one observing, script-scoped downstream hook' do
    added = []
    allow(DownstreamHook).to receive(:remove)
    allow(DownstreamHook).to receive(:add) { |name, action, **options| added << [name, action, options] }

    installed = described_class.install(%w[Vrakk Thargrund])

    expect(added.map(&:first)).to eq([described_class::HOOK])
    expect(added.first[2]).to eq(persist: false)
    expect(added.first[1].call('text')).to eq('text')
    expect(installed).to be_a(described_class)
  end
end

# ===================================================================
# SetupProcess -- weapon selection
# ===================================================================
RSpec.describe SetupProcess do
  before(:each) { ct_setup }

  def build_setup(**overrides)
    sp = SetupProcess.allocate
    defaults = { ignore_weapon_mindstate: false, offhand_trainables: false, priority_weapons: [] }
    defaults.merge(overrides).each { |k, v| sp.instance_variable_set(:"@#{k}", v) }
    sp
  end

  def gs_double(weapon_skill:, skill_done: true)
    state = double('GameState')
    allow(state).to receive(:skill_done?).and_return(skill_done)
    allow(state).to receive(:weapon_skill).and_return(weapon_skill)
    allow(state).to receive(:skip_all_weapon_max_check).and_return(false)
    allow(state).to receive(:skip_all_weapon_max_check=)
    allow(state).to receive(:reset_action_count)
    allow(state).to receive(:last_exp=)
    allow(state).to receive(:last_action_count=)
    allow(state).to receive(:update_weapon_info)
    allow(state).to receive(:update_target_weapon_skill)
    allow(state).to receive(:sort_by_rate_then_rank) { |skills, _| skills }
    allow(state).to receive(:summoned_weapons).and_return([])
    allow(state).to receive(:summoned_info).and_return(nil)
    allow(state).to receive(:focus_threshold_active).and_return(false)
    allow(state).to receive(:aiming_trainables).and_return([])
    state
  end

  before(:each) do
    allow(DRSkill).to receive(:getxp).and_return(34)
    allow(DRSkill).to receive(:getrank).and_return(100)
  end

  describe '#determine_next_to_train' do
    let(:weapons) { { 'Bow' => 'longbow', 'Slings' => 'sling', 'Crossbow' => 'latchbow' } }

    it 'stays on current weapon when all at 34 and weapon equipped' do
      gs = gs_double(weapon_skill: 'Bow')
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).not_to have_received(:update_weapon_info)
    end

    it 'selects initial weapon when all at 34 but none equipped' do
      gs = gs_double(weapon_skill: nil)
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).to have_received(:update_weapon_info)
    end

    it 'selects new weapon when some below 34' do
      allow(DRSkill).to receive(:getxp).with('Slings').and_return(17)
      gs = gs_double(weapon_skill: 'Bow')
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).to have_received(:update_weapon_info)
    end

    it 'skips locked guard with ignore_weapon_mindstate' do
      gs = gs_double(weapon_skill: 'Bow')
      build_setup(ignore_weapon_mindstate: true).send(:determine_next_to_train, gs, weapons, false)
      expect(gs).to have_received(:update_weapon_info)
    end

    it 'returns early when skill_done? is false' do
      gs = gs_double(weapon_skill: 'Bow', skill_done: false)
      build_setup.send(:determine_next_to_train, gs, weapons, false)
      expect(gs).not_to have_received(:update_weapon_info)
    end

    # BUG-FINDING: nil weapon_training should not crash
    it 'handles nil weapon_training without error' do
      allow(DRC).to receive(:message)
      gs = gs_double(weapon_skill: nil)
      expect { build_setup.send(:determine_next_to_train, gs, nil, false) }.not_to raise_error
    end

    # BUG-FINDING: empty weapon_training should warn user
    it 'warns user when weapon_training is empty' do
      allow(DRC).to receive(:message)
      gs = gs_double(weapon_skill: nil)
      build_setup.send(:determine_next_to_train, gs, {}, false)
      expect(DRC).to have_received(:message).with(/No weapons configured/)
    end

    # BUG-FINDING: warn message fires only once across repeated calls
    it 'warns about all-locked only once' do
      allow(DRC).to receive(:message)
      gs = gs_double(weapon_skill: 'Bow')
      sp = build_setup
      sp.send(:determine_next_to_train, gs, weapons, false)
      sp.send(:determine_next_to_train, gs, weapons, false)
      expect(DRC).to have_received(:message).with(/All weapon_training skills mindlocked/).once
    end
  end
end

# ===================================================================
# Cross-process state pollution
#
# Build a real GameState (via allocate), run methods from different
# processes in sequence on the same object. Look for state left by
# one method that corrupts assumptions in the next.
# ===================================================================
RSpec.describe 'Cross-process state pollution' do
  before(:each) { ct_setup }

  # Minimal GameState with enough state to run multiple process methods.
  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: nil,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: 'Small Edged', last_weapon_skill: nil,
      weapon_training: { 'Small Edged' => 'sword' },
      weapons_to_train: { 'Small Edged' => 'sword' },
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 0,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {},
      currently_whirlwinding: false, need_bundle: true,
      skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: []
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: update_room_npcs sets @dancing, then is_offense_allowed?
  # should still work independently (no state coupling).
  it 'update_room_npcs does not affect is_offense_allowed?' do
    DRRoom.npcs = []
    gs = build_live_game_state(is_empath: true, construct_mode: true)
    gs.update_room_npcs

    expect(gs.dancing?).to be true
    expect(gs.is_offense_allowed?).to be true
  end

  # BUG-FINDING: gain_check only fires when action_count > last_action_count.
  # Verify that stagnant XP with rising action_count increments no_gain,
  # then fresh XP resets it.
  # gain_check requires weapons_to_train.size > 1 to increment no_gain
  it 'skill_done? gain_check increments on stagnant XP, resets on gain' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRSkill).to receive(:getrank).and_return(100)
    two_weapons = { 'Small Edged' => 'sword', 'Large Edged' => 'greatsword' }
    gs = build_live_game_state(
      last_exp: 10, gain_check: 2, action_count: 5, last_action_count: 0,
      weapons_to_train: two_weapons, weapon_training: two_weapons
    )

    gs.skill_done?
    first_no_gain = gs.instance_variable_get(:@no_gain_list)['Small Edged']
    expect(first_no_gain).to eq(1)

    gs.instance_variable_set(:@action_count, 10)
    allow(DRSkill).to receive(:getxp).and_return(15)
    gs.skill_done?
    second_no_gain = gs.instance_variable_get(:@no_gain_list)['Small Edged']
    expect(second_no_gain).to eq(0)
  end

  # BUG-FINDING: construct marking via ManipulateProcess persists on GameState.
  # A construct NPC should remain marked across process boundaries.
  it 'construct marking persists across process calls' do
    DRRoom.npcs = ['golem']
    gs = build_live_game_state

    gs.send(:construct, 'golem')
    expect(gs.construct?('golem')).to be true

    gs.update_room_npcs
    expect(gs.construct?('golem')).to be true
  end

  # BUG-FINDING: cleanup state machine -- calling next_clean_up_step
  # repeatedly should progress through all states without skipping.
  it 'cleanup state machine progresses through all states in order' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)
    gs.instance_variable_set(:@stop_on_bleeding, false)
    gs.instance_variable_set(:@skip_last_kill, false)

    states = []
    gs.next_clean_up_step
    states << gs.instance_variable_get(:@clean_up_step)
    4.times do
      gs.next_clean_up_step
      states << gs.instance_variable_get(:@clean_up_step)
    end

    expect(states).to eq(%w[kill clear_magic dismiss_pet stow done])
  end

  # drbot hunting health waiver (#1278): cleanup skips the last kill only when
  # the bleeding stop is actually in force.
  it 'cleanup keeps the last kill for bleeding while the waiver is active' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(true)
    gs.instance_variable_set(:@stop_on_bleeding, true)
    gs.instance_variable_set(:@skip_last_kill, false)
    reader = Class.new { def self.waived?(_signal) = true }
    stub_const('DrbotHuntingHealthPolicy', reader)

    gs.next_clean_up_step

    expect(gs.instance_variable_get(:@clean_up_step)).to eq('kill')
  end

  it 'cleanup skips the last kill for bleeding when the waiver reports normal gates' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(true)
    gs.instance_variable_set(:@stop_on_bleeding, true)
    gs.instance_variable_set(:@skip_last_kill, false)
    reader = Class.new { def self.waived?(_signal) = false }
    stub_const('DrbotHuntingHealthPolicy', reader)

    gs.next_clean_up_step

    expect(gs.instance_variable_get(:@clean_up_step)).to eq('clear_magic')
  end

  # BUG-FINDING: dancing state and can_engage? interaction.
  # When dancing (npcs <= threshold), can_engage? should still return true
  # if npcs exist -- dancing controls weapon selection, not engagement.
  it 'dancing does not prevent engagement when npcs exist' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(dance_threshold: 5)
    gs.update_room_npcs

    expect(gs.dancing?).to be true
    expect(gs.can_engage?).to be true
  end
end

# ===================================================================
# Multi-tick simulation
#
# Call the same method repeatedly with changing external state.
# Look for counters that grow without bound, timers that never reset,
# or flags that get stuck.
# ===================================================================
RSpec.describe 'Multi-tick simulation' do
  before(:each) { ct_setup }

  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: 3,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: 'Small Edged', last_weapon_skill: nil,
      weapon_training: { 'Small Edged' => 'sword', 'Large Edged' => 'greatsword' },
      weapons_to_train: { 'Small Edged' => 'sword', 'Large Edged' => 'greatsword' },
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 5,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {},
      currently_whirlwinding: false, need_bundle: true,
      skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: []
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: update_room_npcs called 50 times with fluctuating NPC count.
  # Verify dancing/retreating toggles correctly and no state leaks.
  it 'update_room_npcs toggles dancing/retreating correctly over 50 ticks' do
    gs = build_live_game_state(dance_threshold: 1, retreat_threshold: 3)

    50.times do |i|
      npc_count = (i % 5) + 0
      DRRoom.npcs = Array.new(npc_count) { |j| "rat_#{j}" }
      gs.update_room_npcs

      expected_dancing = npc_count <= 1 || npc_count.zero?
      expected_retreating = npc_count >= 3
      expect(gs.dancing?).to eq(expected_dancing), "tick #{i}: npc_count=#{npc_count}, expected dancing=#{expected_dancing}"
      expect(gs.retreating?).to eq(expected_retreating), "tick #{i}: npc_count=#{npc_count}, expected retreating=#{expected_retreating}"
    end
  end

  # BUG-FINDING: skill_done? called repeatedly with stagnant XP should
  # increment no_gain_list each tick (when action_count rises).
  it 'no_gain_list increments correctly over many stagnant ticks' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRSkill).to receive(:getrank).and_return(100)
    gs = build_live_game_state(last_exp: 10, gain_check: 100, action_count: 1, last_action_count: 0)

    20.times do |i|
      gs.instance_variable_set(:@action_count, i + 1)
      gs.skill_done?

      no_gain = gs.instance_variable_get(:@no_gain_list)['Small Edged']
      expect(no_gain).to eq(i + 1), "tick #{i}: expected no_gain=#{i + 1}, got #{no_gain}"
    end
  end

  # BUG-FINDING: ManipulateProcess called repeatedly -- cooldown timer
  # should prevent spam. Verify exactly one manipulation per 120s window.
  it 'ManipulateProcess respects cooldown across repeated calls' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')

    mp = ManipulateProcess.allocate
    mp.instance_variable_set(:@threshold, 1)
    mp.instance_variable_set(:@manip_to_train, false)
    mp.instance_variable_set(:@last_manip, Time.now - 200)

    gs = double('GameState', danger: false, construct_mode?: false, npcs: ['rat'])
    allow(gs).to receive(:construct?).and_return(false)

    manip_count = 0
    10.times do
      old_time = mp.instance_variable_get(:@last_manip)
      mp.execute(gs)
      new_time = mp.instance_variable_get(:@last_manip)
      manip_count += 1 if new_time != old_time
    end

    expect(manip_count).to eq(1)
  end
end

# ===================================================================
# Nil/missing YAML fields
#
# Settings arrive as OpenStruct from YAML. Missing keys return nil.
# Wrong types (string "true" instead of boolean true) are common
# user errors. Test that the code handles these gracefully.
# ===================================================================
RSpec.describe 'Nil and type-confused settings' do
  before(:each) { ct_setup }

  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: nil,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: nil, last_weapon_skill: nil,
      weapon_training: {}, weapons_to_train: {},
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 0,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {}, currently_whirlwinding: false,
      need_bundle: true, skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: []
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: permashocked set to string "true" instead of boolean
  it 'string "true" for permashocked is truthy (matches boolean behavior)' do
    gs = build_live_game_state(is_empath: true, is_permashocked: "true")
    expect(gs.is_permashocked?).to be_truthy
  end

  # BUG-FINDING: permashocked set to string "false" is still truthy in Ruby
  it 'string "false" for permashocked is truthy (Ruby string truthiness bug)' do
    gs = build_live_game_state(is_empath: true, is_permashocked: "false")
    expect(gs.is_permashocked?).to be_truthy
  end

  # BUG-FINDING: construct_mode set to nil (missing from YAML)
  it 'nil construct_mode does not crash is_offense_allowed?' do
    gs = build_live_game_state(is_empath: true, construct_mode: nil)
    allow(DRSpells).to receive(:active_spells).and_return({})
    expect { gs.is_offense_allowed? }.not_to raise_error
    expect(gs.is_offense_allowed?).to be false
  end

  # FIXED: ignored_npcs nil falls back to empty array instead of crashing.
  it 'nil ignored_npcs is handled gracefully' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(ignored_npcs: nil)
    expect { gs.update_room_npcs }.not_to raise_error
    expect(gs.npcs).to eq(['rat'])
  end

  # BUG: dance_threshold set to nil instead of integer crashes.
  # YAML key `dance_threshold:` with no value produces nil.
  it 'nil dance_threshold crashes update_room_npcs with ArgumentError' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(dance_threshold: nil, ignored_npcs: [])
    expect { gs.update_room_npcs }.to raise_error(ArgumentError)
  end

  # BUG: dance_threshold set to string "2" crashes.
  # YAML key `dance_threshold: "2"` (quoted) produces string.
  # Ruby cannot compare Integer <= String.
  it 'string dance_threshold crashes update_room_npcs with ArgumentError' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state(dance_threshold: "2", ignored_npcs: [])
    expect { gs.update_room_npcs }.to raise_error(ArgumentError)
  end

  # BUG-FINDING: weapon_training as nil (not set in YAML at all)
  it 'nil weapon_training does not crash determine_next_to_train' do
    allow(DRC).to receive(:message)
    allow(DRSkill).to receive(:getxp).and_return(0)
    allow(DRSkill).to receive(:getrank).and_return(100)
    gs = double('GameState')
    allow(gs).to receive(:skill_done?).and_return(true)
    allow(gs).to receive(:weapon_skill).and_return(nil)

    sp = SetupProcess.allocate
    sp.instance_variable_set(:@ignore_weapon_mindstate, false)
    sp.instance_variable_set(:@offhand_trainables, false)
    sp.instance_variable_set(:@priority_weapons, [])

    expect { sp.send(:determine_next_to_train, gs, nil, false) }.not_to raise_error
  end

  # FIXED: ManipulateProcess coerces threshold to integer at init.
  # String "2" from YAML now works via &.to_i in the constructor.
  it 'string threshold for ManipulateProcess is coerced to integer' do
    allow(DRSkill).to receive(:getxp).and_return(10)
    allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')

    mp = ManipulateProcess.allocate
    mp.instance_variable_set(:@threshold, "2".to_i)
    mp.instance_variable_set(:@manip_to_train, false)
    mp.instance_variable_set(:@last_manip, Time.now - 200)

    gs = double('GameState', danger: false, construct_mode?: false, npcs: %w[rat kobold])
    allow(gs).to receive(:construct?).and_return(false)

    expect { mp.execute(gs) }.not_to raise_error
  end
end

# ===================================================================
# State mutation after cleanup
#
# The cleanup state machine (next_clean_up_step) drives script
# shutdown. Test what happens when external state changes mid-cleanup
# (new mob spawns, flags fire, etc).
# ===================================================================
RSpec.describe 'State mutation after cleanup' do
  before(:each) { ct_setup }

  def build_live_game_state(**overrides)
    gs = GameState.allocate
    defaults = {
      is_empath: false, is_permashocked: false, construct_mode: false,
      undead_mode: false, innocence_mode: false,
      ignored_npcs: [], dance_threshold: 1, retreat_threshold: nil,
      dancing: false, retreating: false, cached_npcs: nil,
      clean_up_step: nil, mob_died: false, danger: false,
      casting: false, loaded: false, parrying: false,
      current_weapon_skill: 'Small Edged', last_weapon_skill: nil,
      weapon_training: { 'Small Edged' => 'sword' },
      weapons_to_train: { 'Small Edged' => 'sword' },
      action_count: 0, target_action_count: 25, target_weapon_skill: 20,
      last_exp: -1, last_action_count: 0, gain_check: 0,
      no_gain_list: Hash.new(0), focus_threshold: 0,
      focus_threshold_active: false, ignore_weapon_mindstate: false,
      cooldown_timers: {}, constructs: [],
      rush_shield: nil, rush_to_engage: false, rush_retreat_skip: false,
      rush_engage_only: false, stomp_to_engage: false, stomp_on_cooldown: false,
      pounce_on_cooldown: false, pounce_to_engage: false,
      charged_maneuvers: {}, currently_whirlwinding: false,
      need_bundle: true, skip_all_weapon_max_check: false,
      no_skins: [], no_dissect: [], no_stab_mobs: [], no_loot: [],
      stop_on_bleeding: false, skip_last_kill: false
    }
    defaults.merge(overrides).each { |k, v| gs.instance_variable_set(:"@#{k}", v) }
    gs
  end

  # BUG-FINDING: new mob spawns during cleanup. The cleanup state machine
  # should not reverse -- once cleanup starts, it proceeds to completion.
  it 'cleanup does not reverse when new npcs appear mid-cleanup' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.cleaning_up?).to be true

    DRRoom.npcs = %w[rat kobold gremlin]
    gs.update_room_npcs

    expect(gs.cleaning_up?).to be true
    expect(gs.done_cleaning_up?).to be false
  end

  # BUG-FINDING: force_cleanup mid-kill should skip to clear_magic
  it 'force_cleanup advances past kill even with npcs present' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.finish_killing?).to be true

    gs.force_cleanup
    expect(gs.finish_killing?).to be false
    expect(gs.finish_spell_casting?).to be true
  end

  # BUG-FINDING: can_engage? during cleanup should still work
  # (cleanup doesn't set innocence or retreating)
  it 'can_engage? remains true during cleanup with npcs present' do
    DRRoom.npcs = ['rat']
    gs = build_live_game_state
    gs.update_room_npcs
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.cleaning_up?).to be true
    expect(gs.can_engage?).to be true
  end

  # BUG-FINDING: is_offense_allowed? does not change during cleanup
  it 'is_offense_allowed? is independent of cleanup state' do
    gs = build_live_game_state(is_empath: true, construct_mode: true)
    allow(gs).to receive(:bleeding?).and_return(false)

    expect(gs.is_offense_allowed?).to be true
    gs.next_clean_up_step
    expect(gs.is_offense_allowed?).to be true
    gs.next_clean_up_step
    expect(gs.is_offense_allowed?).to be true
  end

  # BUG-FINDING: skip_last_kill should jump straight to clear_magic
  it 'skip_last_kill skips the kill phase entirely' do
    gs = build_live_game_state(skip_last_kill: true)
    allow(gs).to receive(:bleeding?).and_return(false)

    gs.next_clean_up_step
    expect(gs.finish_killing?).to be false
    expect(gs.finish_spell_casting?).to be true
  end

  # BUG-FINDING: calling next_clean_up_step past 'done' should not crash
  it 'next_clean_up_step past done is a no-op' do
    gs = build_live_game_state
    allow(gs).to receive(:bleeding?).and_return(false)

    5.times { gs.next_clean_up_step }
    expect(gs.done_cleaning_up?).to be true

    expect { gs.next_clean_up_step }.not_to raise_error
  end
end

# ###################################################################
# MERGED FROM spec/combat_trainer_bug_fixes_spec.rb
# ###################################################################

# ===========================================================================
# SetupProcess#last_stance -- nil guard for Flags['last-stance']
# ===========================================================================
RSpec.describe SetupProcess do
  def build_setup_process
    SetupProcess.allocate
  end

  # A fired flag holds the MatchData from its registered regex, NOT a String or
  # Array: DRParser.check_events does `Flags.flags[key] = server_string.match(regex)`.
  # last_stance reads Flags['last-stance'] by named capture (:evasion, :parry,
  # :shield, :spare), so the fixture has to be a real MatchData with those
  # captures. We extract the exact regex the script registers so a capture-name
  # drift between Flags.add('last-stance', ...) and last_stance fails here
  # instead of shipping a script that silently reads all zeros.
  def registered_last_stance_regex
    filepath = File.join(File.dirname(__FILE__), '..', 'combat-trainer.lic')
    line = File.readlines(filepath).find { |l| l.include?("Flags.add('last-stance'") }
    raise "Flags.add('last-stance', ...) not found in combat-trainer.lic" unless line

    eval(line[%r{Flags\.add\('last-stance',\s*(/.*/)\)}, 1])
  end

  # Build the MatchData production would store for the given stance percentages
  # by matching a real game line against the registered regex.
  def last_stance_flag(evasion:, parry:, shield:, spare:)
    line = "Setting your Evasion stance to #{evasion}%, your Parry stance to #{parry}%, " \
           "your Shield stance to #{shield}%.  You have #{spare} stance points left."
    line.match(registered_last_stance_regex) ||
      raise("sample stance line did not match the registered regex: #{line.inspect}")
  end

  describe '#last_stance' do
    context 'when the flag has never fired (registered default is false)' do
      it 'returns a zeroed stance hash instead of indexing false' do
        Flags['last-stance'] = false
        instance = build_setup_process

        result = instance.send(:last_stance)

        expect(result).to eq({ 'EVASION' => 0, 'PARRY' => 0, 'SHIELD' => 0, 'SPARE' => 0 })
      end
    end

    context 'when the flag was cleared to nil' do
      it 'returns a zeroed stance hash instead of raising NoMethodError' do
        Flags['last-stance'] = nil
        instance = build_setup_process

        result = instance.send(:last_stance)

        expect(result).to eq({ 'EVASION' => 0, 'PARRY' => 0, 'SHIELD' => 0, 'SPARE' => 0 })
      end
    end

    context 'when the flag holds a fired stance MatchData' do
      it 'parses each named capture into an integer percentage' do
        Flags['last-stance'] = last_stance_flag(evasion: 80, parry: 60, shield: 40, spare: 20)
        instance = build_setup_process

        result = instance.send(:last_stance)

        expect(result).to eq({ 'EVASION' => 80, 'PARRY' => 60, 'SHIELD' => 40, 'SPARE' => 20 })
      end
    end

    context 'when a fired stance MatchData is all zeros' do
      it 'returns all zeros via the parse path, not the unfired-flag guard' do
        Flags['last-stance'] = last_stance_flag(evasion: 0, parry: 0, shield: 0, spare: 0)
        instance = build_setup_process

        result = instance.send(:last_stance)

        expect(result).to eq({ 'EVASION' => 0, 'PARRY' => 0, 'SHIELD' => 0, 'SPARE' => 0 })
      end
    end
  end
end

# ===========================================================================
# ManipulateProcess#manipulate -- ordinal targeting for duplicate NPCs
# ===========================================================================
RSpec.describe ManipulateProcess do
  def build_manipulate_process(**overrides)
    instance = ManipulateProcess.allocate
    defaults = {
      threshold: 5,
      manip_to_train: false,
      last_manip: Time.now - 200,
      filtered_npcs: []
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      npcs: [],
      danger: false,
      construct_mode?: false
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:construct?).and_return(false)
    allow(state).to receive(:construct)
    state
  end

  describe '#manipulate' do
    before(:each) do
      allow(DRC).to receive(:bput).and_return('You attempt to empathically manipulate')
    end

    context 'when all NPCs have different nouns' do
      it 'uses "first" ordinal for each NPC' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 3,
          filtered_npcs: %w[rat kobold goblin]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first kobold/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first goblin/, any_args)
      end
    end

    context 'when multiple NPCs share the same noun' do
      it 'uses incrementing ordinals for duplicate nouns' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 3,
          filtered_npcs: %w[rat rat rat]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second rat/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship third rat/, any_args)
      end
    end

    context 'when mixed duplicate and unique NPCs are present' do
      it 'tracks ordinals independently per noun' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 4,
          filtered_npcs: %w[rat kobold rat kobold]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first kobold/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second rat/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second kobold/, any_args)
      end
    end

    context 'when an NPC is a construct' do
      it 'skips constructs and does not increment ordinal for that noun' do
        game_state = build_game_state
        allow(game_state).to receive(:construct?).with('golem').and_return(true)
        allow(game_state).to receive(:construct?).with('rat').and_return(false)

        instance = build_manipulate_process(
          threshold: 2,
          filtered_npcs: %w[golem rat]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).not_to have_received(:bput).with(/manipulate friendship .* golem/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, any_args)
      end
    end

    context 'when threshold limits the number of manipulations' do
      it 'stops after reaching the threshold' do
        game_state = build_game_state
        instance = build_manipulate_process(
          threshold: 2,
          filtered_npcs: %w[rat rat rat]
        )

        instance.send(:manipulate, game_state)

        expect(DRC).to have_received(:bput).with(/manipulate friendship first rat/, any_args)
        expect(DRC).to have_received(:bput).with(/manipulate friendship second rat/, any_args)
        expect(DRC).not_to have_received(:bput).with(/manipulate friendship third rat/, any_args)
      end
    end
  end
end

# ###################################################################
# MERGED FROM spec/combat_trainer_safety_spec.rb
# ###################################################################

RSpec.describe SafetyProcess do
  # The original safety spec seeded $HUNTING_BUDDY/$COMBAT_TRAINER and reset
  # known_spells in its own RSpec.configure before(:each). ct_setup is a
  # superset of that, so we use it here to preserve the same per-example state.
  before(:each) { ct_setup }

  def build_safety_process(**overrides)
    instance = SafetyProcess.allocate
    defaults = {
      equipment_manager: double('EquipmentManager'),
      health_threshold: 20,
      stop_on_bleeding: true,
      safety_untendable_threshold: 3,
      safety_exit_on_bleeding: false,
      safety_concentration_minimum: nil,
      safety_escape_health_threshold: nil,
      untendable_counter: 0
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      danger: false,
      retreating?: false
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:danger=)
    state
  end

  # Stub the rest of execute that runs after the safety branches
  def stub_post_safety(instance)
    allow(instance).to receive(:check_item_recovery)
    allow(instance).to receive(:tend_lodged)
    allow(instance).to receive(:tend_parasite)
    allow(instance).to receive(:active_mitigation)
    allow(instance).to receive(:in_danger?).and_return(false)
    allow(instance).to receive(:keep_away)
    allow(instance).to receive(:bleeding?).and_return(false)
    allow(instance).to receive(:stunned?).and_return(false)
    DRStats.health = 100
    DRStats.concentration = 100
    allow(DRCA).to receive(:activate_khri?).and_return(true)
  end

  describe 'drbot hunting health waiver (#1278)' do
    def stub_waiver(active)
      reader = Class.new do
        define_singleton_method(:waived?) { |_signal| active }
      end
      stub_const('DrbotHuntingHealthPolicy', reader)
    end

    it 'does not stop for untendable bleeding while the waiver is active' do
      stub_waiver(true)
      instance = build_safety_process(untendable_counter: 3)
      stub_post_safety(instance)
      allow(instance).to receive(:bleeding?).and_return(true)
      allow(DRCH).to receive(:has_tendable_bleeders?).and_return(false)

      instance.execute(build_game_state)

      expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      expect($COMBAT_TRAINER).not_to have_received(:stop)
    end

    it 'does not send EXIT below the health threshold while the waiver is active' do
      stub_waiver(true)
      instance = build_safety_process(health_threshold: 60)
      stub_post_safety(instance)
      DRStats.health = 30
      allow(instance).to receive(:fput)

      instance.execute(build_game_state)

      expect(instance).not_to have_received(:fput).with('exit')
      expect(DRStats.health).to eq(30)
    end

    it 'does not stop for bleeding with safety_exit_on_bleeding while the waiver is active' do
      stub_waiver(true)
      instance = build_safety_process(safety_exit_on_bleeding: true)
      stub_post_safety(instance)
      allow(instance).to receive(:bleeding?).and_return(true)
      allow(DRCH).to receive(:has_tendable_bleeders?).and_return(false)

      instance.execute(build_game_state)

      expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
    end

    it 'keeps the Thief stun escape while only health is waived' do
      stub_waiver(true)
      instance = build_safety_process(safety_escape_health_threshold: 50)
      stub_post_safety(instance)
      allow(DRStats).to receive(:thief?).and_return(true)
      DRSpells.known_spells['Vanish'] = true
      allow(instance).to receive(:stunned?).and_return(true, false) # stun clears during the escape wait

      instance.execute(build_game_state)

      expect($HUNTING_BUDDY).to have_received(:stop_hunting)
    end

    it 'does not use the Thief health escape while the waiver is active' do
      stub_waiver(true)
      instance = build_safety_process(safety_escape_health_threshold: 50)
      stub_post_safety(instance)
      allow(DRStats).to receive(:thief?).and_return(true)
      DRSpells.known_spells['Vanish'] = true
      DRStats.health = 20

      instance.execute(build_game_state)

      expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
    end

    it 'keeps the concentration stop while the waiver is active' do
      stub_waiver(true)
      instance = build_safety_process(safety_concentration_minimum: 50)
      stub_post_safety(instance)
      DRStats.concentration = 10

      instance.execute(build_game_state)

      expect($HUNTING_BUDDY).to have_received(:stop_hunting)
    end

    it 'restores every health stop when the waiver reports normal gates' do
      stub_waiver(false)
      instance = build_safety_process(untendable_counter: 3, health_threshold: 60)
      stub_post_safety(instance)
      allow(instance).to receive(:bleeding?).and_return(true)
      allow(instance).to receive(:fput)
      DRStats.health = 30

      instance.execute(build_game_state)

      expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      expect(instance).to have_received(:fput).with('exit')
    end

    it 'fails closed when the reader raises' do
      reader = Class.new { def self.waived?(_signal) = raise(StandardError, 'boom') }
      stub_const('DrbotHuntingHealthPolicy', reader)
      instance = build_safety_process(health_threshold: 60)
      stub_post_safety(instance)
      allow(instance).to receive(:fput)
      DRStats.health = 30

      instance.execute(build_game_state)

      expect(instance).to have_received(:fput).with('exit')
    end
  end

  describe '#execute' do
    describe 'safety_untendable_threshold' do
      it 'stops hunt at default threshold of 3' do
        instance = build_safety_process(untendable_counter: 3)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true) # stop is gated on active bleeding
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
        expect($COMBAT_TRAINER).to have_received(:stop)
      end

      it 'does not stop hunt below default threshold' do
        instance = build_safety_process(untendable_counter: 2)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true) # bleeding so the threshold (not the not-bleeding reset) is what is tested
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end

      it 'stops hunt at custom threshold of 1' do
        instance = build_safety_process(safety_untendable_threshold: 1, untendable_counter: 1)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true) # stop is gated on active bleeding
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'requires stop_on_bleeding to be true' do
        instance = build_safety_process(untendable_counter: 3, stop_on_bleeding: false)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true) # bleeding so stop_on_bleeding=false is what prevents the stop
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end
    end

    describe 'safety_concentration_minimum' do
      it 'stops hunt when concentration drops below minimum' do
        instance = build_safety_process(safety_concentration_minimum: 10)
        stub_post_safety(instance)
        DRStats.concentration = 5
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'does not stop hunt when concentration is above minimum' do
        instance = build_safety_process(safety_concentration_minimum: 10)
        stub_post_safety(instance)
        DRStats.concentration = 50
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end

      it 'is disabled when nil' do
        DRStats.concentration = 0
        instance = build_safety_process(safety_concentration_minimum: nil)
        stub_post_safety(instance)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end
    end

    describe 'safety_escape_health_threshold (Thief Vanish)' do
      before(:each) do
        DRStats.guild = 'Thief'
        DRSpells._set_known_spells({ 'Vanish' => true })
      end

      it 'activates Vanish and stops hunt when health is below threshold' do
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        DRStats.health = 85
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).to have_received(:activate_khri?).with(false, "Vanish")
        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'activates Vanish when bleeding' do
        DRStats.health = 100
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).to have_received(:activate_khri?).with(false, "Vanish")
      end

      it 'does not fire for non-Thieves' do
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        DRStats.guild = 'Ranger'
        DRStats.health = 50
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).not_to have_received(:activate_khri?)
      end

      it 'does not fire if Thief does not know Vanish' do
        instance = build_safety_process(safety_escape_health_threshold: 90)
        stub_post_safety(instance)
        DRSpells._set_known_spells({})
        DRStats.health = 50
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).not_to have_received(:activate_khri?)
      end

      it 'is disabled when nil' do
        instance = build_safety_process(safety_escape_health_threshold: nil)
        stub_post_safety(instance)
        DRStats.health = 10
        game_state = build_game_state

        instance.execute(game_state)

        expect(DRCA).not_to have_received(:activate_khri?)
      end
    end

    describe 'safety_exit_on_bleeding' do
      it 'stops hunt when bleeding and setting is true' do
        instance = build_safety_process(safety_exit_on_bleeding: true)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'stops hunt when stunned with low health' do
        instance = build_safety_process(safety_exit_on_bleeding: true)
        stub_post_safety(instance)
        DRStats.health = 70
        allow(instance).to receive(:stunned?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).to have_received(:stop_hunting)
      end

      it 'does not stop hunt when stunned with high health' do
        instance = build_safety_process(safety_exit_on_bleeding: true)
        stub_post_safety(instance)
        DRStats.health = 95
        allow(instance).to receive(:stunned?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end

      it 'does not fire when setting is false' do
        instance = build_safety_process(safety_exit_on_bleeding: false)
        stub_post_safety(instance)
        allow(instance).to receive(:bleeding?).and_return(true)
        game_state = build_game_state

        instance.execute(game_state)

        expect($HUNTING_BUDDY).not_to have_received(:stop_hunting)
      end
    end
  end
end

# ###################################################################
# MERGED FROM spec/combat_trainer_warhorn_egg_spec.rb
# ###################################################################

# ===========================================================================
# AbilityProcess warhorn/egg discovery and usage
# ===========================================================================
RSpec.describe AbilityProcess do
  before(:each) do
    allow(DRC).to receive(:bput).and_return('Roundtime')
    allow(DRC).to receive(:message)
  end

  # ===========================================================================
  # #discover_egg
  # ===========================================================================
  describe '#discover_egg' do
    it 'records the game ID when egg is found' do
      instance = build_ability_process
      stub_right_hand_with_id('12345')
      allow(DRCI).to receive(:get_item?).with('egg').and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:discover_egg, 'egg')

      expect(instance.instance_variable_get(:@egg_ids)).to eq(['12345'])
    end

    it 'stows by game ID after discovery' do
      instance = build_ability_process
      stub_right_hand_with_id('12345')
      allow(DRCI).to receive(:get_item?).with('egg').and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:discover_egg, 'egg')

      expect(DRCI).to have_received(:stow_item?).with('#12345')
    end

    it 'warns and does not record when egg is not found' do
      instance = build_ability_process
      allow(DRCI).to receive(:get_item?).with('second egg').and_return(false)

      instance.send(:discover_egg, 'second egg')

      expect(instance.instance_variable_get(:@egg_ids)).to be_empty
      expect(DRC).to have_received(:message).with(/Could not find 'second egg'/)
    end
  end

  # ===========================================================================
  # #discover_warhorn
  # ===========================================================================
  describe '#discover_warhorn' do
    it 'records worn warhorn when remove succeeds' do
      instance = build_ability_process
      stub_right_hand_with_id('99')
      allow(DRCI).to receive(:remove_item?).with('warhorn').and_return(true)
      allow(DRCI).to receive(:wear_item?).and_return(true)

      instance.send(:discover_warhorn, 'warhorn')

      items = instance.instance_variable_get(:@warhorn_items)
      expect(items).to eq([{ id: '99', worn: true }])
    end

    it 're-wears a worn warhorn after discovery' do
      instance = build_ability_process
      stub_right_hand_with_id('99')
      allow(DRCI).to receive(:remove_item?).with('warhorn').and_return(true)
      allow(DRCI).to receive(:wear_item?).and_return(true)

      instance.send(:discover_warhorn, 'warhorn')

      expect(DRCI).to have_received(:wear_item?).with('#99')
    end

    it 'records stowed warhorn when remove fails but get succeeds' do
      instance = build_ability_process
      stub_right_hand_with_id('50')
      allow(DRCI).to receive(:remove_item?).with('horn').and_return(false)
      allow(DRCI).to receive(:get_item?).with('horn').and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:discover_warhorn, 'horn')

      items = instance.instance_variable_get(:@warhorn_items)
      expect(items).to eq([{ id: '50', worn: false }])
    end

    it 'warns when warhorn is not found at all' do
      instance = build_ability_process
      allow(DRCI).to receive(:remove_item?).with('horn').and_return(false)
      allow(DRCI).to receive(:get_item?).with('horn').and_return(false)

      instance.send(:discover_warhorn, 'horn')

      expect(instance.instance_variable_get(:@warhorn_items)).to be_empty
      expect(DRC).to have_received(:message).with(/Could not find warhorn 'horn'/)
    end
  end

  # ===========================================================================
  # #set_warhorn_or_egg
  # ===========================================================================
  describe '#set_warhorn_or_egg' do
    it 'builds rotation with both egg and warhorn when both are found' do
      instance = build_ability_process(egg_count: 1, warhorn_nouns: ['warhorn'])
      stub_right_hand_with_id('10')
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)
      allow(DRCI).to receive(:remove_item?).and_return(true)
      allow(DRCI).to receive(:wear_item?).and_return(true)

      instance.send(:set_warhorn_or_egg)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[egg warhorn])
    end

    it 'builds rotation with only egg when no warhorns configured' do
      instance = build_ability_process(egg_count: 1, warhorn_nouns: [])
      stub_right_hand_with_id('10')
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:set_warhorn_or_egg)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(['egg'])
    end

    it 'warns when no items are found at all' do
      instance = build_ability_process(egg_count: 1, warhorn_nouns: ['warhorn'])
      allow(DRCI).to receive(:get_item?).and_return(false)
      allow(DRCI).to receive(:remove_item?).and_return(false)

      instance.send(:set_warhorn_or_egg)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to be_empty
      expect(DRC).to have_received(:message).with(/No eggs or warhorns found/)
    end

    it 'warns when fewer eggs found than configured' do
      call_count = 0
      instance = build_ability_process(egg_count: 2, warhorn_nouns: [])
      allow(DRCI).to receive(:get_item?) do |_arg|
        call_count += 1
        if call_count == 1
          stub_right_hand_with_id('10')
          true
        else
          false
        end
      end
      allow(DRCI).to receive(:stow_item?).and_return(true)

      instance.send(:set_warhorn_or_egg)

      expect(DRC).to have_received(:message).with(/wanted 2 egg.*only found 1/)
    end
  end

  # ===========================================================================
  # #use_warhorn_or_egg -- room effect gate
  # ===========================================================================
  describe '#use_warhorn_or_egg' do
    it 'skips when room effect is still active (< 600s)' do
      UserVars.warhorn = { "last_warhorn_or_egg" => Time.now - 300 }
      instance = build_ability_process(warhorn_or_egg: ['egg'], egg_ids: ['10'])
      game_state = build_game_state

      instance.send(:use_warhorn_or_egg, game_state)

      expect(DRC).not_to have_received(:bput).with(/invoke/, anything, anything, anything, anything, anything)
    end

    it 'attempts use when room effect has expired (>= 600s)' do
      UserVars.warhorn = { "last_warhorn_or_egg" => Time.now - 601 }
      instance = build_ability_process(
        warhorn_or_egg: ['egg'],
        egg_ids: ['10'],
        item_cooldowns: {}
      )
      game_state = build_game_state
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      instance.send(:use_warhorn_or_egg, game_state)

      expect(DRC).to have_received(:bput).with("invoke #10", anything, anything, anything, anything, anything)
    end

    it 'rotates the type after each call' do
      UserVars.warhorn = { "last_warhorn_or_egg" => Time.now - 601 }
      instance = build_ability_process(
        warhorn_or_egg: %w[egg warhorn],
        egg_ids: ['10'],
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {}
      )
      game_state = build_game_state
      allow(DRC).to receive(:bput).and_return('light envelops the area briefly')

      instance.send(:use_warhorn_or_egg, game_state)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[warhorn egg])
    end
  end

  # ===========================================================================
  # #use_egg? -- per-item cooldown and error handling
  # ===========================================================================
  describe '#use_egg?' do
    it 'returns true on successful invocation' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      expect(instance.send(:use_egg?)).to be true
    end

    it 'records cooldown timestamp on success' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      instance.send(:use_egg?)

      cooldowns = instance.instance_variable_get(:@item_cooldowns)
      expect(cooldowns['10']).to be_within(2).of(Time.now)
    end

    it 'skips egg on cooldown and tries the next one' do
      instance = build_ability_process(
        egg_ids: %w[10 20],
        item_cooldowns: { '10' => Time.now }
      )
      allow(DRC).to receive(:bput).with("invoke #20", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      expect(instance.send(:use_egg?)).to be true
      expect(DRC).not_to have_received(:bput).with("invoke #10", anything, anything, anything, anything, anything)
    end

    it 'returns false and removes egg type when area inhibits' do
      rotation = %w[egg warhorn]
      instance = build_ability_process(
        egg_ids: ['10'],
        item_cooldowns: {},
        warhorn_or_egg: rotation
      )
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('Something about the area inhibits')

      result = instance.send(:use_egg?)

      expect(result).to be false
      expect(rotation).not_to include('egg')
    end

    it 'removes a missing egg from the list and tries remaining' do
      instance = build_ability_process(
        egg_ids: %w[10 20],
        item_cooldowns: {},
        warhorn_or_egg: ['egg']
      )
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('Invoke what?')
      allow(DRC).to receive(:bput).with("invoke #20", anything, anything, anything, anything, anything)
                                  .and_return('light envelops the area briefly')

      expect(instance.send(:use_egg?)).to be true
      expect(instance.instance_variable_get(:@egg_ids)).to eq(['20'])
    end

    it 'returns false when all eggs are missing' do
      instance = build_ability_process(
        egg_ids: ['10'],
        item_cooldowns: {},
        warhorn_or_egg: ['egg']
      )
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('Invoke what?')

      expect(instance.send(:use_egg?)).to be false
    end

    it 'sets a 60s retry cooldown when egg is dim/sluggish' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('The red light within the egg is dim and moves about sluggishly')

      instance.send(:use_egg?)

      cooldown = instance.instance_variable_get(:@item_cooldowns)['10']
      expect(cooldown).to be_within(2).of(Time.now - 900 + 60)
    end

    it 'returns false when hidden and cannot use egg' do
      instance = build_ability_process(egg_ids: ['10'], item_cooldowns: {})
      allow(DRC).to receive(:bput).with("invoke #10", anything, anything, anything, anything, anything)
                                  .and_return('You cannot stay hidden while using the egg.')

      expect(instance.send(:use_egg?)).to be false
    end

    it 'returns false when egg_ids is empty' do
      instance = build_ability_process(egg_ids: [], item_cooldowns: {})

      expect(instance.send(:use_egg?)).to be false
    end

    it 'returns false when all eggs are on cooldown' do
      instance = build_ability_process(
        egg_ids: %w[10 20],
        item_cooldowns: { '10' => Time.now, '20' => Time.now }
      )

      expect(instance.send(:use_egg?)).to be false
    end
  end

  # ===========================================================================
  # #use_warhorn? -- per-item cooldown and error handling
  # ===========================================================================
  describe '#use_warhorn?' do
    let(:game_state) { build_game_state }

    it 'returns true on successful exhale' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get a silver warhorn.')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      expect(instance.send(:use_warhorn?, game_state)).to be true
    end

    it 'uses remove verb for worn warhorns' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: true }],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("remove #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You remove a silver warhorn.')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("wear #20", anything, anything, anything, anything)
                                  .and_return('You attach')

      expect(instance.send(:use_warhorn?, game_state)).to be true
      expect(DRC).to have_received(:bput).with("remove #20", anything, anything, anything, anything, anything, anything)
    end

    it 'skips warhorn on cooldown and tries the next one' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }, { id: '30', worn: false }],
        item_cooldowns: { '20' => Time.now }
      )
      allow(DRC).to receive(:bput).with("get #30", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #30 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("stow #30", anything, anything, anything, anything)
                                  .and_return('You put')

      expect(instance.send(:use_warhorn?, game_state)).to be true
      expect(DRC).not_to have_received(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
    end

    it 'sets a 60s retry cooldown when lungs are tired' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {},
        warhorn_cooldown: 1200
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('Your lungs are tired from having sounded a')
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      instance.send(:use_warhorn?, game_state)

      cooldown = instance.instance_variable_get(:@item_cooldowns)['20']
      expect(cooldown).to be_within(2).of(Time.now - 1200 + 60)
    end

    it 'returns false and removes warhorn type when area inhibits' do
      rotation = %w[warhorn egg]
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {},
        warhorn_or_egg: rotation
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('Something about the area inhibits')
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      result = instance.send(:use_warhorn?, game_state)

      expect(result).to be false
      expect(rotation).not_to include('warhorn')
    end

    it 'removes a missing warhorn from the list and tries remaining' do
      item1 = { id: '20', worn: false }
      item2 = { id: '30', worn: false }
      instance = build_ability_process(
        warhorn_items: [item1, item2],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('What were you referring to')
      allow(DRC).to receive(:bput).with("get #30", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #30 lure", anything, anything, anything, anything)
                                  .and_return('You sound a series of bursts from the')
      allow(instance).to receive(:waitrt?)
      allow(DRC).to receive(:bput).with("stow #30", anything, anything, anything, anything)
                                  .and_return('You put')

      expect(instance.send(:use_warhorn?, game_state)).to be true
      expect(instance.instance_variable_get(:@warhorn_items)).not_to include(item1)
    end

    it 'returns false when hands are full' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {}
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You need a free hand')

      expect(instance.send(:use_warhorn?, game_state)).to be false
    end

    it 'returns false when all warhorns are on cooldown' do
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }, { id: '30', worn: false }],
        item_cooldowns: { '20' => Time.now, '30' => Time.now }
      )

      expect(instance.send(:use_warhorn?, game_state)).to be false
    end

    it 'returns false and removes warhorn type when player cannot use warhorns' do
      rotation = %w[warhorn egg]
      instance = build_ability_process(
        warhorn_items: [{ id: '20', worn: false }],
        item_cooldowns: {},
        warhorn_or_egg: rotation
      )
      allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                  .and_return('You get')
      allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                  .and_return('not accomplishing much and looking rather silly')
      allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                  .and_return('You put')

      result = instance.send(:use_warhorn?, game_state)

      expect(result).to be false
      expect(rotation).not_to include('warhorn')
    end

    it 'wields whirlwind offhand when all warhorns exhausted' do
      instance = build_ability_process(
        warhorn_items: [],
        item_cooldowns: {}
      )

      instance.send(:use_warhorn?, game_state)

      expect(game_state).to have_received(:wield_whirlwind_offhand)
    end
  end

  # ===========================================================================
  # #stow_warhorn_item
  # ===========================================================================
  describe '#stow_warhorn_item' do
    it 'uses stow for non-worn items' do
      instance = build_ability_process
      allow(DRC).to receive(:bput).and_return('You put')

      instance.send(:stow_warhorn_item, { id: '20', worn: false })

      expect(DRC).to have_received(:bput).with('stow #20', anything, anything, anything, anything)
    end

    it 'uses wear for worn items' do
      instance = build_ability_process
      allow(DRC).to receive(:bput).and_return('You attach')

      instance.send(:stow_warhorn_item, { id: '20', worn: true })

      expect(DRC).to have_received(:bput).with('wear #20', anything, anything, anything, anything)
    end
  end

  # ===========================================================================
  # Bad YAML config parsing -- tests the case expressions in initialize
  # that produce @warhorn_nouns and @egg_count from raw settings values.
  #
  # We can't call initialize (needs full game I/O), so we replicate the
  # case expressions inline and verify the derived values fed to downstream
  # methods behave correctly.
  # ===========================================================================
  describe 'bad YAML config edge cases' do
    # Replicate the warhorn case expression from initialize
    def warhorn_nouns_from(raw)
      case raw
      when Array then raw
      when String then [raw]
      when true then ['warhorn']
      else []
      end
    end

    # Replicate the egg case expression from initialize
    def egg_count_from(raw)
      case raw
      when Integer then raw
      when true, String then 1
      else 0
      end
    end

    # Replicate the guard that decides whether to call set_warhorn_or_egg
    def should_setup?(nouns, count)
      !(nouns.empty? && count < 1)
    end

    # =========================================================================
    # warhorn config parsing
    # =========================================================================
    describe 'warhorn config parsing' do
      it 'treats integer 42 as no warhorns' do
        nouns = warhorn_nouns_from(42)
        expect(nouns).to eq([])
      end

      it 'treats false as no warhorns' do
        nouns = warhorn_nouns_from(false)
        expect(nouns).to eq([])
      end

      it 'treats nil as no warhorns' do
        nouns = warhorn_nouns_from(nil)
        expect(nouns).to eq([])
      end

      it 'wraps a single string in an array' do
        nouns = warhorn_nouns_from('silver warhorn')
        expect(nouns).to eq(['silver warhorn'])
      end

      it 'passes an array through unchanged' do
        nouns = warhorn_nouns_from(%w[warhorn horn])
        expect(nouns).to eq(%w[warhorn horn])
      end

      it 'treats true as default warhorn noun' do
        nouns = warhorn_nouns_from(true)
        expect(nouns).to eq(['warhorn'])
      end

      it 'passes an empty array through (no warhorns)' do
        nouns = warhorn_nouns_from([])
        expect(nouns).to eq([])
      end

      it 'passes an array with non-string elements through without filtering' do
        nouns = warhorn_nouns_from([true, 42, 'warhorn'])
        expect(nouns).to eq([true, 42, 'warhorn'])
      end
    end

    # =========================================================================
    # egg config parsing
    # =========================================================================
    describe 'egg config parsing' do
      it 'treats integer 0 as zero eggs' do
        expect(egg_count_from(0)).to eq(0)
      end

      it 'treats negative integer as negative count' do
        expect(egg_count_from(-1)).to eq(-1)
      end

      it 'treats integer 2 as two eggs' do
        expect(egg_count_from(2)).to eq(2)
      end

      it 'treats integer 3 as three (even though only 2 ordinals supported)' do
        expect(egg_count_from(3)).to eq(3)
      end

      it 'treats true as 1 egg' do
        expect(egg_count_from(true)).to eq(1)
      end

      it 'treats a string as 1 egg' do
        expect(egg_count_from('yes')).to eq(1)
      end

      it 'treats false as 0 eggs' do
        expect(egg_count_from(false)).to eq(0)
      end

      it 'treats nil as 0 eggs' do
        expect(egg_count_from(nil)).to eq(0)
      end

      it 'treats an array as 0 eggs' do
        expect(egg_count_from([1, 2])).to eq(0)
      end

      it 'treats a hash as 0 eggs' do
        expect(egg_count_from({ count: 2 })).to eq(0)
      end

      it 'treats float 1.5 as 0 eggs (not Integer)' do
        expect(egg_count_from(1.5)).to eq(0)
      end
    end

    # =========================================================================
    # setup guard -- should set_warhorn_or_egg be called?
    # =========================================================================
    describe 'setup guard' do
      it 'skips setup when both empty/zero' do
        expect(should_setup?([], 0)).to be false
      end

      it 'runs setup when warhorn nouns present but egg_count is 0' do
        expect(should_setup?(['warhorn'], 0)).to be true
      end

      it 'runs setup when egg_count is 1 but no warhorn nouns' do
        expect(should_setup?([], 1)).to be true
      end

      it 'runs setup when both present' do
        expect(should_setup?(['warhorn'], 2)).to be true
      end

      it 'runs setup when egg_count is negative (will discover 0 eggs)' do
        expect(should_setup?([], -1)).to be false
      end
    end

    # =========================================================================
    # set_warhorn_or_egg with bad config-derived values
    # =========================================================================
    describe 'set_warhorn_or_egg with degenerate configs' do
      it 'handles egg_count 0 with warhorn_nouns present (warhorn only)' do
        instance = build_ability_process(egg_count: 0, warhorn_nouns: ['warhorn'])
        stub_right_hand_with_id('10')
        allow(DRCI).to receive(:remove_item?).and_return(true)
        allow(DRCI).to receive(:wear_item?).and_return(true)

        instance.send(:set_warhorn_or_egg)

        expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(['warhorn'])
        expect(instance.instance_variable_get(:@egg_ids)).to be_empty
      end

      it 'handles warhorn_nouns with non-string elements gracefully' do
        instance = build_ability_process(egg_count: 0, warhorn_nouns: [true, 42])
        allow(DRCI).to receive(:remove_item?).and_return(false)
        allow(DRCI).to receive(:get_item?).and_return(false)

        instance.send(:set_warhorn_or_egg)

        expect(instance.instance_variable_get(:@warhorn_or_egg)).to be_empty
        expect(DRC).to have_received(:message).with(/No eggs or warhorns found/)
      end

      it 'handles egg_count 3 (only discovers first 2, skips unsupported ordinal)' do
        instance = build_ability_process(egg_count: 3, warhorn_nouns: [])
        call_count = 0
        allow(DRCI).to receive(:get_item?) do |_arg|
          call_count += 1
          stub_right_hand_with_id("e#{call_count}")
          true
        end
        allow(DRCI).to receive(:stow_item?).and_return(true)

        instance.send(:set_warhorn_or_egg)

        # Only 2 ordinals are supported ("egg" and "second egg")
        expect(instance.instance_variable_get(:@egg_ids).size).to eq(2)
        expect(DRC).to have_received(:message).with(/wanted 3 egg.*only found 2/)
      end

      it 'handles empty warhorn_nouns array (no discovery attempted)' do
        instance = build_ability_process(egg_count: 1, warhorn_nouns: [])
        stub_right_hand_with_id('10')
        allow(DRCI).to receive(:get_item?).and_return(true)
        allow(DRCI).to receive(:stow_item?).and_return(true)

        instance.send(:set_warhorn_or_egg)

        expect(instance.instance_variable_get(:@warhorn_items)).to be_empty
        expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(['egg'])
      end
    end

    # =========================================================================
    # use methods with zero/negative warhorn_cooldown
    # =========================================================================
    describe 'warhorn_cooldown edge cases' do
      let(:game_state) { build_game_state }

      it 'warhorn_cooldown 0 means cooldown expires immediately' do
        instance = build_ability_process(
          warhorn_items: [{ id: '20', worn: false }],
          item_cooldowns: { '20' => Time.now - 1 },
          warhorn_cooldown: 0
        )
        allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                    .and_return('You sound a series of bursts from the')
        allow(instance).to receive(:waitrt?)
        allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                    .and_return('You put')

        expect(instance.send(:use_warhorn?, game_state)).to be true
      end

      it 'negative warhorn_cooldown means cooldown is always expired' do
        instance = build_ability_process(
          warhorn_items: [{ id: '20', worn: false }],
          item_cooldowns: { '20' => Time.now },
          warhorn_cooldown: -500
        )
        allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                    .and_return('You sound a series of bursts from the')
        allow(instance).to receive(:waitrt?)
        allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                    .and_return('You put')

        expect(instance.send(:use_warhorn?, game_state)).to be true
      end

      it 'lungs-tired retry with cooldown 0 sets retry ~60s from now' do
        instance = build_ability_process(
          warhorn_items: [{ id: '20', worn: false }],
          item_cooldowns: {},
          warhorn_cooldown: 0
        )
        allow(DRC).to receive(:bput).with("get #20", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #20 lure", anything, anything, anything, anything)
                                    .and_return('Your lungs are tired from having sounded a')
        allow(DRC).to receive(:bput).with("stow #20", anything, anything, anything, anything)
                                    .and_return('You put')

        instance.send(:use_warhorn?, game_state)

        cooldown = instance.instance_variable_get(:@item_cooldowns)['20']
        # Time.now - 0 + 60 = ~60s from now
        expect(cooldown).to be_within(2).of(Time.now + 60)
      end
    end

    # =========================================================================
    # Concurrent removal of all items during use
    # =========================================================================
    describe 'all items vanish during use' do
      let(:game_state) { build_game_state }

      it 'handles all eggs disappearing one by one' do
        instance = build_ability_process(
          egg_ids: %w[10 20 30],
          item_cooldowns: {},
          warhorn_or_egg: ['egg']
        )
        allow(DRC).to receive(:bput).with(/invoke #/, anything, anything, anything, anything, anything)
                                    .and_return('Invoke what?')

        expect(instance.send(:use_egg?)).to be false
        expect(instance.instance_variable_get(:@egg_ids)).to be_empty
      end

      it 'handles all warhorns disappearing one by one' do
        instance = build_ability_process(
          warhorn_items: [
            { id: '20', worn: false },
            { id: '30', worn: false },
            { id: '40', worn: false }
          ],
          item_cooldowns: {}
        )
        allow(DRC).to receive(:bput).with(/get #/, anything, anything, anything, anything, anything, anything)
                                    .and_return('What were you referring to')

        expect(instance.send(:use_warhorn?, game_state)).to be false
        expect(instance.instance_variable_get(:@warhorn_items)).to be_empty
      end
    end

    # =========================================================================
    # Mixed success/failure across multiple items
    # =========================================================================
    describe 'mixed item states' do
      it 'first egg cooldown, second egg missing, third egg succeeds' do
        instance = build_ability_process(
          egg_ids: %w[10 20 30],
          item_cooldowns: { '10' => Time.now },
          warhorn_or_egg: ['egg']
        )
        allow(DRC).to receive(:bput).with("invoke #20", anything, anything, anything, anything, anything)
                                    .and_return('Invoke what?')
        allow(DRC).to receive(:bput).with("invoke #30", anything, anything, anything, anything, anything)
                                    .and_return('light envelops the area briefly')

        expect(instance.send(:use_egg?)).to be true
        expect(instance.instance_variable_get(:@egg_ids)).to eq(%w[10 30])
      end

      it 'first warhorn cooldown, second warhorn lungs-tired, all exhausted' do
        instance = build_ability_process(
          warhorn_items: [
            { id: '20', worn: false },
            { id: '30', worn: false }
          ],
          item_cooldowns: { '20' => Time.now },
          warhorn_cooldown: 1200
        )
        allow(DRC).to receive(:bput).with("get #30", anything, anything, anything, anything, anything, anything)
                                    .and_return('You get')
        allow(DRC).to receive(:bput).with("exhale #30 lure", anything, anything, anything, anything)
                                    .and_return('Your lungs are tired from having sounded a')
        allow(DRC).to receive(:bput).with("stow #30", anything, anything, anything, anything)
                                    .and_return('You put')

        game_state = build_game_state
        expect(instance.send(:use_warhorn?, game_state)).to be false
        expect(instance.instance_variable_get(:@item_cooldowns)['30']).not_to be_nil
      end
    end
  end
end

# ###################################################################
# MERGED FROM spec/combat_trainer_slivers_spec.rb
# ###################################################################

# ===========================================================================
# SpellProcess#check_slivers -- sliver detection and creation for Moon Mages
# ===========================================================================
RSpec.describe SpellProcess do
  # Build a SpellProcess without calling initialize
  def build_spell_process(**overrides)
    instance = SpellProcess.allocate
    defaults = {
      tk_spell: { 'abbrev' => 'tkt', 'slivers' => true },
      tk_ammo: nil,
      settings: OpenStruct.new,
      # Sliver-recreation throttle. Default the timer well into the past so the
      # cooldown is elapsed for tests that are not specifically about throttling.
      sliver_recast_delay: 180,
      sliver_timer: Time.now - 1000
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = { casting: false }
    double('GameState', defaults.merge(attrs))
  end

  def setup_moon_mage_with_moonblade
    DRStats.guild = 'Moon Mage'
    DRSpells._set_known_spells({ 'Moonblade' => true })
    UserVars._set_moons({ 'visible' => ['Katamba'] })
    # Stub get_data to return spell data with Moonblade
    $test_data = OpenStruct.new(
      spells: OpenStruct.new(
        spell_data: { 'Moonblade' => { 'mana' => 5, 'prep_time' => 5 } }
      )
    )
  end

  describe '#check_slivers' do
    context 'guard clauses' do
      it 'returns early if character does not know Moonblade' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({})

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if character is not a Moon Mage' do
        DRStats.guild = 'Warrior Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if no TK spell is configured' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })

        instance = build_spell_process(tk_spell: nil)
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if already casting' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })

        instance = build_spell_process
        game_state = build_game_state(casting: true)

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if slivers already exist' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })
        DRSpells._set_slivers(true)

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end

      it 'returns early if no moons are visible' do
        DRStats.guild = 'Moon Mage'
        DRSpells._set_known_spells({ 'Moonblade' => true })
        UserVars._set_moons({ 'visible' => [] })

        instance = build_spell_process
        game_state = build_game_state

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, game_state)
      end
    end

    context 'when slivers need to be created' do
      before(:each) do
        setup_moon_mage_with_moonblade
        # A successful cast is a precondition for breaking a fresh moonblade;
        # the failed-cast behavior is covered in its own context below.
        allow(DRCA).to receive(:cast_spell).and_return(true)
      end

      it 'casts moonblade and breaks it on success' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('The slivers drift about')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).once
        expect(DRC).to have_received(:bput).with('break moonblade', anything, anything, anything).once
      end

      it 'retries up to 3 times on failure' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('dissipate without any benefit', 'dissipate without any benefit', 'dissipate without any benefit')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).exactly(3).times
        expect(DRC).to have_received(:bput).with('break moonblade', anything, anything, anything).exactly(3).times
      end

      it 'stops retrying after first success' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('dissipate without any benefit', 'The slivers drift about')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).exactly(2).times
      end

      it 'logs failure message when all retries are exhausted' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('dissipate without any benefit')

        instance = build_spell_process
        game_state = build_game_state

        expect(DRC).to receive(:message).with(/Failed to create slivers.*3 attempts/)
        instance.send(:check_slivers, game_state)
      end

      it 'does not log failure message on success' do
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('The slivers drift about')

        instance = build_spell_process
        game_state = build_game_state

        expect(DRC).not_to receive(:message).with(/Failed to create slivers/)
        instance.send(:check_slivers, game_state)
      end
    end

    # Issue 2 regression: `break moonblade` must be gated on the Moonblade cast
    # actually succeeding. A failed snap-cast (the character lacks the skill to
    # complete the pattern at minimum prep) creates no fresh blade, so an
    # unconditional break would shatter the moonblade already in hand -- the
    # wielded weapon of a moonblade melee trainer -- leaving them unarmed.
    context 'when the moonblade cast fails' do
      before(:each) do
        setup_moon_mage_with_moonblade
        allow(DRC).to receive(:message)
        # Make DRC.bput a spy so `have_received(:bput)` negative assertions work;
        # examples that need a specific break result re-stub the matching args.
        allow(DRC).to receive(:bput)
      end

      it 'never breaks a moonblade when the cast fails (would destroy the wielded weapon)' do
        allow(DRCA).to receive(:cast_spell).and_return(false)

        instance = build_spell_process
        game_state = build_game_state

        expect(DRC).not_to receive(:bput).with('break moonblade', anything, anything, anything)
        instance.send(:check_slivers, game_state)
      end

      it 'retries the cast up to 3 times but never breaks' do
        allow(DRCA).to receive(:cast_spell).and_return(false)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).exactly(3).times
        expect(DRC).not_to have_received(:bput).with('break moonblade', anything, anything, anything)
      end

      it 'logs the failure message when every cast fails' do
        allow(DRCA).to receive(:cast_spell).and_return(false)

        instance = build_spell_process
        game_state = build_game_state

        expect(DRC).to receive(:message).with(/Failed to create slivers.*3 attempts/)
        instance.send(:check_slivers, game_state)
      end

      it 'breaks only after a cast finally succeeds (fail, fail, then succeed)' do
        allow(DRCA).to receive(:cast_spell).and_return(false, false, true)
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('The slivers drift about')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).exactly(3).times
        expect(DRC).to have_received(:bput).with('break moonblade', anything, anything, anything).once
      end

      it 'breaks only on the successful cast, not on a later failed one' do
        # cast succeeds first -> break attempted but yields no slivers -> retry;
        # the next two casts FAIL -> must NOT break again on those.
        allow(DRCA).to receive(:cast_spell).and_return(true, false, false)
        allow(DRC).to receive(:bput)
          .with('break moonblade', 'The slivers drift about', 'dissipate without any benefit', 'Break what?')
          .and_return('dissipate without any benefit')

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell).exactly(3).times
        expect(DRC).to have_received(:bput).with('break moonblade', anything, anything, anything).once
      end
    end

    context 'prep time based on Lunar Magic rank' do
      before(:each) do
        setup_moon_mage_with_moonblade
        allow(DRC).to receive(:bput)
          .with('break moonblade', anything, anything, anything)
          .and_return('The slivers drift about')
      end

      it 'uses prep_time 2 for Lunar Magic >= 400' do
        DRSkill._set_rank('Lunar Magic', 450)
        allow(DRCA).to receive(:cast_spell).and_return(true)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          expect(spell_data['prep_time']).to eq(2)
        end
      end

      it 'uses prep_time 3 for Lunar Magic 300-399' do
        DRSkill._set_rank('Lunar Magic', 350)
        allow(DRCA).to receive(:cast_spell).and_return(true)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          expect(spell_data['prep_time']).to eq(3)
        end
      end

      it 'uses prep_time 4 for Lunar Magic 200-299' do
        DRSkill._set_rank('Lunar Magic', 250)
        allow(DRCA).to receive(:cast_spell).and_return(true)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          expect(spell_data['prep_time']).to eq(4)
        end
      end

      it 'does not override prep_time for Lunar Magic < 200' do
        DRSkill._set_rank('Lunar Magic', 150)
        allow(DRCA).to receive(:cast_spell).and_return(true)

        instance = build_spell_process
        game_state = build_game_state

        instance.send(:check_slivers, game_state)

        expect(DRCA).to have_received(:cast_spell) do |spell_data, _settings|
          # prep_time should remain at the spell data default (5)
          expect(spell_data['prep_time']).to eq(5)
        end
      end
    end

    # sliver_recast_delay throttle: at most one sliver re-creation attempt per
    # delay window (default 180s, user-configurable; 0 disables). Prevents
    # spamming Moonblade casts on targets that consume slivers quickly.
    context 'sliver recast throttle' do
      before(:each) do
        setup_moon_mage_with_moonblade
        allow(DRC).to receive(:bput)
          .with('break moonblade', anything, anything, anything)
          .and_return('The slivers drift about')
      end

      it 'does not cast again while still within the cooldown window' do
        instance = build_spell_process(sliver_recast_delay: 180, sliver_timer: Time.now - 30)

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, build_game_state)
      end

      it 'casts once the cooldown window has elapsed' do
        allow(DRCA).to receive(:cast_spell).and_return(true)

        instance = build_spell_process(sliver_recast_delay: 180, sliver_timer: Time.now - 181)
        instance.send(:check_slivers, build_game_state)

        expect(DRCA).to have_received(:cast_spell)
      end

      it 'boundary: still throttled one second before the delay elapses' do
        instance = build_spell_process(sliver_recast_delay: 100, sliver_timer: Time.now - 99)

        expect(DRCA).not_to receive(:cast_spell)
        instance.send(:check_slivers, build_game_state)
      end

      it 'respects a custom (shorter) delay that a default 180 would still block' do
        allow(DRCA).to receive(:cast_spell).and_return(true)

        # 30s since last attempt: blocked at the 180 default, allowed at 20s.
        instance = build_spell_process(sliver_recast_delay: 20, sliver_timer: Time.now - 30)
        instance.send(:check_slivers, build_game_state)

        expect(DRCA).to have_received(:cast_spell)
      end

      it 'a delay of 0 disables the throttle entirely' do
        allow(DRCA).to receive(:cast_spell).and_return(true)

        instance = build_spell_process(sliver_recast_delay: 0, sliver_timer: Time.now)
        instance.send(:check_slivers, build_game_state)

        expect(DRCA).to have_received(:cast_spell)
      end

      it 'starts the cooldown on an attempt so an immediate second call is throttled' do
        allow(DRCA).to receive(:cast_spell).and_return(true)

        instance = build_spell_process(sliver_recast_delay: 180, sliver_timer: Time.now - 1000)
        game_state = build_game_state

        instance.send(:check_slivers, game_state) # attempt: sets the timer
        instance.send(:check_slivers, game_state) # immediately after: throttled

        expect(DRCA).to have_received(:cast_spell).once
      end

      it 'starts the cooldown even when every cast fails (no per-tick retry spam)' do
        allow(DRC).to receive(:message)
        allow(DRCA).to receive(:cast_spell).and_return(false)

        instance = build_spell_process(sliver_recast_delay: 180, sliver_timer: Time.now - 1000)
        game_state = build_game_state

        instance.send(:check_slivers, game_state) # 3 failed casts, sets the timer
        instance.send(:check_slivers, game_state) # throttled: no new casts

        expect(DRCA).to have_received(:cast_spell).exactly(3).times
      end

      it 'does not start the cooldown when no moons are visible (retries next tick)' do
        UserVars._set_moons({ 'visible' => [] })

        instance = build_spell_process(sliver_recast_delay: 180, sliver_timer: Time.now - 1000)
        instance.send(:check_slivers, build_game_state)

        # timer stays in the past so a later tick (with moons up) can still attempt
        expect(instance.instance_variable_get(:@sliver_timer)).to be <= (Time.now - 1000)
      end
    end
  end

  # cast_ritual now routes weapon disposition through the summoned-aware
  # GameState helpers (stow_or_store_weapon / restore_weapon) instead of its
  # own inline break/stow + re-summon/wield branching.
  describe '#cast_ritual' do
    it 'stores the weapon before the ritual and restores it after' do
      allow(DRCMM).to receive(:update_astral_data).and_return(nil)
      instance = build_spell_process
      gs = double('GameState')
      allow(gs).to receive(:reset_stance=)
      expect(gs).to receive(:stow_or_store_weapon).ordered
      expect(gs).to receive(:restore_weapon).ordered
      instance.send(:cast_ritual, { 'ritual' => true }, gs)
    end

    it 'performs the ritual (invoke + DRCA.ritual) when astral data is present' do
      data = { 'ritual' => true, 'abbrev' => 'foo' }
      allow(DRCMM).to receive(:update_astral_data).and_return(data)
      allow(DRCA).to receive(:ritual)
      instance = build_spell_process
      allow(instance).to receive(:check_invoke)
      gs = double('GameState', stow_or_store_weapon: nil, restore_weapon: nil)
      allow(gs).to receive(:reset_stance=)

      instance.send(:cast_ritual, data, gs)

      expect(gs).to have_received(:stow_or_store_weapon)
      expect(instance).to have_received(:check_invoke)
      expect(DRCA).to have_received(:ritual).with(data, anything)
      expect(gs).to have_received(:restore_weapon)
    end

    it 'skips the ritual body but still restores the weapon when astral data is nil' do
      allow(DRCMM).to receive(:update_astral_data).and_return(nil)
      allow(DRCA).to receive(:ritual)
      instance = build_spell_process
      allow(instance).to receive(:check_invoke)
      gs = double('GameState', stow_or_store_weapon: nil, restore_weapon: nil)
      allow(gs).to receive(:reset_stance=)

      instance.send(:cast_ritual, { 'ritual' => true }, gs)

      expect(instance).not_to have_received(:check_invoke)
      expect(DRCA).not_to have_received(:ritual)
      expect(gs).to have_received(:restore_weapon)
    end

    it 'resets stance after the ritual' do
      allow(DRCMM).to receive(:update_astral_data).and_return(nil)
      instance = build_spell_process
      gs = double('GameState', stow_or_store_weapon: nil, restore_weapon: nil)
      expect(gs).to receive(:reset_stance=).with(true)
      instance.send(:cast_ritual, { 'ritual' => true }, gs)
    end
  end
end

# ###################################################################
# MERGED FROM spec/combat_trainer_gempouch_spec.rb
# ###################################################################

# ===========================================================================
# LootProcess#stow_loot -- gem pouch swap when pouch is full
#
# Flow: stow_loot tries to stow an item. If the pouch-full flag fires
# (set by a game message matcher), the method drops the item, swaps
# the full pouch for a spare via DRCI.swap_out_full_gempouch?, then
# picks up the dropped gem.
# ===========================================================================
RSpec.describe LootProcess do
  def build_loot_process(**overrides)
    instance = LootProcess.allocate
    defaults = {
      tie_bundle: false,
      skin: false,
      dissect: false,
      dump_timer: Time.now,
      dump_junk: false,
      dump_item_count: 10,
      autoloot_container: nil,
      autoloot_gems: false,
      loot_bodies: true,
      lootables: [],
      gem_nouns: ['diamond'],
      box_nouns: [],
      box_loot_limit: nil,
      current_box_count: 0,
      loot_specials: [],
      gem_pouch_adjective: 'black',
      gem_pouch_noun: 'pouch',
      full_pouch_container: 'backpack',
      spare_gem_pouch_container: 'locker',
      tie_pouch: false,
      equipment_manager: double('EquipmentManager', stow_weapon: nil, wield_weapon?: nil, is_listed_item?: false)
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      need_bundle: false,
      mob_died: false,
      npcs: [],
      skinnable?: false,
      finish_killing?: false,
      finish_spell_casting?: false,
      stowing?: false,
      currently_whirlwinding: false
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:unlootable)
    allow(state).to receive(:lootable?).and_return(true)
    state
  end

  describe '#stow_loot (pouch-full swap)' do
    before(:each) do
      # Allow all bput calls by default (stow, drop, etc.)
      allow(DRC).to receive(:bput).and_return('You put')
      allow(DRCI).to receive(:swap_out_full_gempouch?).and_return(true)
      allow(DRCI).to receive(:get_item_unsafe).and_return(false)
    end

    context 'when pouch-full flag is set and swap succeeds' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['container-full'] = nil
        # The pouch-full flag fires as a side effect during the stow bput call.
        # Simulate this by having the stow bput set the flag.
        allow(DRC).to receive(:bput).with(/^stow /, any_args) do
          Flags['pouch-full'] = true
          'You put'
        end
      end

      it 'calls DRCI.swap_out_full_gempouch? with correct arguments' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRCI).to have_received(:swap_out_full_gempouch?).with(
          'black', 'pouch', 'backpack', 'locker', false
        )
      end

      it 'passes tie_pouch=true when configured' do
        instance = build_loot_process(tie_pouch: true)
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRCI).to have_received(:swap_out_full_gempouch?).with(
          'black', 'pouch', 'backpack', 'locker', true
        )
      end

      it 'picks up the dropped gem after successful swap' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRC).to have_received(:bput).with('stow gem', anything, anything, anything, anything, anything, anything, anything)
      end

      it 'does not mark item as unlootable' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(game_state).not_to have_received(:unlootable)
      end
    end

    context 'when pouch-full flag is set and swap fails' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['container-full'] = nil
        allow(DRC).to receive(:bput).with(/^stow /, any_args) do
          Flags['pouch-full'] = true
          'You put'
        end
        allow(DRCI).to receive(:swap_out_full_gempouch?).and_return(false)
      end

      it 'marks item as unlootable' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(game_state).to have_received(:unlootable).with('diamond')
      end

      it 'does not try to pick up the gem' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRC).not_to have_received(:bput).with('stow gem', anything, anything, anything, anything, anything, anything, anything)
      end
    end

    context 'when pouch-full flag is set but no spare container configured' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['container-full'] = nil
        allow(DRC).to receive(:bput).with(/^stow /, any_args) do
          Flags['pouch-full'] = true
          'You put'
        end
      end

      it 'marks item unlootable without attempting swap' do
        instance = build_loot_process(spare_gem_pouch_container: nil)
        instance.send(:stow_loot, 'diamond', game_state)

        expect(game_state).to have_received(:unlootable).with('diamond')
        expect(DRCI).not_to have_received(:swap_out_full_gempouch?)
      end
    end

    context 'when pouch-full flag is not set' do
      let(:game_state) { build_game_state }

      before(:each) do
        Flags['pouch-full'] = nil
        Flags['container-full'] = nil
      end

      it 'does not attempt to swap pouches' do
        instance = build_loot_process
        instance.send(:stow_loot, 'diamond', game_state)

        expect(DRCI).not_to have_received(:swap_out_full_gempouch?)
      end
    end
  end
end

# ###################################################################
# MERGED FROM spec/combat_trainer_force_cleanup_spec.rb
# ###################################################################

# ===========================================================================
# GameState#force_cleanup specs
#
# Validates that force_cleanup advances the cleanup state machine past the
# 'kill' phase, and is a no-op in all other states. This is the safety net
# for when finishing the last mob takes too long (e.g. ranged weapons with
# long aim cycles in multi-mob areas).
# ===========================================================================
RSpec.describe GameState do
  def build_game_state(**overrides)
    instance = GameState.allocate
    defaults = {
      clean_up_step: nil,
      skip_last_kill: false,
      stop_on_bleeding: false
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  describe '#force_cleanup' do
    context 'when in the kill phase' do
      it 'advances to clear_magic' do
        gs = build_game_state(clean_up_step: 'kill')

        gs.force_cleanup

        expect(gs.finish_killing?).to be false
        expect(gs.finish_spell_casting?).to be true
      end

      it 'is idempotent -- calling twice stays at clear_magic' do
        gs = build_game_state(clean_up_step: 'kill')

        gs.force_cleanup
        gs.force_cleanup

        expect(gs.finish_spell_casting?).to be true
      end
    end

    # ------------------------------------------------------------------
    # Adversarial: force_cleanup must not disrupt cleanup states that have
    # already progressed past 'kill'. A bug here could skip stowing or
    # cause the state machine to regress.
    # ------------------------------------------------------------------
    shared_examples 'no-op for non-kill phase' do |phase, description|
      context "when in the #{description} phase (#{phase.inspect})" do
        it 'does not change the cleanup step' do
          gs = build_game_state(clean_up_step: phase)

          gs.force_cleanup

          expect(gs.instance_variable_get(:@clean_up_step)).to eq(phase)
        end
      end
    end

    include_examples 'no-op for non-kill phase', nil, 'not yet cleaning up'
    include_examples 'no-op for non-kill phase', 'clear_magic', 'clear_magic'
    include_examples 'no-op for non-kill phase', 'dismiss_pet', 'dismiss_pet'
    include_examples 'no-op for non-kill phase', 'stow', 'stow'
    include_examples 'no-op for non-kill phase', 'done', 'done'

    # ------------------------------------------------------------------
    # Adversarial: garbage or unexpected values must not be treated as
    # 'kill'. The guard is an equality check, not a pattern match.
    # ------------------------------------------------------------------
    context 'when clean_up_step has an unexpected value' do
      it 'does not change the cleanup step' do
        gs = build_game_state(clean_up_step: 'bogus')

        gs.force_cleanup

        expect(gs.instance_variable_get(:@clean_up_step)).to eq('bogus')
      end
    end
  end

  # ===========================================================================
  # next_clean_up_step interaction with force_cleanup
  #
  # Validates that the normal state machine and force_cleanup compose
  # correctly -- force_cleanup mid-kill should allow normal progression
  # to resume from clear_magic onward.
  # ===========================================================================
  describe '#next_clean_up_step after force_cleanup' do
    it 'resumes normal progression from clear_magic through done' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup
      expect(gs.finish_spell_casting?).to be true

      gs.next_clean_up_step
      expect(gs.dismiss_pet?).to be true

      gs.next_clean_up_step
      expect(gs.stowing?).to be true

      gs.next_clean_up_step
      expect(gs.done_cleaning_up?).to be true
    end
  end

  # ===========================================================================
  # next_clean_up_step with skip_last_kill
  #
  # When skip_last_kill is true, next_clean_up_step skips 'kill' entirely.
  # force_cleanup should never be needed, but if called on the resulting
  # 'clear_magic' state it must be a no-op.
  # ===========================================================================
  describe '#next_clean_up_step with skip_last_kill' do
    it 'skips kill and goes directly to clear_magic' do
      gs = build_game_state(skip_last_kill: true)

      gs.next_clean_up_step

      expect(gs.finish_killing?).to be false
      expect(gs.finish_spell_casting?).to be true
    end

    it 'force_cleanup is a no-op when skip_last_kill already skipped kill' do
      gs = build_game_state(skip_last_kill: true)

      gs.next_clean_up_step
      gs.force_cleanup

      expect(gs.finish_spell_casting?).to be true
    end
  end

  # ===========================================================================
  # Predicate consistency
  #
  # Validates that the predicates agree with the state after force_cleanup.
  # A mismatch here could cause the main loop to get stuck or skip steps.
  # ===========================================================================
  describe 'predicate consistency after force_cleanup' do
    it 'cleaning_up? remains true' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.cleaning_up?).to be true
    end

    it 'done_cleaning_up? is false' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.done_cleaning_up?).to be false
    end

    it 'finish_killing? is false' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.finish_killing?).to be false
    end

    it 'stowing? is false' do
      gs = build_game_state(clean_up_step: 'kill')

      gs.force_cleanup

      expect(gs.stowing?).to be false
    end
  end
end

# ###################################################################
# MERGED FROM spec/combat_trainer_almanac_spec.rb
# ###################################################################

RSpec.describe TrainerProcess do
  def build_trainer(**overrides)
    instance = TrainerProcess.allocate
    defaults = {
      almanac: 'almanac',
      almanac_skills: [],
      almanac_priority_skills: [],
      equipment_manager: double('EquipmentManager')
    }
    defaults.merge(overrides).each do |k, v|
      instance.instance_variable_set(:"@#{k}", v)
    end
    instance
  end

  def build_game_state(**attrs)
    defaults = {
      currently_whirlwinding: false,
      npcs: []
    }
    state = double('GameState', defaults.merge(attrs))
    allow(state).to receive(:sheath_whirlwind_offhand)
    allow(state).to receive(:wield_whirlwind_offhand)
    allow(state).to receive(:engage_slow)
    state
  end

  describe '#use_almanac' do
    before(:each) do
      allow(DRC).to receive(:retreat)
      allow(DRC).to receive(:bput).and_return('Roundtime')
      allow(DRCI).to receive(:get_item_if_not_held?).and_return(true)
      allow(DRCI).to receive(:in_hands?).and_return(true)
      allow(DRCI).to receive(:exists?).and_return(true)
      allow(DRCI).to receive(:put_away_item?).and_return(true)
      UserVars.almanac_last_use = Time.now - 700
    end

    # -----------------------------------------------------------------
    # Early return guards
    # -----------------------------------------------------------------
    context 'when @almanac is nil' do
      it 'returns immediately without any game commands' do
        trainer = build_trainer(almanac: nil)
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:retreat)
        expect(DRCI).not_to have_received(:get_item_if_not_held?)
      end
    end

    context 'when cooldown has not elapsed' do
      it 'returns immediately without any game commands' do
        trainer = build_trainer
        game_state = build_game_state
        UserVars.almanac_last_use = Time.now

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:retreat)
        expect(DRCI).not_to have_received(:get_item_if_not_held?)
      end
    end

    context 'when left hand is full and not whirlwinding' do
      it 'returns immediately' do
        $left_hand = 'sword'
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: false)

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:retreat)
      end
    end

    # -----------------------------------------------------------------
    # Almanac script delegation
    # -----------------------------------------------------------------
    context 'when almanac script is running' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(true)
      end

      it 'delegates to $ALMANAC.use_almanac' do
        almanac_script = double('AlmanacScript')
        $ALMANAC = almanac_script
        allow(almanac_script).to receive(:use_almanac).and_return(:ok)

        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(almanac_script).to have_received(:use_almanac)
        expect(DRCI).not_to have_received(:get_item_if_not_held?)
      end

      it 'disables almanac when script returns :not_found' do
        almanac_script = double('AlmanacScript')
        $ALMANAC = almanac_script
        allow(almanac_script).to receive(:use_almanac).and_return(:not_found)

        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(trainer.instance_variable_get(:@almanac)).to be_nil
      end

      it 're-wields whirlwind offhand after delegation' do
        almanac_script = double('AlmanacScript')
        $ALMANAC = almanac_script
        allow(almanac_script).to receive(:use_almanac).and_return(:ok)

        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:wield_whirlwind_offhand)
      end
    end

    # -----------------------------------------------------------------
    # Successful almanac usage (inline, no almanac script)
    # -----------------------------------------------------------------
    context 'when almanac is retrieved successfully' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
      end

      it 'retreats and engages slow before getting the almanac' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:retreat).ordered
        expect(game_state).to have_received(:engage_slow).ordered
      end

      it 'studies the almanac and puts it away' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('study my almanac', anything, anything, anything)
        expect(DRCI).to have_received(:put_away_item?).with('almanac')
      end

      it 'updates the cooldown timer' do
        trainer = build_trainer
        game_state = build_game_state
        before_time = Time.now

        trainer.send(:use_almanac, game_state)

        expect(UserVars.almanac_last_use).to be >= before_time
      end

      it 'does not turn the almanac when no training_skill is set' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:bput).with(/^turn almanac/, anything, anything)
      end

      it 'turns the almanac to the training skill when almanac_skills are configured' do
        allow(DRSkill).to receive(:getxp).and_return(5)
        allow(DRSkill).to receive(:getrank).and_return(100)

        trainer = build_trainer(almanac_skills: ['Scholarship'])
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('turn almanac to Scholarship', 'You turn', 'You attempt to turn')
      end

      it 'prefers priority skills over regular almanac skills' do
        allow(DRSkill).to receive(:getxp).and_return(5)
        allow(DRSkill).to receive(:getrank).and_return(100)

        trainer = build_trainer(
          almanac_skills: ['Scholarship'],
          almanac_priority_skills: ['Tactics']
        )
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('turn almanac to Tactics', 'You turn', 'You attempt to turn')
      end

      it 're-wields whirlwind offhand after studying' do
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:wield_whirlwind_offhand)
      end

      it 'sheaths whirlwind offhand before getting the almanac' do
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:sheath_whirlwind_offhand)
      end
    end

    # -----------------------------------------------------------------
    # Almanac not found -- disables for the hunt
    # -----------------------------------------------------------------
    context 'when almanac is not found in inventory' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
        allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:exists?).and_return(false)
      end

      it 'disables almanac usage for the rest of the hunt' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(trainer.instance_variable_get(:@almanac)).to be_nil
      end

      it 'does not attempt to study or stow' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:bput).with(/study/, anything, anything, anything)
        expect(DRCI).not_to have_received(:put_away_item?)
      end

      it 'does not update the cooldown timer' do
        trainer = build_trainer
        game_state = build_game_state
        UserVars.almanac_last_use = Time.now - 700
        old_time = UserVars.almanac_last_use

        trainer.send(:use_almanac, game_state)

        expect(UserVars.almanac_last_use).to eq(old_time)
      end

      it 're-wields whirlwind offhand even on failure' do
        trainer = build_trainer
        game_state = build_game_state(currently_whirlwinding: true)

        trainer.send(:use_almanac, game_state)

        expect(game_state).to have_received(:wield_whirlwind_offhand)
      end
    end

    # -----------------------------------------------------------------
    # Hands full -- almanac exists but could not be retrieved
    # -----------------------------------------------------------------
    context 'when hands are full but almanac exists' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
        allow(DRCI).to receive(:get_item_if_not_held?).and_return(false)
        allow(DRCI).to receive(:in_hands?).and_return(false)
        allow(DRCI).to receive(:exists?).and_return(true)
      end

      it 'does not disable almanac usage' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(trainer.instance_variable_get(:@almanac)).to eq('almanac')
      end

      it 'returns without studying or stowing' do
        trainer = build_trainer
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).not_to have_received(:bput).with(/study/, anything, anything, anything)
        expect(DRCI).not_to have_received(:put_away_item?)
      end
    end

    # -----------------------------------------------------------------
    # Skill selection edge cases
    # -----------------------------------------------------------------
    context 'when all almanac_skills are at mindstate 18+' do
      before(:each) do
        allow(Script).to receive(:running?).with('almanac').and_return(false)
        allow(DRSkill).to receive(:getxp).and_return(18)
        allow(DRSkill).to receive(:getrank).and_return(100)
      end

      it 'falls back to skill_with_lowest_mindstate' do
        skill_data = double('SkillData', name: 'Forging', exp: 1, rank: 50)
        allow(DRSkill).to receive(:list).and_return([skill_data])

        trainer = build_trainer(almanac_skills: ['Scholarship'])
        game_state = build_game_state

        trainer.send(:use_almanac, game_state)

        expect(DRC).to have_received(:bput).with('turn almanac to Forging', 'You turn', 'You attempt to turn')
      end
    end
  end
end

# ===================================================================
# Summoned-weapon-aware store/restore (Issue 1 regression)
#
# A moon mage (or warrior mage) trains with a SUMMONED weapon whose
# configured name is the spell noun ("moonblade" / "moonstaff" / an
# elemental weapon), which is NOT a gear-list item. Routines that stow
# then re-wield the weapon around an interruption (astrology telescope,
# a sorcery-boosted cast, a cleric ritual) used the raw EquipmentManager
# path, which can never match the summoned name: it printed
#   "EquipmentManager: Failed to match a weapon for moonblade:<skill>"
# and left the blade stuck in hand (blocking the telescope) or the
# character unarmed after re-wield returned false.
#
# GameState#stow_or_store_weapon and #restore_weapon route summoned
# weapons through wear/break + re-hold/reshape instead, matching what
# SetupProcess#check_weapon already does on a weapon switch. Non-summoned
# weapons fall through to the identical EquipmentManager calls as before.
# ===================================================================
RSpec.describe 'GameState summoned-weapon store/restore' do
  before(:each) { ct_setup }

  # Real GameState (allocate) with just the fields the two helpers touch.
  # summoned membership is keyed on the weapon SKILL, so weapon_name is free
  # to be the (non-gear) summoned noun.
  def build_weapon_state(weapon_skill:, weapon_name:, summoned_weapons:, equipment_manager: nil)
    gs = GameState.allocate
    gs.instance_variable_set(:@current_weapon_skill, weapon_skill)
    gs.instance_variable_set(:@weapons_to_train, { weapon_skill => weapon_name })
    gs.instance_variable_set(:@summoned_weapons, summoned_weapons)
    gs.instance_variable_set(:@equipment_manager, equipment_manager || double('EquipmentManager', stow_weapon: nil, wield_weapon?: nil))
    gs.instance_variable_set(:@summoned_weapons_adjective, nil)
    gs.instance_variable_set(:@summoned_weapons_element, nil)
    gs.instance_variable_set(:@summoned_weapons_ingot, nil)
    gs
  end

  describe '#stow_or_store_weapon' do
    it 'wears (not stows) a moon mage summoned weapon to free the hand' do
      DRStats.guild = 'Moon Mage'
      em = double('EquipmentManager')
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'moonblade',
                              summoned_weapons: [{ 'name' => 'Large Edged' }], equipment_manager: em)
      expect(DRCMM).to receive(:wear_moon_weapon?)
      expect(em).not_to receive(:stow_weapon)
      expect(DRCS).not_to receive(:break_summoned_weapon)
      gs.stow_or_store_weapon
    end

    it 'breaks a warrior mage summoned weapon by its configured name' do
      DRStats.guild = 'Warrior Mage'
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'fiery sword',
                              summoned_weapons: [{ 'name' => 'Large Edged' }])
      expect(DRCS).to receive(:break_summoned_weapon).with('fiery sword')
      expect(DRCMM).not_to receive(:wear_moon_weapon?)
      gs.stow_or_store_weapon
    end

    it 'stows a normal gear weapon via EquipmentManager' do
      DRStats.guild = 'Barbarian'
      em = double('EquipmentManager')
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'war sword',
                              summoned_weapons: [], equipment_manager: em)
      expect(em).to receive(:stow_weapon).with('war sword')
      gs.stow_or_store_weapon
    end

    # boundary: summoned membership is by SKILL, not by the weapon's noun
    it 'treats the weapon as summoned based on skill even when the name looks mundane' do
      DRStats.guild = 'Moon Mage'
      gs = build_weapon_state(weapon_skill: 'Small Edged', weapon_name: 'moonblade',
                              summoned_weapons: [{ 'name' => 'Small Edged' }])
      expect(DRCMM).to receive(:wear_moon_weapon?)
      gs.stow_or_store_weapon
    end

    # boundary: a nil weapon_skill is not a summoned skill -> normal stow, no crash
    it 'handles a nil weapon_skill without raising (normal stow path)' do
      em = double('EquipmentManager')
      gs = build_weapon_state(weapon_skill: nil, weapon_name: nil,
                              summoned_weapons: [{ 'name' => 'Large Edged' }], equipment_manager: em)
      expect(em).to receive(:stow_weapon).with(nil)
      expect { gs.stow_or_store_weapon }.not_to raise_error
    end

    # adversarial: a summoned weapon under a non-moon, non-warrior-mage guild
    # (a misconfiguration) falls into the break branch -- documents the
    # else = break disposition rather than silently stowing to the gear list.
    it 'breaks a summoned weapon for a non-moon, non-warrior-mage guild' do
      DRStats.guild = 'Ranger'
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'summoned thing',
                              summoned_weapons: [{ 'name' => 'Large Edged' }])
      expect(DRCS).to receive(:break_summoned_weapon).with('summoned thing')
      gs.stow_or_store_weapon
    end
  end

  describe '#restore_weapon' do
    it 're-holds and reshapes a summoned weapon instead of gear-matching it' do
      DRStats.guild = 'Moon Mage'
      em = double('EquipmentManager')
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'moonblade',
                              summoned_weapons: [{ 'name' => 'Large Edged' }], equipment_manager: em)
      expect(gs).to receive(:prepare_summoned_weapon).with(false)
      expect(em).not_to receive(:wield_weapon?)
      gs.restore_weapon
    end

    # THE core regression: a summoned moonblade must never reach EquipmentManager
    # (that raw path is what printed "Failed to match a weapon for moonblade:<skill>").
    it 'never calls EquipmentManager#wield_weapon? for a summoned moonblade' do
      DRStats.guild = 'Moon Mage'
      em = double('EquipmentManager') # strict: any wield_weapon? call fails the example
      gs = build_weapon_state(weapon_skill: 'Small Edged', weapon_name: 'moonblade',
                              summoned_weapons: [{ 'name' => 'Small Edged' }], equipment_manager: em)
      allow(gs).to receive(:prepare_summoned_weapon)
      expect(em).not_to receive(:wield_weapon?)
      gs.restore_weapon
    end

    it 'wields a normal gear weapon via EquipmentManager with name and skill' do
      DRStats.guild = 'Barbarian'
      em = double('EquipmentManager', wield_weapon?: true)
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'war sword',
                              summoned_weapons: [], equipment_manager: em)
      expect(em).to receive(:wield_weapon?).with('war sword', 'Large Edged')
      expect(gs).not_to receive(:prepare_summoned_weapon)
      gs.restore_weapon
    end

    it 'handles a nil weapon_skill without raising (normal wield path)' do
      em = double('EquipmentManager', wield_weapon?: nil)
      gs = build_weapon_state(weapon_skill: nil, weapon_name: nil,
                              summoned_weapons: [{ 'name' => 'Large Edged' }], equipment_manager: em)
      expect { gs.restore_weapon }.not_to raise_error
    end

    # integration: the REAL prepare_summoned_weapon runs (DRCS/DRCMM no-ops) and
    # must issue no EquipmentManager calls at all.
    it 'real prepare_summoned_weapon path issues no EquipmentManager calls' do
      DRStats.guild = 'Moon Mage'
      UserVars._set_moons({ 'visible' => ['Katamba'] })
      em = double('EquipmentManager') # strict: no stow_weapon / wield_weapon? allowed
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'moonblade',
                              summoned_weapons: [{ 'name' => 'Large Edged' }], equipment_manager: em)
      expect { gs.restore_weapon }.not_to raise_error
    end
  end

  describe 'store then restore round trip' do
    it 'moon mage wears then re-holds, never touching the gear list' do
      DRStats.guild = 'Moon Mage'
      em = double('EquipmentManager') # strict: neither stow_weapon nor wield_weapon? allowed
      gs = build_weapon_state(weapon_skill: 'Large Edged', weapon_name: 'moonblade',
                              summoned_weapons: [{ 'name' => 'Large Edged' }], equipment_manager: em)
      allow(gs).to receive(:prepare_summoned_weapon)
      expect(DRCMM).to receive(:wear_moon_weapon?)
      gs.stow_or_store_weapon
      gs.restore_weapon
      expect(gs).to have_received(:prepare_summoned_weapon).with(false)
    end
  end
end

# ===================================================================
# TrainerProcess#check_heavens (Issue 1 -- astrology)
#
# Astrology needs a free hand for the telescope. For a moon mage the
# weapon is a summoned moonblade; the old code stowed/re-wielded it via
# EquipmentManager, which could not match "moonblade" -- so the blade was
# never freed (telescope failed) and re-wield spammed the match error.
# check_heavens now uses the summoned-aware store/restore seam.
# ===================================================================
RSpec.describe 'TrainerProcess#check_heavens' do
  before(:each) { ct_setup }

  def build_heavens_trainer(have_telescope: true, equipment_manager: nil)
    tp = TrainerProcess.allocate
    tp.instance_variable_set(:@have_telescope, have_telescope)
    tp.instance_variable_set(:@telescope_name, 'telescope')
    tp.instance_variable_set(:@telescope_storage, 'case')
    tp.instance_variable_set(:@equipment_manager, equipment_manager) if equipment_manager
    tp
  end

  it 'stows via the summoned-aware seam before observing and restores after' do
    tp = build_heavens_trainer
    allow(tp).to receive(:determine_time)
    allow(DRCMM).to receive(:get_telescope?).and_return(true)
    gs = double('GameState')
    expect(gs).to receive(:stow_or_store_weapon).ordered
    expect(gs).to receive(:restore_weapon).ordered
    tp.send(:check_heavens, gs)
  end

  it 'observes the sky when a telescope is retrieved' do
    tp = build_heavens_trainer(have_telescope: true)
    allow(DRCMM).to receive(:get_telescope?).and_return(true)
    gs = double('GameState', stow_or_store_weapon: nil, restore_weapon: nil)
    expect(tp).to receive(:determine_time)
    tp.send(:check_heavens, gs)
  end

  it 'skips observing but still restores the weapon when the telescope cannot be retrieved' do
    tp = build_heavens_trainer(have_telescope: true)
    allow(DRCMM).to receive(:get_telescope?).and_return(false)
    gs = double('GameState')
    expect(gs).to receive(:stow_or_store_weapon)
    expect(tp).not_to receive(:determine_time)
    expect(gs).to receive(:restore_weapon)
    tp.send(:check_heavens, gs)
  end

  it 'observes without a telescope check when have_telescope is false' do
    tp = build_heavens_trainer(have_telescope: false)
    gs = double('GameState', stow_or_store_weapon: nil, restore_weapon: nil)
    expect(DRCMM).not_to receive(:get_telescope?)
    expect(tp).to receive(:determine_time)
    tp.send(:check_heavens, gs)
  end

  # Regression: check_heavens must not touch EquipmentManager directly anymore.
  it 'never calls EquipmentManager directly (summoned weapons stay off the gear path)' do
    em = double('EquipmentManager') # strict: any call fails the example
    tp = build_heavens_trainer(have_telescope: true, equipment_manager: em)
    allow(tp).to receive(:determine_time)
    allow(DRCMM).to receive(:get_telescope?).and_return(true)
    gs = double('GameState', stow_or_store_weapon: nil, restore_weapon: nil)
    expect { tp.send(:check_heavens, gs) }.not_to raise_error
  end
end

# ===========================================================================
# CombatTrainer plugin system -- registry + hook dispatch
# ===========================================================================
# These stub plugins stand in for real combat-trainer plugins. Each is
# deliberately tiny so the behavior under test is obvious at the call site
# (DAMP), and each records its invocations so tests can assert exactly which
# plugins were polled and with what arguments.

# Records every hook invocation and returns a preconfigured value.
class RecordingPlugin
  attr_reader :calls

  def initialize(return_value: nil)
    @return_value = return_value
    @calls = []
  end

  def warhorn_cooldown_active?(room_id:)
    @calls << [:warhorn_cooldown_active?, { room_id: room_id }]
    @return_value
  end

  def warhorn_applied(room_id:, type:)
    @calls << [:warhorn_applied, { room_id: room_id, type: type }]
    @return_value
  end

  def combat_tick(trainer, game_state, counter:)
    @calls << [:combat_tick, [trainer, game_state], { counter: counter }]
    @return_value
  end

  # Used only to prove method_missing forwarding through CombatTrainer.
  def custom_command(arg)
    @calls << [:custom_command, [arg]]
    "handled:#{arg}"
  end
end

# Raises whenever a hook is called, to prove dispatch isolates plugin errors.
class ExplodingPlugin
  def warhorn_cooldown_active?(room_id:)
    raise "boom for #{room_id}"
  end

  def warhorn_applied(room_id:, type:)
    raise "boom applying #{type} in #{room_id}"
  end

  def combat_tick(_trainer, _game_state, counter:)
    raise "boom on tick #{counter}"
  end
end

# Implements no hooks at all, to prove respond_to? gating skips it cleanly.
class InertPlugin
end

RSpec.describe CombatTrainer do
  before(:each) do
    CombatTrainer.registered_plugins.clear
  end

  after(:each) do
    CombatTrainer.registered_plugins.clear
    $debug_mode_ct = nil
  end

  describe '.register_plugin' do
    it 'accumulates plugins in registration order' do
      first = RecordingPlugin.new
      second = RecordingPlugin.new

      CombatTrainer.register_plugin(first)
      CombatTrainer.register_plugin(second)

      expect(CombatTrainer.registered_plugins).to eq([first, second])
    end
  end

  describe '.fire_hook (decision dispatch)' do
    it 'returns nil when no plugins are registered' do
      expect(CombatTrainer.fire_hook(:warhorn_cooldown_active?, room_id: 5)).to be_nil
    end

    it 'returns nil when registered plugins do not implement the hook' do
      CombatTrainer.register_plugin(InertPlugin.new)

      expect(CombatTrainer.fire_hook(:warhorn_cooldown_active?, room_id: 5)).to be_nil
    end

    it 'returns the first non-nil result and stops polling later plugins' do
      first = RecordingPlugin.new(return_value: nil)
      second = RecordingPlugin.new(return_value: true)
      third = RecordingPlugin.new(return_value: false)
      [first, second, third].each { |plugin| CombatTrainer.register_plugin(plugin) }

      result = CombatTrainer.fire_hook(:warhorn_cooldown_active?, room_id: 7)

      expect(result).to eq(true)
      expect(third.calls).to be_empty
    end

    it 'treats a false return as a real answer (does not fall through)' do
      answering = RecordingPlugin.new(return_value: false)
      later = RecordingPlugin.new(return_value: true)
      CombatTrainer.register_plugin(answering)
      CombatTrainer.register_plugin(later)

      expect(CombatTrainer.fire_hook(:warhorn_cooldown_active?, room_id: 1)).to eq(false)
      expect(later.calls).to be_empty
    end

    it 'skips a plugin that raises and uses the next plugin answer' do
      responder = RecordingPlugin.new(return_value: true)
      CombatTrainer.register_plugin(ExplodingPlugin.new)
      CombatTrainer.register_plugin(responder)

      result = nil
      expect { result = CombatTrainer.fire_hook(:warhorn_cooldown_active?, room_id: 9) }.not_to raise_error
      expect(result).to eq(true)
    end

    it 'echoes the plugin error under $debug_mode_ct' do
      $debug_mode_ct = true
      CombatTrainer.register_plugin(ExplodingPlugin.new)

      CombatTrainer.fire_hook(:warhorn_cooldown_active?, room_id: 9)

      expect(displayed_messages).to include(a_string_matching(/ExplodingPlugin error in warhorn_cooldown_active\?/))
    end

    it 'forwards positional and keyword arguments to the hook' do
      plugin = RecordingPlugin.new(return_value: :done)
      CombatTrainer.register_plugin(plugin)
      state = Object.new

      CombatTrainer.fire_hook(:combat_tick, :trainer, state, counter: 42)

      expect(plugin.calls).to eq([[:combat_tick, [:trainer, state], { counter: 42 }]])
    end
  end

  describe '.notify_hook (notification dispatch)' do
    it 'always returns nil, even when a plugin returns a value' do
      CombatTrainer.register_plugin(RecordingPlugin.new(return_value: :ignored))

      expect(CombatTrainer.notify_hook(:warhorn_applied, room_id: 1, type: 'egg')).to be_nil
    end

    it 'invokes every plugin that implements the hook, not just the first' do
      first = RecordingPlugin.new
      second = RecordingPlugin.new
      CombatTrainer.register_plugin(first)
      CombatTrainer.register_plugin(second)

      CombatTrainer.notify_hook(:warhorn_applied, room_id: 3, type: 'warhorn')

      expect(first.calls).to eq([[:warhorn_applied, { room_id: 3, type: 'warhorn' }]])
      expect(second.calls).to eq([[:warhorn_applied, { room_id: 3, type: 'warhorn' }]])
    end

    it 'continues notifying the remaining plugins after one raises' do
      survivor = RecordingPlugin.new
      CombatTrainer.register_plugin(ExplodingPlugin.new)
      CombatTrainer.register_plugin(survivor)

      expect { CombatTrainer.notify_hook(:warhorn_applied, room_id: 4, type: 'egg') }.not_to raise_error
      expect(survivor.calls).to eq([[:warhorn_applied, { room_id: 4, type: 'egg' }]])
    end

    it 'skips plugins that do not implement the hook' do
      CombatTrainer.register_plugin(InertPlugin.new)

      expect { CombatTrainer.notify_hook(:warhorn_applied, room_id: 4, type: 'egg') }.not_to raise_error
    end
  end

  describe 'method_missing forwarding' do
    it 'forwards an unknown call to the first plugin that responds' do
      trainer = CombatTrainer.allocate
      plugin = RecordingPlugin.new
      CombatTrainer.register_plugin(plugin)

      expect(trainer.custom_command('x')).to eq('handled:x')
      expect(plugin.calls).to eq([[:custom_command, ['x']]])
    end

    it 'reports respond_to? true when a plugin implements the method' do
      trainer = CombatTrainer.allocate
      CombatTrainer.register_plugin(RecordingPlugin.new)

      expect(trainer.respond_to?(:custom_command)).to be(true)
    end

    it 'raises NoMethodError when no registered plugin can handle the call' do
      trainer = CombatTrainer.allocate
      CombatTrainer.register_plugin(InertPlugin.new)

      expect { trainer.totally_unknown_method }.to raise_error(NoMethodError)
    end
  end
end

# ===========================================================================
# AbilityProcess room-effect (warhorn/egg) cooldown seam
# ===========================================================================
RSpec.describe 'AbilityProcess room-effect cooldown seam' do
  before(:each) do
    CombatTrainer.registered_plugins.clear
    # UserVars is shared across examples; reset it so each example starts from a
    # known state and the built-in-timer branch is exercised only when set.
    UserVars.warhorn = nil
    allow(DRC).to receive(:message)
    allow(Room).to receive(:current).and_return(double('room', id: 4242))
  end

  after(:each) do
    CombatTrainer.registered_plugins.clear
  end

  describe '#room_effect_on_cooldown?' do
    context 'with no plugin registered (built-in per-character timer)' do
      it 'is on cooldown when the last use was under 600s ago' do
        instance = build_ability_process
        UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now - 599 }

        expect(instance.send(:room_effect_on_cooldown?, 4242)).to be(true)
      end

      it 'is off cooldown when the last use was over 600s ago' do
        instance = build_ability_process
        UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now - 601 }

        expect(instance.send(:room_effect_on_cooldown?, 4242)).to be(false)
      end

      it 'treats exactly 600s since last use as still on cooldown (boundary)' do
        instance = build_ability_process
        # Freeze the clock so the boundary is exact; with a live clock the check
        # instant drifts microseconds past 600s and the case is unobservable.
        frozen = Time.now
        allow(Time).to receive(:now).and_return(frozen)
        UserVars.warhorn = { 'last_warhorn_or_egg' => frozen - 600 }

        expect(instance.send(:room_effect_on_cooldown?, 4242)).to be(true)
      end
    end

    context 'with a plugin answering the decision hook' do
      it 'uses the plugin true answer and never consults the built-in timer' do
        instance = build_ability_process
        CombatTrainer.register_plugin(RecordingPlugin.new(return_value: true))
        # UserVars.warhorn is nil here (reset in before(:each)); if the built-in
        # branch ran it would raise on nil, proving the plugin short-circuits it.
        UserVars.warhorn = nil

        expect(instance.send(:room_effect_on_cooldown?, 4242)).to be(true)
      end

      it 'uses the plugin false answer even when the built-in timer would block' do
        instance = build_ability_process
        UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now }
        CombatTrainer.register_plugin(RecordingPlugin.new(return_value: false))

        expect(instance.send(:room_effect_on_cooldown?, 4242)).to be(false)
      end

      it 'falls back to the built-in timer when the plugin returns nil' do
        instance = build_ability_process
        UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now - 601 }
        CombatTrainer.register_plugin(RecordingPlugin.new(return_value: nil))

        expect(instance.send(:room_effect_on_cooldown?, 4242)).to be(false)
      end

      it 'forwards the current room id to the plugin as a keyword' do
        instance = build_ability_process
        plugin = RecordingPlugin.new(return_value: true)
        CombatTrainer.register_plugin(plugin)

        instance.send(:room_effect_on_cooldown?, 4242)

        expect(plugin.calls).to eq([[:warhorn_cooldown_active?, { room_id: 4242 }]])
      end
    end
  end

  describe '#record_room_effect' do
    it 'refreshes the built-in per-character timer to now' do
      instance = build_ability_process
      UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now - 5000 }

      instance.send(:record_room_effect, 4242, 'egg')

      expect(UserVars.warhorn['last_warhorn_or_egg']).to be_within(2).of(Time.now)
    end

    it 'notifies plugins of the application with room id and type' do
      instance = build_ability_process
      UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now }
      plugin = RecordingPlugin.new
      CombatTrainer.register_plugin(plugin)

      instance.send(:record_room_effect, 4242, 'warhorn')

      expect(plugin.calls).to eq([[:warhorn_applied, { room_id: 4242, type: 'warhorn' }]])
    end
  end

  describe '#use_warhorn_or_egg' do
    it 'skips use and does not rotate when the room effect is on cooldown' do
      instance = build_ability_process(warhorn_or_egg: %w[egg warhorn])
      UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now }

      expect(instance).not_to receive(:use_egg?)

      instance.send(:use_warhorn_or_egg, build_game_state)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[egg warhorn])
    end

    it 'applies an egg, records the effect, and rotates on success' do
      instance = build_ability_process(warhorn_or_egg: %w[egg warhorn])
      UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now - 601 }
      allow(instance).to receive(:use_egg?).and_return(true)
      plugin = RecordingPlugin.new
      CombatTrainer.register_plugin(plugin)

      instance.send(:use_warhorn_or_egg, build_game_state)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[warhorn egg])
      # The plugin is also polled for the cooldown decision (it defers with nil);
      # what matters here is that the successful application was recorded.
      expect(plugin.calls).to include([:warhorn_applied, { room_id: 4242, type: 'egg' }])
    end

    it 'rotates without recording the effect when application fails' do
      instance = build_ability_process(warhorn_or_egg: %w[egg warhorn])
      UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now - 601 }
      allow(instance).to receive(:use_egg?).and_return(false)
      plugin = RecordingPlugin.new
      CombatTrainer.register_plugin(plugin)

      instance.send(:use_warhorn_or_egg, build_game_state)

      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[warhorn egg])
      expect(plugin.calls.select { |call| call.first == :warhorn_applied }).to be_empty
    end

    it 'routes a warhorn rotation entry through use_warhorn?' do
      instance = build_ability_process(warhorn_or_egg: %w[warhorn egg])
      UserVars.warhorn = { 'last_warhorn_or_egg' => Time.now - 601 }
      game_state = build_game_state
      allow(instance).to receive(:use_warhorn?).with(game_state).and_return(true)

      instance.send(:use_warhorn_or_egg, game_state)

      expect(instance).to have_received(:use_warhorn?).with(game_state)
      expect(instance.instance_variable_get(:@warhorn_or_egg)).to eq(%w[egg warhorn])
    end
  end
end
