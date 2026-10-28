require "application_system_test_case"

class DispatchPaginationTest < ApplicationSystemTestCase
  test "homepage leads to thirty dispatches per page with working older and newer links" do
    Dispatch.delete_all
    Dispatch.insert_all!(31.times.map do |i|
      { headline: "Pagination dispatch #{i}", body_markdown: "A synthetic newsroom note.",
        kind: :daily_brief, status: :published, published_at: Time.utc(2026, 8, 3) }
    end)
    published = Dispatch.published.recent_first.to_a

    visit root_path
    assert_selector "[data-testid='dispatch-card']", count: 5
    click_on "All dispatches"
    assert_selector "[data-testid='dispatch-card']", count: 30
    assert_text published.first.headline
    assert_no_selector "[data-testid='dispatch-headline-link']", text: published.last.headline, exact_text: true
    within "nav[aria-label='Dispatch pagination']" do
      assert_text "Page 1 of 2"
      assert_no_link "Newer dispatches"
      find_link("Older dispatches").send_keys(:enter)
    end

    assert_current_path dispatches_path(page: 2)
    assert_selector "[data-testid='dispatch-card']", count: 1
    assert_selector "[data-testid='dispatch-headline-link']", text: published.last.headline, exact_text: true
    within "nav[aria-label='Dispatch pagination']" do
      assert_text "Page 2 of 2"
      assert_no_link "Older dispatches"
      click_on "Newer dispatches"
    end
    assert_current_path dispatches_path
    assert_selector "[data-testid='dispatch-card']", count: 30

    page.driver.browser.manage.window.resize_to(390, 844)
    within "nav[aria-label='Dispatch pagination']" do
      assert_link "Older dispatches"
      assert_operator find_link("Older dispatches").native.rect.height, :>=, 44
      assert_equal 0, page.evaluate_script("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)")
      click_on "Older dispatches"
    end
    assert_selector "[data-testid='dispatch-card']", count: 1
    click_on published.last.headline
    assert_current_path dispatch_path(published.last)
    assert_selector "h1", text: published.last.headline
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "empty and single page feeds have no pagination controls" do
    visit dispatches_path
    assert_selector "[data-testid='dispatch-card']", count: Dispatch.published.count
    assert_no_selector "nav[aria-label='Dispatch pagination']"

    Dispatch.delete_all
    visit dispatches_path
    assert_selector "[data-testid='dispatches-empty']"
    assert_no_selector "nav[aria-label='Dispatch pagination']"
  end
end
