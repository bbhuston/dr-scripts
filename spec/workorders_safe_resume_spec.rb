# frozen_string_literal: true

require 'ostruct'

require_relative 'spec_helper'

def before_dying(&block)
  # No-op for testing.
end

$ORDINALS = %w[first second third fourth fifth sixth seventh eighth ninth tenth].freeze

load_lic_class('workorders.lic', 'WorkOrders')

RSpec.describe 'WorkOrders safe resume-or-request' do
  let(:workorders) { WorkOrders.allocate }
  let(:recipes) do
    [
      { 'name' => 'a metal rod', 'noun' => 'rod', 'type' => 'blacksmithing', 'volume' => 1 },
      { 'name' => 'a shallow metal cup', 'noun' => 'cup', 'type' => 'blacksmithing', 'volume' => 1 }
    ]
  end
  let(:resume_args) do
    [recipes, [8776], 'Yalda', 'Yalda', 'blacksmithing', 'forging', 'easy']
  end

  before do
    $right_hand = nil
    $left_hand = nil
    workorders.instance_variable_set(:@settings, OpenStruct.new(default_container: 'backpack', workorders_max_requests: 1))
    workorders.instance_variable_set(:@resume_or_request, true)
    workorders.instance_variable_set(:@bag, 'backpack')
    workorders.instance_variable_set(:@belt, nil)
    workorders.instance_variable_set(:@hometown, 'Crossing')
    workorders.instance_variable_set(:@cash_on_hand, 5000)
    workorders.instance_variable_set(:@material_budget, 5000)
    workorders.instance_variable_set(:@forging_info, { 'stock-room' => 8775 })
    workorders.instance_variable_set(:@workorders_materials, { 'metal_type' => 'steel' })
    workorders.instance_variable_set(:@crafting_stock, {
                                      'steel' => { 'stock-name' => 'steel', 'stock-number' => 9, 'stock-volume' => 5, 'stock-value' => 2000 }
                                    })
    workorders.instance_variable_set(:@worn_trashcan, nil)
    workorders.instance_variable_set(:@worn_trashcan_verb, nil)
    workorders.instance_variable_set(:@min_items, 1)
    workorders.instance_variable_set(:@max_items, 10)
    allow(workorders).to receive(:stow_tool)
    # Persistence/one-write behavior is exercised with the actual pinned
    # Vars and item APIs by the publication repo's stock-preflight suite.
    allow(workorders).to receive(:forging_purchase_pending?).and_return(false)
    allow(workorders).to receive(:save_forging_purchase).and_return(true)
    allow(workorders).to receive(:exit)
  end

  it 'resumes an active order without ASK or economic commands' do
    expect(DRCI).to receive(:get_item?).with('forging logbook') do
      $left_hand = 'a forging logbook'
      true
    end
    expect(DRC).to receive(:bput)
      .with('read my forging logbook', *WorkOrders::RESUME_LOGBOOK_PATTERNS)
      .and_return('This logbook is tracking a work order requiring you to craft a metal rod from any')
    expect(workorders).to receive(:logbook_remaining).with('forging').and_return(2)
    expect(workorders).not_to receive(:request_work_order)
    expect(DRCM).not_to receive(:ensure_copper_on_hand)
    expect(DRCT).not_to receive(:order_item)

    expect(workorders.send(:resume_or_request_work_order, *resume_args)).to eq(['a metal rod', 2])
  end

  it 'blocks a new order before ASK when no admitted recipe fits purchased stock' do
    recipes.replace([{ 'name' => 'a diagonal-peen mallet', 'volume' => 12 }])
    $left_hand = 'a forging logbook'
    allow(DRCI).to receive(:get_item?).and_return(true)
    allow(DRC).to receive(:bput).and_return('This logbook is not currently tracking a work order.')
    expect(workorders).not_to receive(:request_work_order)
    expect(DRCM).not_to receive(:ensure_copper_on_hand)
    expect(DRCT).not_to receive(:order_item)
    expect(workorders).to receive(:exit).and_raise(SystemExit)

    expect { workorders.send(:resume_or_request_work_order, *resume_args) }.to raise_error(SystemExit)
  end

  it 'resumes a valid active recipe despite a different oversized admitted recipe' do
    recipes << { 'name' => 'a diagonal-peen mallet', 'volume' => 12 }
    $left_hand = 'a forging logbook'
    allow(DRCI).to receive(:get_item?).and_return(true)
    allow(DRC).to receive(:bput)
      .and_return('This logbook is tracking a work order requiring you to craft a metal rod from any')
    allow(workorders).to receive(:logbook_remaining).and_return(2)
    expect(workorders).not_to receive(:request_work_order)

    expect(workorders.send(:resume_or_request_work_order, *resume_args)).to eq(['a metal rod', 2])
  end

  it 'blocks over-budget stock or part prices without lowering the cash floor' do
    stock = { 'stock-name' => 'steel', 'stock-number' => 9, 'stock-volume' => 50, 'stock-value' => 11875 }
    expect(workorders.send(:safe_forging_stock_preflight, recipes, stock)).to be false
    workorders.instance_variable_get(:@crafting_stock)['short pole'] = { 'stock-value' => 101 }
    item = recipes.first.merge('part' => ['short pole'])
    stock['stock-value'] = 4900
    expect(workorders.send(:safe_forging_stock_preflight, [item], stock)).to be false
    expect(workorders.instance_variable_get(:@cash_on_hand)).to eq(5000)
  end

  it 'blocks invalid material before recipe calculation, funding or a smith child' do
    item = recipes.first.merge('volume' => 12)
    stock = { 'stock-name' => 'steel', 'stock-number' => 9, 'stock-volume' => 10, 'stock-value' => 2000 }
    expect(workorders).not_to receive(:find_recipe)
    expect(DRCM).not_to receive(:ensure_copper_on_hand)
    expect(DRCT).not_to receive(:order_item)
    expect(DRC).not_to receive(:wait_for_script_to_complete)
    expect(DRCT).not_to receive(:dispose)

    expect(workorders.send(:forge_items_safely, {}, stock, item, 1)).to be false
  end

  it 'asks once only for exact no-order state and confirms the resulting logbook' do
    expect(DRCI).to receive(:get_item?).with('forging logbook') do
      $left_hand = 'a forging work order logbook'
      true
    end
    expect(DRC).to receive(:bput).once.and_return('This logbook is not currently tracking a work order.')
    expect(workorders).to receive(:request_work_order)
      .with(*resume_args, max_requests: 1, allow_bundled_cleanup: false)
      .and_return(['a metal rod', 2])
    expect(workorders).to receive(:read_active_work_order)
      .with(recipes, 'forging').and_return(['a metal rod', 2])

    expect(workorders.send(:resume_or_request_work_order, *resume_args)).to eq(['a metal rod', 2])
  end

  it 'stops before spending when the requested order and logbook differ' do
    $left_hand = 'a forging logbook'
    allow(DRCI).to receive(:get_item?).and_return(true)
    allow(DRC).to receive(:bput).and_return('This logbook is not currently tracking any work orders.')
    allow(workorders).to receive(:request_work_order).and_return(['a metal rod', 2])
    allow(workorders).to receive(:read_active_work_order).and_return(['a shallow metal cup', 2])
    expect(workorders).to receive(:exit).and_raise(SystemExit)
    expect(DRCM).not_to receive(:ensure_copper_on_hand)
    expect(DRCT).not_to receive(:order_item)

    expect { workorders.send(:resume_or_request_work_order, *resume_args) }.to raise_error(SystemExit)
  end

  ['This work order has expired.', 'I could not find what you were referring to.', 'unknown logbook state'].each do |response|
    it "does not ask or spend from ambiguous state: #{response}" do
      $left_hand = 'a forging logbook'
      allow(DRCI).to receive(:get_item?).and_return(true)
      allow(DRC).to receive(:bput).and_return(response)
      expect(workorders).not_to receive(:request_work_order)
      expect(workorders).to receive(:exit).and_raise(SystemExit)
      expect(DRCM).not_to receive(:ensure_copper_on_hand)
      expect(DRCT).not_to receive(:order_item)

      expect { workorders.send(:resume_or_request_work_order, *resume_args) }.to raise_error(SystemExit)
    end
  end

  it 'routes an active header followed by a complete count to turn-in' do
    $left_hand = 'a forging logbook'
    allow(DRCI).to receive(:get_item?).and_return(true)
    allow(DRC).to receive(:bput)
      .and_return('This logbook is tracking a work order requiring you to craft a metal rod from any')
    allow(workorders).to receive(:logbook_remaining).and_return(0)
    expect(workorders).not_to receive(:request_work_order)

    expect(workorders.send(:resume_or_request_work_order, *resume_args)).to eq([nil, 0])
  end

  it 'bundles only with exact custody and an exact one-item decrement' do
    $right_hand = 'a metal rod'
    $left_hand = 'a forging logbook'
    accepted = 'You notate the rod in the logbook then bundle it up for delivery.'
    expect(DRC).to receive(:bput)
      .with('bundle my rod with my forging logbook', any_args).and_return(accepted)
    expect(workorders).to receive(:logbook_remaining).with('forging').and_return(1)
    expect(DRCI).to receive(:stow_hands)

    expect(workorders.send(:bundle_item_safely, 'rod', 'forging', 2)).to be true
  end

  it 'does not BUNDLE, dispose, or stow when the forged noun is unavailable' do
    expect(DRCI).to receive(:get_item?).with('rod', 'backpack').and_return(false)
    expect(DRC).not_to receive(:bput)
    expect(DRCI).not_to receive(:dispose_trash)
    expect(DRCI).not_to receive(:stow_hands)

    expect(workorders.send(:bundle_item_safely, 'rod', 'forging', 2)).to be false
  end

  it 'preserves custody on the observed not-holding response' do
    $right_hand = 'a metal rod'
    $left_hand = 'a forging logbook'
    expect(DRC).to receive(:bput).and_return('You need to be holding the rod')
    expect(workorders).not_to receive(:logbook_remaining)
    expect(DRCI).not_to receive(:dispose_trash)
    expect(DRCI).not_to receive(:stow_hands)

    expect(workorders.send(:bundle_item_safely, 'rod', 'forging', 2)).to be false
  end

  it 'stops when BUNDLE succeeds but the logbook does not decrement' do
    $right_hand = 'a metal rod'
    $left_hand = 'a forging logbook'
    allow(DRC).to receive(:bput)
      .and_return('You notate the rod in the logbook then bundle it up for delivery.')
    allow(workorders).to receive(:logbook_remaining).and_return(2)
    expect(DRCI).not_to receive(:stow_hands)

    expect(workorders.send(:bundle_item_safely, 'rod', 'forging', 2)).to be false
  end

  it 'stops the forge before funding or purchase on unreadable progress' do
    allow(workorders).to receive(:find_recipe).and_return([recipes.first])
    allow(workorders).to receive(:logbook_remaining).and_return(nil)
    expect(DRCM).not_to receive(:ensure_copper_on_hand)
    expect(DRCT).not_to receive(:order_item)
    expect(DRC).not_to receive(:wait_for_script_to_complete)
    expect(DRCT).not_to receive(:dispose)

    info = { 'stock-room' => 8775, 'trash-room' => nil, 'logbook' => 'forging' }
    stock = { 'stock-name' => 'steel', 'stock-number' => 1, 'stock-volume' => 5, 'stock-value' => 2000 }
    expect(workorders.send(:forge_items_safely, info, stock, recipes.first, 1)).to be false
  end

  it 'propagates bundle failure without cleanup, another purchase, or turn-in' do
    allow(workorders).to receive(:find_recipe).and_return([recipes.first])
    allow(workorders).to receive(:logbook_remaining).and_return(1)
    allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
    allow(DRCT).to receive(:walk_to).and_return(true)
    allow(Room).to receive(:current).and_return(OpenStruct.new(id: 8775))
    allow(workorders).to receive(:purchase_forging_stock).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRCI).to receive(:in_hands?).and_return(false)
    allow(DRC).to receive(:wait_for_script_to_complete).and_return(true)
    allow(workorders).to receive(:bundle_item).and_return(false)
    expect(DRCT).not_to receive(:dispose)
    expect(workorders).not_to receive(:complete_work_order)

    info = { 'stock-room' => 8775, 'trash-room' => nil, 'logbook' => 'forging' }
    stock = { 'stock-name' => 'steel', 'stock-number' => 1, 'stock-volume' => 5, 'stock-value' => 2000 }
    expect(workorders.send(:forge_items_safely, info, stock, recipes.first, 1)).to be false
  end

  it 'stops before material purchase when funding explicitly fails' do
    allow(workorders).to receive(:find_recipe).and_return([recipes.first])
    allow(workorders).to receive(:logbook_remaining).and_return(1)
    allow(DRCM).to receive(:ensure_copper_on_hand).and_return(false)
    expect(DRCT).not_to receive(:order_item)
    expect(DRC).not_to receive(:wait_for_script_to_complete)

    info = { 'stock-room' => 8775, 'trash-room' => nil, 'logbook' => 'forging' }
    stock = { 'stock-name' => 'steel', 'stock-number' => 1, 'stock-volume' => 5, 'stock-value' => 2000 }
    expect(workorders.send(:forge_items_safely, info, stock, recipes.first, 1)).to be false
  end

  it 'stops before BUNDLE when the smith script does not start' do
    allow(workorders).to receive(:find_recipe).and_return([recipes.first])
    allow(workorders).to receive(:logbook_remaining).and_return(1)
    allow(DRCM).to receive(:ensure_copper_on_hand).and_return(true)
    allow(DRCT).to receive(:walk_to).and_return(true)
    allow(Room).to receive(:current).and_return(OpenStruct.new(id: 8775))
    allow(workorders).to receive(:purchase_forging_stock).and_return(true)
    allow(DRCI).to receive(:put_away_item?).and_return(true)
    allow(DRCI).to receive(:in_hands?).and_return(false)
    allow(DRC).to receive(:wait_for_script_to_complete).and_return(nil)
    expect(workorders).not_to receive(:bundle_item)
    expect(DRCT).not_to receive(:dispose)

    info = { 'stock-room' => 8775, 'trash-room' => nil, 'logbook' => 'forging' }
    stock = { 'stock-name' => 'steel', 'stock-number' => 1, 'stock-volume' => 5, 'stock-value' => 2000 }
    expect(workorders.send(:forge_items_safely, info, stock, recipes.first, 1)).to be false
  end

  it 'does not ASK from an unrelated occupied hand without the exact logbook' do
    $right_hand = 'a metal rod'
    allow(workorders).to receive(:find_npc).and_return(true)
    expect(DRCI).to receive(:get_item?).with('forging logbook').and_return(false)
    expect(DRC).not_to receive(:bput)
    expect(DRCI).not_to receive(:untie_item?)
    expect(DRCI).not_to receive(:dispose_trash)

    workorders.send(
      :request_work_order,
      recipes, [8776], 'Yalda', 'Yalda', 'blacksmithing', 'forging', 'easy',
      max_requests: 1, allow_bundled_cleanup: false
    )
  end

  it 'does not GIVE an incomplete logbook' do
    allow(workorders).to receive(:logbook_remaining).and_return(1)
    expect(workorders).not_to receive(:find_npc)
    expect(DRC).not_to receive(:bput)

    expect(workorders.send(:complete_work_order_safely, { 'logbook' => 'forging' })).to be false
  end

  it 'reports completion only for the exact accepted payout response' do
    info = { 'logbook' => 'forging', 'npc-rooms' => [8776], 'npc_last_name' => 'Yalda', 'npc' => 'Yalda' }
    allow(workorders).to receive(:logbook_remaining).and_return(0)
    allow(workorders).to receive(:find_npc).and_return(true)
    allow(DRCI).to receive(:stow_hands)
    allow(DRCI).to receive(:get_item?) do
      $right_hand = 'a forging logbook'
      true
    end
    allow(DRC).to receive(:release_invisibility)
    expect(DRC).to receive(:bput)
      .and_return('You hand Yalda your logbook and bundled items, and are given 1,234 Kronars in return.')
    expect(Lich::Messaging).to receive(:msg)
      .with('plain', 'WorkOrders: Work order completed and turned in')

    expect(workorders.send(:complete_work_order_safely, info)).to be true
  end

  it 'does not report completion or retry an ambiguous turn-in' do
    info = { 'logbook' => 'forging', 'npc-rooms' => [8776], 'npc_last_name' => 'Yalda', 'npc' => 'Yalda' }
    allow(workorders).to receive(:logbook_remaining).and_return(0)
    allow(workorders).to receive(:find_npc).and_return(true)
    allow(DRCI).to receive(:stow_hands)
    allow(DRCI).to receive(:get_item?) do
      $right_hand = 'a forging logbook'
      true
    end
    allow(DRC).to receive(:release_invisibility)
    expect(DRC).to receive(:bput).once.and_return("The work order isn't yet complete")
    expect(Lich::Messaging).not_to receive(:msg).with('plain', /completed and turned in/)

    expect(workorders.send(:complete_work_order_safely, info)).to be false
  end
end
